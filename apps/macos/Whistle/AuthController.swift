// AuthController.swift
// Owns app-level auth state (TECH-SPEC §4.1/§9, plan U6). Drives
// `users.ensure` (via WhistleCore's `ConvexServiceProtocol`) on first
// sign-in, and persists the "we've signed in before" flag so `StatusItemController`
// can render account/sign-in state in the right-click menu. The actual
// session/refresh token lives in the Keychain via the auth provider
// implementation itself (`Auth0AuthProvider`'s `CredentialsManager` for the
// real path, or purely in-memory for `MockAuthProvider` in tests) — this
// controller does not duplicate that storage; it only tracks a small
// "did we ever complete sign-in" breadcrumb in the Keychain so the app can
// show a sensible state before the first token fetch resolves.
//
// All automated tests + the one-shot smoke run exercise this against
// `MockAuthProvider` (WhistleCore) — never Auth0AuthProvider — per
// TECH-SPEC §2a/§9.

import Foundation
import Security
import WhistleCore

/// Auth lifecycle state driving the status item's account UI.
public enum AuthState: Equatable, Sendable {
    case signedOut
    case signingIn
    case signedIn
    /// Refresh/token fetch failed after a prior successful sign-in; user
    /// must re-authenticate. Distinct from `.signedOut` so UI can show a
    /// "session expired" message rather than the plain sign-in prompt.
    case reauthRequired
}

/// Minimal Keychain-backed flag store, used only for the "has this device
/// signed in before" breadcrumb — not for tokens (those live inside the
/// auth provider implementation itself).
public protocol AuthBreadcrumbStore: Sendable {
    func hasSignedInBefore() -> Bool
    func setHasSignedInBefore(_ value: Bool)
}

/// Real Keychain-backed implementation (generic password item, no token
/// material stored — just a boolean breadcrumb).
public final class KeychainAuthBreadcrumbStore: AuthBreadcrumbStore, @unchecked Sendable {
    private let service: String
    private let account = "hasSignedInBefore"

    public init(service: String = "build.conductor.whistle.auth") {
        self.service = service
    }

