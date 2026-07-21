// ConvexService.swift
// Wraps the official convex-swift client (product name `ConvexMobile`,
// package `convex-swift`, pinned exact 0.8.1 — see Package.swift and the
// resolved source read at packages/whistle-core/.build/checkouts/convex-swift
// before writing this file) behind WhistleCore's OWN protocol
// (`ConvexServiceProtocol`), per TECH-SPEC §4.1 `ConvexService` /
// §13 U5's pinning note: all convex-swift usage stays behind this one file
// so any API drift from its pre-1.0 status is absorbed here, not scattered
// across call sites.
//
// convex-swift's REAL API (as resolved, not as assumed from training data):
//   - `ConvexClient(deploymentUrl:)` — base client, unauthenticated.
//   - `ConvexClientWithAuth<T>(deploymentUrl:authProvider:)` — authenticated
//     client; `T` is whatever the AuthProvider's login returns.
//   - `subscribe<T: Decodable>(to: String, with: [String: ConvexEncodable?]?, yielding:) -> AnyPublisher<T, ClientError>`
//     — Combine-based, NOT AsyncSequence-based. `name` is "module:function".
//     This is ALSO the only way to run a one-shot Convex *query*: 0.8.1
//     exposes no `query(_:with:)` method at all (confirmed by reading
//     ConvexMobile.swift — only `subscribe`, `mutation`, `action` exist on
//     `ConvexClient`). Queries must therefore be driven through `subscribe`
//     and reduced to a single value (see `LiveConvexService.firstValue`).
//   - `mutation<T: Decodable>(_:with:) async throws -> T` and a
//     void-returning overload.
//   - `action<T: Decodable>(_:with:) async throws -> T` and a void-returning
//     overload.
//   - `AuthProvider<T>` protocol: `login(onIdToken:) async throws -> T`,
//     `logout() async throws`, `loginFromCache(onIdToken:) async throws -> T`,
//     `extractIdToken(from:) -> String`.
//   - Args are `[String: ConvexEncodable?]`; String/Int/Bool/Double etc.
//     conform out of the box.
//
// This file bridges that Combine-based `subscribe` surface to AsyncStream
// (WhistleCore's chosen concurrency idiom, matching CaptureStore) so callers
// never touch Combine directly.

import Combine
import Foundation
#if canImport(ConvexMobile)
    import ConvexMobile
#endif

// MARK: - AuthProvider seam (WhistleCore's own protocol)

/// Token-supplier seam so this package never depends on a concrete auth
/// implementation. `Auth0AuthProvider` (U6, app target) and
/// `MockAuthProvider` (this package, used by tests and the one-shot smoke
/// run) both implement this. Deliberately NOT the convex-swift
/// `AuthProvider<T>` protocol directly — that ties `T` to convex-swift's
/// generic client; this protocol is the stable seam WhistleCore owns.
public protocol WhistleAuthProvider: Sendable {
    /// Returns a valid JWT ID token, performing a login/refresh flow if
    /// needed. Returns `nil` if the user is unauthenticated or the session
    /// could not be refreshed (caller should present a re-auth prompt).
    func currentIdToken() async -> String?

    /// True once a token has successfully been obtained at least once this
    /// session (used by callers to decide whether to show a signed-in UI
    /// optimistically before the first token fetch completes).
    var isAuthenticated: Bool { get async }

    /// Clears any cached/stored credentials so no later launch or call can
    /// obtain a token for this session. Called by `AuthController.signOut()`
    /// -- without it, sign-out only flipped in-memory UI state while the
    /// real credentials (Keychain-backed for Auth0, in-memory for the dev/
    /// mock providers) stayed put, so a relaunch (or a second sign-in as a
    /// different user) could still mint tokens for the previous session.
    func logout() async
}

// MARK: - Mock auth provider (used by tests, and by U6's one-shot smoke run)

/// A trivial `WhistleAuthProvider` that always returns a fixed fake token
/// (or `nil`, in the `alwaysFail` mode used to simulate refresh failure).
/// The real Auth0 implementation lives in the app target (U6) — this
/// package must not depend on Auth0 or convex-swift-auth0.
public actor MockAuthProvider: WhistleAuthProvider {
    private var fixedToken: String?

    public init(fixedToken: String? = "mock-id-token") {
        self.fixedToken = fixedToken
    }

    public func currentIdToken() async -> String? {
        fixedToken
    }

    public var isAuthenticated: Bool {
        get async { fixedToken != nil }
    }

    /// Clears the mock's token, mirroring the real providers' logout()
    /// contract -- tests can assert `currentIdToken()` returns `nil`
    /// afterward. `fixedToken` is `var` (not `let`) specifically so this
    /// has somewhere to write.
    public func logout() async {
        fixedToken = nil
    }
}

// MARK: - ConvexServiceProtocol (WhistleCore's own client contract)

/// Errors surfaced by `ConvexServiceProtocol` implementations. Deliberately
/// small and I/O-shaped (not convex-swift's `ClientError`) so callers and
/// tests don't need to know convex-swift exists.
public enum ConvexServiceError: Error, Equatable {
    case notAuthenticated
    case requestFailed(String)
    case decodingFailed(String)
}

/// Typed wrapper for every §7 function, plus the two subscriptions
/// (`captures.listRecent`, `projects.list`). Defined as a protocol so
/// SyncEngine/CaptureStore consumers (and all U5 tests) depend on this
/// contract, not on convex-swift directly; `LiveConvexService` is the real
/// implementation, and tests supply a fake.
public protocol ConvexServiceProtocol: Sendable {
    // MARK: users
    func usersEnsure() async throws -> String

    /// Backend-truth identity for Settings' "Signed in as" / "Via" display
    /// (canonical-accounts plan §4) — never derived from decoding the JWT
    /// client-side. Mirrors `users:me` (a query, so this goes through
    /// `authedQuery` in `LiveConvexService`, same as `settingsGet`).
    func usersMe() async throws -> UserSelfSnapshot

    // MARK: auth lifecycle

    /// Drops the current websocket auth attachment and resets the internal
    /// attach-once gate, so the next authenticated call must re-attach with
    /// a fresh token instead of continuing to run under a previous session's
    /// already-pinned JWT. Called by `AuthController.signOut()` (and must be
    /// called before a different user signs in) -- without it, a second
    /// sign-in short-circuited the attach gate (`if attached { return true }`)
    /// and ran mutations under the FIRST user's token. Defaults to a no-op
    /// via the extension below so existing fakes/tests stay source-
    /// compatible without implementing it; `LiveConvexService` MUST override
    /// this with a real implementation.
    func detachAuth() async

    // MARK: settings
    func settingsGet() async throws -> SettingsSnapshot
    func settingsUpdate(_ patch: SettingsPatch) async throws
    func settingsSetConductorKey(_ key: String) async throws

    // MARK: conductor
    func conductorValidateKey(key: String?) async throws -> Bool
    /// Like `conductorValidateKey`, but also reports whether this key's project
    /// set differs from the previously-saved key (canonical-accounts). Has a
    /// default implementation so existing fakes/tests conform unchanged; only
    /// `LiveConvexService` decodes the extra signal.
    func conductorValidateKeyDetailed(key: String?) async throws -> ConductorValidateResult
    func conductorRefreshProjects() async throws

    // MARK: projects
    func projectsList() -> AsyncStream<[Project]>

    // MARK: templates
    func templatesGet() async throws -> TemplateSnapshot
    func templatesUpdate(body: String) async throws
    func templatesReset() async throws

    // MARK: files
    func filesGenerateUploadUrl() async throws -> String

    // MARK: captures
    func capturesCreate(_ input: CaptureCreateInput) async throws -> String
    func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]>
    func capturesList() async throws -> [ServerCaptureRecord]
    func capturesGet(id: String) async throws -> ServerCaptureRecord?
    func capturesRetry(id: String) async throws
    func capturesDeleteScreenshot(id: String) async throws
    func capturesMarkOpened(id: String) async throws
    func capturesArchive(id: String) async throws
}

/// Default no-op so pre-existing `ConvexServiceProtocol` fakes (test doubles
/// that predate `detachAuth()`) don't need to be touched just to keep
/// conforming. Only `LiveConvexService` needs a real implementation; a fake
/// that wants to assert on the call can still override it.
public extension ConvexServiceProtocol {
    func detachAuth() async {}

    /// Default: fall back to the plain bool validate and report no project-set
    /// change. `LiveConvexService` overrides this to decode the real signal;
    /// fakes/onboarding that only care about validity inherit this unchanged.
    func conductorValidateKeyDetailed(key: String?) async throws -> ConductorValidateResult {
        ConductorValidateResult(ok: try await conductorValidateKey(key: key), projectsChanged: false)
    }
}

// MARK: - Supporting request/response shapes

/// The `users:me` response (canonical-accounts plan §4): backend-truth
/// identity for display, not a decoded JWT. `email` is absent for
/// identities that never carried one (e.g. a GitHub identity with email
/// privacy enabled) — callers fall back to `authSubject`.
public struct UserSelfSnapshot: Codable, Equatable, Sendable {
    public var email: String?
    public var authSubject: String

    public init(email: String?, authSubject: String) {
        self.email = email
        self.authSubject = authSubject
    }
}

/// The richer result of validating a Conductor API key (canonical-accounts):
/// besides `ok`, `projectsChanged` reports whether this key sees a different
/// set of Conductor projects than the previously-saved key — a heads-up that
/// the key may belong to a different Conductor account than the one the user
/// runs the Conductor app under. There is no Conductor whoami endpoint, so the
/// project set is the closest available identity proxy.
public struct ConductorValidateResult: Equatable, Sendable {
    public let ok: Bool
    public let projectsChanged: Bool

    public init(ok: Bool, projectsChanged: Bool) {
        self.ok = ok
        self.projectsChanged = projectsChanged
    }
}

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public var defaultProjectId: String?
    public var agent: String
    public var model: String?
    public var screenshotsEnabled: Bool
    public var hasKey: Bool
    public var lastFour: String?

    public init(
        defaultProjectId: String?,
        agent: String,
        model: String?,
        screenshotsEnabled: Bool,
        hasKey: Bool,
        lastFour: String?
    ) {
        self.defaultProjectId = defaultProjectId
        self.agent = agent
        self.model = model
        self.screenshotsEnabled = screenshotsEnabled
        self.hasKey = hasKey
        self.lastFour = lastFour
    }
}

/// Tri-state patch value for a settings field that has a real "clear"
/// affordance in the UI (unlike `agent`/`screenshotsEnabled`, which have no
/// way to be cleared through the UI, so a plain `Optional` is enough for
/// them): `nil` means "leave untouched," `.set` writes a new value, `.clear`
/// explicitly unsets the field server-side. See `settingsUpdateArgs` for how
/// each case is encoded on the wire.
public enum SettingsFieldPatch<Value: Equatable & Sendable>: Equatable, Sendable {
    case set(Value)
    case clear
}