    public func hasSignedInBefore() -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }
        query.removeValue(forKey: kSecReturnData as String)
        guard status == errSecSuccess, let data = result as? Data else { return false }
        return data == Data([1])
    }

    public func setHasSignedInBefore(_ value: Bool) {
        let data = Data([value ? 1 : 0])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

/// In-memory breadcrumb store for tests — never touches the real Keychain.
public final class InMemoryAuthBreadcrumbStore: AuthBreadcrumbStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public func hasSignedInBefore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func setHasSignedInBefore(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// Drives the app's auth state machine. `@MainActor` per TECH-SPEC §4.1's
/// concurrency map (UI controllers carry a targeted `@MainActor`); this
/// controller is consulted directly by `StatusItemController` to render
/// menu state, so it must be main-actor-isolated rather than an actor.
@MainActor
public final class AuthController: ObservableObject {
    @Published public private(set) var state: AuthState = .signedOut

    /// Number of times `usersEnsure()` has been called — tests assert this
    /// is exactly 1 per successful sign-in (plan U6 happy-path scenario).
    @Published public private(set) var usersEnsureCallCount = 0

    /// Human-readable reason the most recent sign-in attempt failed, for UI
    /// surfaces (onboarding) to show instead of a generic "didn't complete"
    /// message. `nil` while signing in and after a successful sign-in. The
    /// underlying error is always NSLog'd as well — a sign-in failure must
    /// never be silent (silent failure here is how the missing Convex
    /// auth-attach bug went undiagnosed).
    @Published public private(set) var lastSignInErrorMessage: String?

    /// True when this controller is driving the local dev sign-in fallback
    /// (`DevSignInAuthProvider`, used when no real Auth0 tenant is
    /// configured). UI surfaces label the signed-in state "Dev sign-in"
    /// instead of "Signed in" so a mock session is never mistaken for a
    /// real one.
    public let isDevSignIn: Bool

    private let authProvider: any WhistleAuthProvider
    private let convexService: any ConvexServiceProtocol
    private let breadcrumbStore: any AuthBreadcrumbStore

    /// The interactive login/logout entry points live outside
    /// `WhistleAuthProvider` (WhistleCore never presents login UI — see
    /// `Auth0AuthProvider`'s doc comment). This closure-based seam lets
    /// `AuthController` trigger a real interactive login when wired to
    /// `Auth0AuthProvider`, while tests supply a trivial no-op/throwing
    /// closure without needing an `Auth0AuthProvider` instance at all.
    private let performInteractiveLogin: @Sendable () async throws -> Void

    public init(
        authProvider: any WhistleAuthProvider,
        convexService: any ConvexServiceProtocol,
        breadcrumbStore: any AuthBreadcrumbStore = InMemoryAuthBreadcrumbStore(),
        performInteractiveLogin: @escaping @Sendable () async throws -> Void = {},
        isDevSignIn: Bool = false
    ) {
        self.authProvider = authProvider
        self.convexService = convexService
        self.breadcrumbStore = breadcrumbStore
        self.performInteractiveLogin = performInteractiveLogin
        self.isDevSignIn = isDevSignIn
    }

    /// Called at app launch: if a token is already available (cached
    /// session), resolves straight to `.signedIn` (calling `users.ensure`
    /// once); otherwise `.signedOut`, or `.reauthRequired` if this device
    /// has signed in before but the cached session no longer yields a
    /// token (e.g. refresh token revoked/expired).
    public func resolveInitialState() async {
        if await authProvider.isAuthenticated, let _ = await authProvider.currentIdToken() {
            await completeSignIn()
        } else if breadcrumbStore.hasSignedInBefore() {
            state = .reauthRequired
        } else {
            state = .signedOut
        }
    }

    /// Starts (or retries) the sign-in flow. Safe to call from
    /// `.signedOut` or `.reauthRequired`.
    public func signIn() async {
        guard state != .signingIn, state != .signedIn else { return }
        state = .signingIn
        lastSignInErrorMessage = nil
        do {
            try await performInteractiveLogin()
        } catch {
            // Interactive login itself failed (user cancelled, network,
            // misconfigured tenant) — fall back to signed-out so the user
            // can retry, never crash.
            NSLog("Whistle: interactive login failed: %@", String(describing: error))
            lastSignInErrorMessage = "Sign-in didn't complete. Please try again."
            state = .signedOut
            return
        }

        guard await authProvider.currentIdToken() != nil else {
            NSLog("Whistle: interactive login succeeded but no ID token is available from the credentials store")
            lastSignInErrorMessage = "Signed in, but no session token was available. Please try again."
            state = .signedOut
            return
        }
        await completeSignIn()
    }

    /// Simulates/handles a token refresh failure encountered during normal
    /// operation (e.g. a background token refresh attempt). Per plan U6's
    /// edge-case scenario: transitions to `.reauthRequired`, never crashes.
    public func handleTokenRefreshFailure() {
        guard state == .signedIn else { return }
        state = .reauthRequired
    }

    public func signOut() async {
        // Order matters: clear the provider's cached credentials BEFORE
        // detaching Convex's websocket attachment. If we detached Convex
        // first, a concurrent authenticated call (e.g. a periodic
        // SyncEngine drain) racing in during this `await` gap would see the
        // gate reset, re-run `ensureAuthAttached()`, and pull a still-valid
        // token from the not-yet-cleared provider -- silently re-latching
        // the exact attachment we just tore down. Clearing the provider
        // first means any such race fails closed (no token to attach)
        // instead of reviving the old session.
        await authProvider.logout()
        await convexService.detachAuth()
        breadcrumbStore.setHasSignedInBefore(false)
        state = .signedOut
    }

    private func completeSignIn() async {
        do {
            _ = try await convexService.usersEnsure()
            usersEnsureCallCount += 1
            breadcrumbStore.setHasSignedInBefore(true)
            lastSignInErrorMessage = nil
            state = .signedIn
        } catch {
            // Dev sign-in is a purely local affordance: its mock token is
            // not a real JWT, so the backend rejecting `users.ensure` is
            // expected — complete the sign-in anyway (the UI labels the
            // state "Dev sign-in" so it can't be mistaken for a real
            // session).
            if isDevSignIn {
                breadcrumbStore.setHasSignedInBefore(true)
                lastSignInErrorMessage = nil
                state = .signedIn
                return
            }
            // NEVER swallow this error silently — log the underlying cause
            // and publish a cause-specific message (backend auth rejection
            // vs network/other) so the sign-in UI can say what actually
            // went wrong.
            NSLog("Whistle: users.ensure failed after sign-in: %@", String(describing: error))
            if case ConvexServiceError.notAuthenticated = error {
                lastSignInErrorMessage = "Signed in, but the Whistle backend couldn't verify the session. Please try signing in again."
            } else {
                lastSignInErrorMessage = "Signed in, but the Whistle backend couldn't be reached. Check your connection and try again."
            }
            // users.ensure failing shouldn't strand the user in a
            // half-signed-in state with no way forward — treat as a
            // re-auth-required condition so the menu offers a retry
            // affordance rather than silently doing nothing.
            state = .reauthRequired
        }
    }
}