public struct SettingsPatch: Equatable, Sendable {
    public var defaultProjectId: SettingsFieldPatch<String>?
    public var agent: String?
    public var model: SettingsFieldPatch<String>?
    public var screenshotsEnabled: Bool?

    public init(
        defaultProjectId: SettingsFieldPatch<String>? = nil,
        agent: String? = nil,
        model: SettingsFieldPatch<String>? = nil,
        screenshotsEnabled: Bool? = nil
    ) {
        self.defaultProjectId = defaultProjectId
        self.agent = agent
        self.model = model
        self.screenshotsEnabled = screenshotsEnabled
    }
}

public struct TemplateSnapshot: Codable, Equatable, Sendable {
    public var body: String
    public var isCustomized: Bool
    public var updatedAt: Date

    public init(body: String, isCustomized: Bool, updatedAt: Date) {
        self.body = body
        self.isCustomized = isCustomized
        self.updatedAt = updatedAt
    }
}

/// Input to `captures.create` — the client (SyncEngine) → server contract,
/// TECH-SPEC §6/§7. `screenshotStorageId` is the id returned after the
/// upload-then-create sequence (generateUploadUrl → HTTP POST → storageId).
public struct CaptureCreateInput: Equatable, Sendable {
    public var clientId: String
    public var transcript: String
    public var notes: String
    public var screenshotStorageId: String?
    public var projectId: String
    public var projectName: String
    public var agent: String
    public var model: String?
    public var capturedAt: Date

    public init(
        clientId: String,
        transcript: String,
        notes: String,
        screenshotStorageId: String?,
        projectId: String,
        projectName: String,
        agent: String,
        model: String?,
        capturedAt: Date
    ) {
        self.clientId = clientId
        self.transcript = transcript
        self.notes = notes
        self.screenshotStorageId = screenshotStorageId
        self.projectId = projectId
        self.projectName = projectName
        self.agent = agent
        self.model = model
        self.capturedAt = capturedAt
    }
}

// MARK: - LiveConvexService

/// The real `ConvexServiceProtocol` implementation, backed by convex-swift's
/// `ConvexClientWithAuth<String>` (the generic payload is the JWT itself —
/// we bridge our simpler `currentIdToken()` seam into convex-swift's
/// callback-based `AuthProvider` internally, and drive the client's
/// `loginFromCache()` before authenticated calls so the token actually
/// attaches to the websocket — see the "Auth attachment" section below).
///
/// NOTE for U6: convex-swift's `subscribe` returns a Combine
/// `AnyPublisher<T, ClientError>`, not an AsyncSequence. This wrapper
/// bridges each subscription into an `AsyncStream` via `.values` /
/// `sink`, so app-target code (History window, status item) only ever
/// deals in AsyncStream, matching `CaptureStore`'s idiom.
#if canImport(ConvexMobile)
    public final class LiveConvexService: ConvexServiceProtocol, @unchecked Sendable {
        private let client: ConvexClientWithAuth<String>
        private let authGate = ConvexAuthAttachmentGate()
        private var cancellables: Set<AnyCancellable> = []
        private let lock = NSLock()

        /// - Parameters:
        ///   - deploymentUrl: Convex deployment URL (dashboard → Settings).
        ///   - authProvider: WhistleCore's own auth seam. Bridged internally
        ///     into convex-swift's `AuthProvider<String>` shape.
        public init(deploymentUrl: String, authProvider: any WhistleAuthProvider) {
            let bridge = WhistleToConvexAuthProviderBridge(authProvider: authProvider)
            self.client = ConvexClientWithAuth(deploymentUrl: deploymentUrl, authProvider: bridge)
        }

        // MARK: - Auth attachment
        //
        // convex-swift's `ConvexClientWithAuth` only attaches the JWT to the
        // underlying websocket client inside its own `login()`/
        // `loginFromCache()` — that is where `ffiClient.setAuthCallback` is
        // invoked (see .build/checkouts/convex-swift ConvexMobile.swift).
        // Constructing the client with an `AuthProvider` alone attaches
        // NOTHING: every function call runs unauthenticated and the backend
        // throws `NotAuthenticatedError` (this was the post-Auth0-sign-in
        // "Sign-in didn't complete" bug). Every authenticated entry point
        // below therefore drives `loginFromCache()` at least once before
        // talking to the backend — covering both the fresh interactive-login
        // path (AuthController calls `usersEnsure` right after Auth0 stores
        // credentials) and the app-launch cached-session path — and
        // re-attempts on the next call after a failed attach (e.g. token
        // briefly unavailable).

        private func ensureAuthAttached() async throws {
            let attached = await authGate.runIfNeeded { [client] in
                // `loginFromCache()` is itself a network-touching call with
                // no internal timeout; a hang here (before `withTimeout` ever
                // wraps the mutation/action below) would wedge syncing just
                // like a hung mutation once did. Bound it too, so a stuck
                // login defers (revert-to-`.queued` via `.notAuthenticated`)
                // instead of blocking the drain forever.
                do {
                    let result = try await Self.withTimeout(Self.authedCallTimeout) {
                        await client.loginFromCache()
                    }
                    switch result {
                    case .success:
                        return true
                    case let .failure(error):
                        NSLog("Whistle: attaching auth to Convex client failed: %@", String(describing: error))
                        return false
                    }
                } catch {
                    NSLog("Whistle: attaching auth to Convex client timed out: %@", String(describing: error))
                    return false
                }
            }
            guard attached else { throw ConvexServiceError.notAuthenticated }
        }

        /// Maps convex-swift's stringly server error for backend auth
        /// rejections (`requireIdentity` throwing `NotAuthenticatedError`)
        /// onto `ConvexServiceError.notAuthenticated`, so callers
        /// (AuthController) can distinguish "backend rejected the session"
        /// from network/transport failures.
        private static func mapAuthError(_ error: Error) -> Error {
            let description = String(describing: error)
            if description.contains("NotAuthenticatedError") || description.contains("Not authenticated") {
                return ConvexServiceError.notAuthenticated
            }
            return error
        }

        // MARK: users

        public func usersEnsure() async throws -> String {
            // Was calling `client.mutation` directly, bypassing
            // `authedMutation`'s `Self.withTimeout` wrap -- interactive
            // sign-in (which calls this right after Auth0 stores
            // credentials) could hang indefinitely on a stuck network call
            // instead of timing out into a retry like every other mutation.
            try await authedMutation("users:ensure")
        }

        /// `users:me` is a query (backend-truth identity for Settings'
        /// account tab, canonical-accounts plan §4) — routed through
        /// `authedQuery` like `settingsGet`, not `authedMutation` like
        /// `usersEnsure` above.
        public func usersMe() async throws -> UserSelfSnapshot {
            try await authedQuery("users:me")
        }

        // MARK: auth lifecycle

        /// `client.logout()` (convex-swift's own, not `WhistleAuthProvider`'s)
        /// calls the bridge's `logout()` (a no-op -- WhistleCore never owns
        /// credential storage), clears convex-swift's internal auth bridge,
        /// and tears down the websocket's auth callback; it never throws
        /// (internal errors are swallowed there, not surfaced to us). The
        /// gate reset is what actually matters for correctness: without it,
        /// `ensureAuthAttached()`'s `runIfNeeded` would see `attached == true`
        /// left over from the previous session and skip re-attaching
        /// entirely, so the very next authenticated call after a fresh
        /// sign-in would ride on convex-swift's already-torn-down (or,
        /// worse, still-live) previous-session attachment instead of pulling
        /// a fresh token via `loginFromCache()`.
        public func detachAuth() async {
            // `client.logout()` is the one Convex call this file previously
            // left unwrapped -- a wedged/non-cancellation-aware FFI logout
            // (the same class of hang `withTimeout` exists to bound; see
            // below) would await here forever. The reauth path
            // (`AuthController.signIn()`) calls `detachAuth()` while
            // `state == .signingIn`, guarded against re-entry, so a hang here
            // would permanently strand sign-in until an app relaunch. Bound
            // it like every other Convex call, and ALWAYS reset the gate
            // afterward regardless of whether logout completed or timed out
            // -- a stuck logout must not also leave the attach gate latched
            // to the old session.
            _ = try? await Self.withTimeout(Self.authedCallTimeout) { [client] in
                await client.logout()
            }
            authGate.reset()
        }

        // MARK: - Authenticated call helpers (attach auth, then call)

        /// Upper bound on how long an authenticated mutation/action (and the
        /// `loginFromCache()` attach) may block the caller. `Self.withTimeout`
        /// enforces this as a real bound — it returns the instant this
        /// elapses even if the underlying convex-swift FFI call never checks
        /// cancellation (see `withTimeout`). This is what prevents a hung call
        /// from permanently wedging `SyncEngine`'s `isDraining` reentrancy
        /// guard, the failure that once left captures unsynced for 20+ hours
        /// until an app relaunch. 15s is generous for a real slow network yet
        /// short enough that a genuine hang self-resolves into a retry quickly.
        private static let authedCallTimeout: Duration = .seconds(15)

        private func authedMutation<T: Decodable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            do {
                return try await Self.withTimeout(Self.authedCallTimeout) {
                    try await self.client.mutation(name, with: args)
                }
            } catch {
                NSLog("Whistle: Convex mutation %@ failed: %@", name, String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        private func authedMutation(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws {
            let _: String? = try await authedMutation(name, with: args)
        }

        private func authedAction<T: Decodable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            do {
                return try await Self.withTimeout(Self.authedCallTimeout) {
                    try await self.client.action(name, with: args)
                }
            } catch {
                NSLog("Whistle: Convex action %@ failed: %@", name, String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        private func authedAction(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws {
            let _: String? = try await authedAction(name, with: args)
        }

        /// Runs a one-shot Convex *query* (`settings:get`, `templates:get`,
        /// `captures:list`, `captures:get`). convex-swift 0.8.1 has no
        /// one-shot query method, so this subscribes via `client.subscribe`,
        /// takes the first yielded value, and cancels — see
        /// `LiveConvexService.firstValue` for the mechanics and
        /// `ConvexOneShotQueryTests` for coverage of that helper against a
        /// synthetic publisher (this method itself can't be driven
        /// hermetically without a live `ConvexClient`, same constraint noted
        /// in `ConvexAuthAttachmentTests`).
        private func authedQuery<T: Decodable & Sendable>(
            _ name: String, with args: [String: ConvexEncodable?]? = nil
        ) async throws -> T {
            try await ensureAuthAttached()
            do {
                return try await Self.firstValue(
                    from: client.subscribe(to: name, with: args, yielding: T.self)
                )
            } catch {
                NSLog("Whistle: Convex query %@ failed: %@", name, String(describing: error))
                throw Self.mapAuthError(error)
            }
        }

        // MARK: settings

        public func settingsGet() async throws -> SettingsSnapshot {
            try await authedQuery("settings:get")
        }

        public func settingsUpdate(_ patch: SettingsPatch) async throws {
            try await authedMutation("settings:update", with: Self.settingsUpdateArgs(patch))
        }

        /// Builds the `settings:update` argument dict, omitting unset fields
        /// entirely rather than sending them as `null`. Every field is
        /// `v.optional(...)` on the backend specifically so a partial patch
        /// can update just one field and leave the rest untouched — but a
        /// nil-valued dict entry serializes as literal JSON `null`, which
        /// `v.optional(...)` rejects. Extracted as a pure, `internal` static
        /// function so the omit-vs-null encoding (a real production fix) is
        /// unit-testable without a live `ConvexClient`; see
        /// `ConvexArgEncodingTests`.
        ///
        /// `defaultProjectId`/`model` are tri-state (`SettingsFieldPatch`):
        /// `nil` omits the key (leave untouched), `.set(v)` sends the value,
        /// and `.clear` sends an explicit key-present-with-`nil` entry, which
        /// serializes to JSON `null` — the backend's `v.optional(v.union(...,
        /// v.null()))` args treat that `null` as "unset this field" (see
        /// `settings.ts`'s `update` mutation), distinct from the key being
        /// absent entirely.
        static func settingsUpdateArgs(_ patch: SettingsPatch) -> [String: ConvexEncodable?] {
            var args: [String: ConvexEncodable?] = [:]
            encodeTriState(patch.defaultProjectId, forKey: "defaultProjectId", into: &args)
            if let agent = patch.agent {
                args["agent"] = agent
            }
            encodeTriState(patch.model, forKey: "model", into: &args)
            if let screenshotsEnabled = patch.screenshotsEnabled {
                args["screenshotsEnabled"] = screenshotsEnabled
            }
            return args
        }

        /// Encodes one tri-state field: absent (`nil`) omits the key,
        /// `.set` stores the value, `.clear` stores the key mapped to a nil
        /// value. For `.clear`, NOT `args[key] = nil` -- Dictionary's
        /// subscript setter treats assigning `nil` as *removing* the key,
        /// even though `Value` here (`ConvexEncodable?`) is itself optional.
        /// `updateValue(_:forKey:)` doesn't have that special-case, so it
        /// actually stores the key mapped to a nil value, which is what we
        /// need to encode explicit JSON `null` (the backend's clear
        /// sentinel).
        private static func encodeTriState(
            _ field: SettingsFieldPatch<String>?,
            forKey key: String,
            into args: inout [String: ConvexEncodable?]
        ) {
            switch field {
            case .set(let value):
                args[key] = value
            case .clear:
                args.updateValue(nil, forKey: key)
            case nil:
                break
            }
        }

        public func settingsSetConductorKey(_ key: String) async throws {
            try await authedMutation("settings:setConductorKey", with: ["conductorApiKey": key])
        }

        // MARK: conductor

        public func conductorValidateKey(key: String?) async throws -> Bool {
            // NOTE: this action lives in `projects.ts` on the backend (there
            // is no `conductor` Convex module — `conductorClient.ts` is a
            // plain helper, not a functions file), so the wire name is
            // "projects:validateKey", not "conductor:validateKey" (the
            // latter throws "Could not find function" on every call). The
            // handler also returns `{ ok, error? }`, not a bare bool, and
            // takes `apiKey`, not `key` — all three had to be fixed together
            // for this call to actually reach and decode correctly.
            let result: ConductorActionResult = try await authedAction(
                "projects:validateKey", with: Self.conductorValidateKeyArgs(key)
            )
            return result.ok
        }

        public func conductorValidateKeyDetailed(key: String?) async throws -> ConductorValidateResult {
            // Same wire call as `conductorValidateKey` (see the note there), but
            // surfaces the `changedFromPrevious` field the Settings key flow
            // uses to warn about a possible different-account key.
            let result: ConductorActionResult = try await authedAction(
                "projects:validateKey", with: Self.conductorValidateKeyArgs(key)
            )
            return ConductorValidateResult(
                ok: result.ok,
                projectsChanged: result.changedFromPrevious ?? false
            )
        }

        /// Builds the `projects:validateKey` argument dict, omitting the
        /// `apiKey` key entirely when `key` is `nil` rather than including it
        /// with a `nil` value. The backend validator is `v.optional(v.string())`
        /// and falls back to the stored key when the arg is absent, but (same
        /// class of bug as `capturesCreateArgs`/`settingsUpdateArgs` above) a
        /// nil-valued dict entry always serializes as literal JSON `null`,
        /// which `v.optional(...)` rejects. Extracted as a pure, `internal`
        /// static function so this is unit-testable without a live
        /// `ConvexClient`; see `ConvexArgEncodingTests`.
        static func conductorValidateKeyArgs(_ key: String?) -> [String: ConvexEncodable?]? {
            guard let key else { return nil }
            return ["apiKey": key]
        }

        public func conductorRefreshProjects() async throws {
            // Same module-name correction as `conductorValidateKey` above;
            // also decodes the actual `{ ok, error? }` response shape
            // instead of the previous `String?` guess (which would have
            // thrown a decoding error on every successful call).
            let _: ConductorActionResult = try await authedAction("projects:refreshProjects")
        }

        // MARK: projects

        public func projectsList() -> AsyncStream<[Project]> {
            asyncStream(subscribingTo: "projects:list")
        }

        // MARK: templates

        public func templatesGet() async throws -> TemplateSnapshot {
            try await authedQuery("templates:get")
        }

        public func templatesUpdate(body: String) async throws {
            try await authedMutation("templates:update", with: ["body": body])
        }

        public func templatesReset() async throws {
            try await authedMutation("templates:reset")
        }

        // MARK: files

        public func filesGenerateUploadUrl() async throws -> String {
            try await authedMutation("files:generateUploadUrl")
        }

        // MARK: captures

        public func capturesCreate(_ input: CaptureCreateInput) async throws -> String {
            try await authedMutation("captures:create", with: Self.capturesCreateArgs(input))
        }

        /// Builds the `captures:create` argument dict, omitting the two
        /// optional fields (`screenshotId`/`model`) entirely when nil rather
        /// than including them with a `nil` value. The backend validator is
        /// `v.optional(...)`, which only tolerates the key being ABSENT --
        /// convex-swift's dictionary encoder has no way to express "omit this
        /// key," so a nil-valued entry always serializes as the literal JSON
        /// `null`, which `v.optional(...)` rejects (`ArgumentValidationError`,
        /// observed in production: every capture with no model/screenshot was
        /// failing to sync). Extracted as a pure, `internal` static function
        /// so this encoding is unit-testable without a live `ConvexClient`;
        /// see `ConvexArgEncodingTests`.
        static func capturesCreateArgs(_ input: CaptureCreateInput) -> [String: ConvexEncodable?] {
            var args: [String: ConvexEncodable?] = [
                "clientId": input.clientId,
                "transcript": input.transcript,
                "notes": input.notes,
                "projectId": input.projectId,
                "projectName": input.projectName,
                "agent": input.agent,
                "capturedAt": input.capturedAt.timeIntervalSince1970 * 1000,
            ]
            if let screenshotId = input.screenshotStorageId {
                args["screenshotId"] = screenshotId
            }
            if let model = input.model {
                args["model"] = model
            }
            return args
        }

        public func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> {
            // `limit` MUST encode as a float64: the backend validator is
            // `v.float64()` and convex-swift encodes Swift `Int` as an
            // `$integer` (bigint), which Convex rejects with an
            // ArgumentValidationError (observed repeatedly in deployment
            // logs before this was fixed).
            //
            // Subscribes yielding the RAW wire shape (`ServerCaptureRecordWire`
            // — `_id`, ms-epoch float64 dates) rather than `ServerCaptureRecord`
            // directly: `ServerCaptureRecord`'s synthesized `Codable` expects
            // `id` and iso8601 dates (a contract `CaptureStore.history_cache`
            // depends on), so decoding a live Convex document straight into it
            // threw `keyNotFound` on every payload — the root cause of History
            // rows getting stuck on "Queued" forever. This wraps the wire
            // stream in a small mapping `AsyncStream` so callers keep seeing
            // `[ServerCaptureRecord]`.
            let wireStream: AsyncStream<[ServerCaptureRecordWire]> = asyncStream(
                subscribingTo: "captures:listRecent", args: ["limit": Double(limit)]
            )
            return AsyncStream { continuation in
                let mappingTask = Task {
                    for await wireRecords in wireStream {
                        continuation.yield(wireRecords.map(\.asRecord))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in mappingTask.cancel() }
            }
        }

        public func capturesList() async throws -> [ServerCaptureRecord] {
            // See `capturesListRecent` above: decodes the raw wire shape,
            // then maps to the public model.
            let wireRecords: [ServerCaptureRecordWire] = try await authedQuery("captures:list")
            return wireRecords.map(\.asRecord)
        }

        public func capturesGet(id: String) async throws -> ServerCaptureRecord? {
            // Arg key fixed to match the backend validator (`captures.get`
            // takes `captureId`, not `id`) — this had to be corrected
            // alongside the call-type fix, since routing this to the right
            // endpoint but with the wrong arg name would still fail with an
            // ArgumentValidationError. Also decodes the raw wire shape (see
            // `capturesListRecent` above) rather than `ServerCaptureRecord`
            // directly.
            let wireRecord: ServerCaptureRecordWire? = try await authedQuery(
                "captures:get", with: ["captureId": id]
            )
            return wireRecord?.asRecord
        }

        public func capturesRetry(id: String) async throws {
            // Arg key fixed to match the backend validator (`captures.retry`
            // takes `captureId`, not `id`) -- same class of bug as
            // `capturesGet` above: the call would otherwise fail with an
            // ArgumentValidationError regardless of routing to the right
            // endpoint.
            try await authedMutation("captures:retry", with: ["captureId": id])
        }

        public func capturesDeleteScreenshot(id: String) async throws {
            try await authedMutation("captures:deleteScreenshot", with: ["captureId": id])
        }

        public func capturesMarkOpened(id: String) async throws {
            try await authedMutation("captures:markOpened", with: ["captureId": id])
        }

        public func capturesArchive(id: String) async throws {
            try await authedMutation("captures:archive", with: ["captureId": id])
        }

        // MARK: - Combine -> AsyncStream bridge

        private func asyncStream<T: Decodable & Sendable>(
            subscribingTo name: String,
            args: [String: ConvexEncodable?]? = nil
        ) -> AsyncStream<T> {
            AsyncStream { continuation in
                let subscriptionTask = Task { [weak self] in
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    // Best-effort auth attach BEFORE subscribing, so
                    // authenticated queries don't land on the websocket
                    // without a JWT. An unauthenticated subscribe still goes
                    // through (matching prior behavior for the signed-out
                    // state); the server then rejects it and the stream
                    // finishes.
                    try? await self.ensureAuthAttached()
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    let cancellable = self.client.subscribe(to: name, with: args, yielding: T.self)
                        .sink(
                            receiveCompletion: { completion in
                                if case let .failure(error) = completion {
                                    NSLog(
                                        "Whistle: Convex subscription %@ failed: %@",
                                        name, String(describing: error)
                                    )
                                }
                                continuation.finish()
                            },
                            receiveValue: { value in continuation.yield(value) }
                        )
                    self.lock.withLock { _ = self.cancellables.insert(cancellable) }
                    // Replaces the task-cancelling handler installed below;
                    // by this point the task is finishing, so cancelling the
                    // subscription itself is all termination needs to do.
                    // (AsyncStream invokes a newly set onTermination
                    // immediately if the stream already terminated, so the
                    // subscription can't leak in that race.)
                    continuation.onTermination = { [weak self] _ in
                        self?.lock.withLock { _ = self?.cancellables.remove(cancellable) }
                        cancellable.cancel()
                    }
                }
                continuation.onTermination = { _ in
                    subscriptionTask.cancel()
                }
            }
        }

        // MARK: - Bounded-wait helper (shared by mutations/actions/queries)

        /// Single-resume race arbiter for `withTimeout`: whichever of the
        /// two racing tasks (the real work, or the timeout timer) finishes
        /// first delivers its result to the awaiting caller; the loser's
        /// later result is dropped. Thread-safe because the two tasks run
        /// concurrently on the global executor.
        private final class TimeoutState<T: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
            private var result: Result<T, Error>?
            private var continuation: CheckedContinuation<T, Error>?

            /// Called by both racers; only the first call wins.
            func finish(_ outcome: Result<T, Error>) {
                let waiting: CheckedContinuation<T, Error>? = lock.withLock {
                    guard result == nil else { return nil }
                    result = outcome
                    defer { continuation = nil }
                    return continuation
                }
                waiting?.resume(with: outcome)
            }

            /// Awaited exactly once by `withTimeout`. Returns as soon as the
            /// first racer finishes — it does NOT await the loser, which is
            /// the whole point (see `withTimeout`).
            func value() async throws -> T {
                try await withCheckedThrowingContinuation { cont in
                    let ready: Result<T, Error>? = lock.withLock {
                        if let result { return result }
                        continuation = cont
                        return nil
                    }
                    if let ready { cont.resume(with: ready) }
                }
            }
        }

        /// Races `operation` against `timeout`, throwing
        /// `ConvexServiceError.requestFailed(timeoutMessage)` if the timeout
        /// elapses first. Extracted so `authedMutation`/`authedAction` and
        /// `firstValue` share one bounded-wait implementation instead of
        /// duplicating the plumbing.
        ///
        /// Why this uses an unstructured `Task` + a single-resume
        /// continuation rather than `withThrowingTaskGroup`: a task group
        /// cannot return until *every* child task has finished (SE-0304),
        /// and `cancelAll()` is cooperative-only. `convex-swift` 0.8.1's
        /// `client.mutation`/`client.action` bottom out in a UniFFI polling
        /// loop (`uniffiRustCallAsync`) that never checks `Task.isCancelled`,
        /// so a genuinely-hung/dropped-connection call would keep a group
        /// child running forever and a group-based race would never return —
        /// which is exactly what previously left `SyncEngine`'s `isDraining`
        /// reentrancy guard wedged `true` for the rest of the process's life
        /// (observed live: captures sat unsynced for 20+ hours until a
        /// relaunch). Running `operation` in an unstructured task means this
        /// function returns the instant the timer fires: the timed-out call
        /// is thrown to the caller, `isDraining` resets, and retries proceed.
        /// The hung operation task is cancelled (a no-op for the
        /// non-cancellation-aware FFI call) and leaks in the background until
        /// the FFI future eventually settles on its own — a cheap suspended
        /// task, and a strictly better trade than a permanent wedge. This
        /// therefore delivers a real upper bound of `timeout` on the caller's
        /// wait, unlike the previous group-based version.
        ///
        /// Internal (not private) and free of any `LiveConvexService`
        /// instance state, so it's unit-testable in isolation against a
        /// synthetic `operation`; see `ConvexTimeoutTests`.
        static func withTimeout<T: Sendable>(
            _ timeout: Duration,
            timeoutMessage: String = "operation timed out",
            operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            let state = TimeoutState<T>()
            let work = Task {
                do { state.finish(.success(try await operation())) }
                catch { state.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                state.finish(.failure(ConvexServiceError.requestFailed(timeoutMessage)))
            }
            defer {
                timer.cancel()
                work.cancel()
            }
            return try await state.value()
        }

        // MARK: - One-shot query support (subscribe -> first value -> cancel)

        /// convex-swift 0.8.1 has no one-shot query method — `subscribe` is
        /// the only way to reach a Convex *query* function, and it's an
        /// indefinite Combine publisher. This reduces that publisher to a
        /// single value: take the first thing it yields, then cancel the
        /// underlying subscription (via `AsyncThrowingPublisher`'s
        /// cancel-on-task-cancel behavior, triggered by returning out of the
        /// `for try await` loop). Races against `timeout` so a query that
        /// never yields (dropped connection before the first snapshot, wrong
        /// function name, etc.) fails fast instead of hanging the caller.
        ///
        /// Internal (not private) — and free of any `LiveConvexService`
        /// instance state — so it's unit-testable against a synthetic
        /// `AnyPublisher` without a live `ConvexClient`; see
        /// `ConvexOneShotQueryTests`.
        ///
        /// Shares the one bounded-wait primitive (`withTimeout`) rather than
        /// duplicating the race plumbing. Unlike the mutation/action path,
        /// the underlying `AsyncThrowingPublisher` IS cancellation-aware, so
        /// when `withTimeout` cancels the losing work task the subscription
        /// is actually torn down (returning out of the `for try await` loop
        /// triggers `AnyPublisher.values`' cancel-on-task-cancel behavior).
        static func firstValue<T: Sendable>(
            from publisher: AnyPublisher<T, ClientError>,
            timeout: Duration = .seconds(10)
        ) async throws -> T {
            try await withTimeout(timeout, timeoutMessage: "query timed out waiting for a value") {
                for try await value in publisher.values {
                    return value
                }
                throw ConvexServiceError.requestFailed(
                    "query completed without yielding a value"
                )
            }
        }
    }

    /// Decodes the `{ ok: boolean, error?: string }` shape returned by the
    /// `projects:validateKey` / `projects:refreshProjects` Convex actions
    /// (see packages/backend/convex/projects.ts). `error` is currently
    /// unused (kept for future surfacing) — decoded so the field doesn't
    /// need to be absent for `Decodable` to succeed.
    struct ConductorActionResult: Decodable, Sendable {
        let ok: Bool
        let error: String?
        /// True when this key lists a different set of Conductor projects than
        /// the previously-cached key (see `projects.ts` `validateKey`). Absent
        /// on the `refreshProjects` response and on older backends — decode as
        /// optional and treat absence as "no change."
        let changedFromPrevious: Bool?
    }

    /// Serializes "attach auth once; re-attempt after failure" semantics for
    /// `LiveConvexService`. Internal (not private) so the sequencing
    /// regression can be unit-tested without a live Convex client.
    final class ConvexAuthAttachmentGate: @unchecked Sendable {
        private let lock = NSLock()
        private var attached = false

        /// Runs `attach` unless a prior attempt already succeeded. Returns
        /// the overall attached state. A failed attempt leaves the gate
        /// open so the next call re-attempts.
        func runIfNeeded(_ attach: () async -> Bool) async -> Bool {
            if lock.withLock({ attached }) { return true }
            let success = await attach()
            if success {
                lock.withLock { attached = true }
            }
            return success
        }

        /// Forces the next `runIfNeeded` call to re-attempt `attach`, even if
        /// a prior attempt already succeeded. Called on sign-out (via
        /// `detachAuth()`) so a later sign-in -- as the same user or a
        /// different one -- can't short-circuit on the old `attached == true`
        /// and skip pulling a fresh token.
        func reset() {
            lock.withLock { attached = false }
        }
    }

    /// Bridges WhistleCore's pull-based `WhistleAuthProvider.currentIdToken()`
    /// into convex-swift's `AuthProvider<String>` (login/logout/
    /// loginFromCache with an `onIdToken` callback). WhistleCore never calls
    /// convex-swift's interactive `login()` UI flow itself — the app target
    /// owns presenting login UI (Auth0 or mock); this bridge only exists so
    /// `ConvexClientWithAuth.loginFromCache()` can pull a current token via
    /// the same path every time, which is all WhistleCore needs.
    ///
    /// `T` is `String` — the JWT itself — because convex-swift's
    /// `ConvexClientWithAuth.login(strategy:)` seeds its internal
    /// `AuthTokenProviderBridge` with `extractIdToken(from: authData)`. The
    /// previous `T == Void` version of this bridge returned `""` from
    /// `extractIdToken`, which would have seeded the websocket auth
    /// callback with an empty token; returning the real JWT makes the
    /// token flow deterministic. Internal (not private) so the token
    /// passthrough is unit-testable.
    final class WhistleToConvexAuthProviderBridge: AuthProvider, @unchecked Sendable {
        typealias T = String

        let authProvider: any WhistleAuthProvider

        init(authProvider: any WhistleAuthProvider) {
            self.authProvider = authProvider
        }

        func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
            try await currentToken(onIdToken: onIdToken)
        }

        func logout() async throws {}

        func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
            try await currentToken(onIdToken: onIdToken)
        }

        func extractIdToken(from authResult: String) -> String {
            authResult
        }

        private func currentToken(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
            guard let token = await authProvider.currentIdToken() else {
                // No token available (signed out / refresh failed). Throwing
                // makes `ConvexClientWithAuth.loginFromCache()` resolve to
                // `.failure` + `.unauthenticated`, which
                // `LiveConvexService.ensureAuthAttached()` surfaces as
                // `ConvexServiceError.notAuthenticated`.
                throw ConvexServiceError.notAuthenticated
            }
            onIdToken(token)
            return token
        }
    }
#endif

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
