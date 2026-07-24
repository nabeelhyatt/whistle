// Auth0AuthProvider.swift
// App-target implementation of WhistleCore's `WhistleAuthProvider` seam
// (packages/whistle-core/Sources/WhistleCore/ConvexService.swift). This type
// implements ONLY `WhistleAuthProvider` — it never touches ConvexMobile
// directly; `ConvexService`/`LiveConvexService` is the only file in the app
// that talks to convex-swift, per TECH-SPEC §4.1/§9.
//
// Wired but unexercised in this unit (U6): no automated test drives a real
// Auth0 login. All automated tests and the one-shot smoke run use
// `MockAuthProvider` (WhistleCore). Real Auth0 tenant provisioning and a
// real `ASWebAuthenticationSession` round-trip inside the sandboxed signed
// app are `docs/MANUAL-QA.md` items (TECH-SPEC §9).
//
// Config (domain/client ID) is read from Info.plist keys injected via
// xcconfig build settings (`AUTH0_DOMAIN` / `AUTH0_CLIENT_ID`, see
// project.yml + Config/*.xcconfig) — never hardcoded here. The checked-in
// xcconfig now carries the real tenant's public identifiers (SECRETS.md);
// if a checkout ever reverts to placeholder values, `Auth0Config`
// detects them and the app degrades to the local dev sign-in fallback
// (`DevSignInAuthProvider`) instead of attempting a doomed network call.

import Foundation
import WhistleCore

#if canImport(Auth0)
    import Auth0
#endif

/// Reads Auth0 tenant configuration from the app's Info.plist (populated at
/// build time from xcconfig `AUTH0_DOMAIN` / `AUTH0_CLIENT_ID` — see
/// `apps/macos/project.yml` and `Config/Auth0.xcconfig`).
public struct Auth0Config: Sendable {
    public let domain: String
    public let clientId: String

    public init(domain: String, clientId: String) {
        self.domain = domain
        self.clientId = clientId
    }

    /// Reads `AUTH0_DOMAIN` / `AUTH0_CLIENT_ID` from the given bundle's
    /// Info.plist. Returns `nil` if either key is missing or is still a
    /// placeholder — either the unfilled `$(AUTH0_DOMAIN)`-style xcconfig
    /// substitution token, or the literal placeholder values checked into
    /// `Config/Auth0.xcconfig` before a real tenant was provisioned
    /// ("your-tenant.us.auth0.com" / "REPLACE_WITH_…"). Rejecting both
    /// shapes lets callers degrade cleanly (dev sign-in fallback) instead
    /// of attempting a doomed network call against a nonexistent host.
    public static func fromInfoPlist(bundle: Bundle = .main) -> Auth0Config? {
        guard
            let domain = bundle.object(forInfoDictionaryKey: "AUTH0_DOMAIN") as? String,
            let clientId = bundle.object(forInfoDictionaryKey: "AUTH0_CLIENT_ID") as? String
        else {
            return nil
        }
        return validated(domain: domain, clientId: clientId)
    }

    /// Placeholder/shape validation, separated from the Bundle read so it's
    /// directly unit-testable. Returns `nil` for empty values, unfilled
    /// `$(…)` xcconfig tokens, and the literal pre-provisioning
    /// placeholders.
    static func validated(domain: String, clientId: String) -> Auth0Config? {
        guard !domain.isEmpty, !clientId.isEmpty,
              !isPlaceholder(domain), !isPlaceholder(clientId)
        else {
            return nil
        }
        return Auth0Config(domain: domain, clientId: clientId)
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("$(")
            || value.hasPrefix("REPLACE_WITH")
            || value.hasPrefix("your-tenant.")
            || value.hasPrefix("placeholder.")
    }
}

/// Errors specific to the Auth0 login/refresh flow, surfaced to
/// `AuthController` so it can drive UI state transitions (e.g. re-auth
/// prompt on refresh failure) without depending on Auth0.swift's own error
/// types.
public enum Auth0AuthError: Error, Equatable {
    case notConfigured
    case loginFailed(String)
    case refreshFailed(String)
    case noStoredCredentials
}

/// `WhistleAuthProvider` implementation backed by Auth0.swift's
/// `CredentialsManager` (Keychain-backed session storage) +
/// `WebAuthentication` (interactive login via `ASWebAuthenticationSession`).
///
/// This type implements ONLY `WhistleAuthProvider` (the pull-based
/// `currentIdToken()` seam WhistleCore defines) — never convex-swift's
/// `AuthProvider<T>` directly. `ConvexService` bridges the two internally.
public actor Auth0AuthProvider: WhistleAuthProvider {
    private let config: Auth0Config?
    private var hasAuthenticatedThisSession = false

    #if canImport(Auth0)
        private lazy var credentialsManager: CredentialsManager? = {
            guard let config else { return nil }
            let auth0 = Auth0.authentication(clientId: config.clientId, domain: config.domain)
            return CredentialsManager(authentication: auth0)
        }()
    #endif

    public init(config: Auth0Config? = .fromInfoPlist()) {
        self.config = config
    }

    // MARK: WhistleAuthProvider

    /// Leeway (seconds) before the ID token's `exp` at which we proactively
    /// force a refresh-token exchange. The ID token is the JWT handed to
    /// Convex; if it's already expired (or about to be) when a call goes out,
    /// the backend rejects it as `NotAuthenticatedError`. 5 minutes is
    /// comfortably longer than any single Convex round-trip yet short relative
    /// to the ID token's lifetime, so we refresh at most once per token window.
    static let idTokenRefreshLeeway: TimeInterval = 300

    /// Returns a currently-valid Auth0 **ID token** for Convex, proactively
    /// renewing it when it is at/near expiry.
    ///
    /// Why this is not just `credentialsManager.credentials { $0.idToken }`:
    /// Auth0.swift's `CredentialsManager` decides whether to renew by looking
    /// at the **access token**'s expiry (`Credentials.expiresIn`), and only
    /// then hands back whatever `idToken` it has stored. But login here uses
    /// no `.audience()`, so the access token is an opaque `/userinfo` token
    /// (~24h) while the ID token expires at the tenant default (~10h). In the
    /// window between those two lifetimes the manager considers the credentials
    /// "valid" and returns a **stale, already-expired ID token** — Convex then
    /// rejects every call and the app escalates to "session expired". We close
    /// that window by decoding the ID token's own `exp` and forcing
    /// `renew()` (a real refresh-token exchange) when it's within the leeway.
    public func currentIdToken() async -> String? {
        #if canImport(Auth0)
            guard let credentialsManager else { return nil }
            guard let credentials = await storedCredentials(credentialsManager) else {
                return nil
            }
            let idTokenTTL = Self.idTokenSecondsRemaining(credentials.idToken)
            let ttlDescription = idTokenTTL.map { String(format: "%.0f", $0) } ?? "unknown"
            NSLog(
                "Whistle: currentIdToken — idToken ttl=%@s, accessToken expiresIn=%.0fs",
                ttlDescription,
                credentials.expiresIn.timeIntervalSinceNow
            )
            // Fresh enough: hand back the cached ID token unchanged.
            if let ttl = idTokenTTL, ttl > Self.idTokenRefreshLeeway {
                return credentials.idToken
            }
            // Missing/undecodable `exp` or within the leeway: force a real
            // refresh-token exchange so Convex always gets a fresh ID token.
            NSLog("Whistle: ID token at/near expiry (ttl=%@s) — forcing refresh-token exchange", ttlDescription)
            guard let renewed = await renewedCredentials(credentialsManager) else {
                // Renew failed (refresh token revoked/expired, offline). Returning
                // nil makes the *explicit* attach path
                // (WhistleToConvexAuthProviderBridge → `ensureAuthAttached`'s
                // `loginFromCache`) throw `.notAuthenticated` so the app escalates
                // to reauth rather than resending a stale token. Caveat: convex-
                // swift's own `fetchToken(forceRefresh:)` FFI path swallows that
                // throw with `try?` and keeps its previously cached token, so a
                // stale token can still ride *that* path until the deferral streak
                // escalates. Clearing it (re-attach on failure) is tracked as
                // deferred work in docs/BACKLOG.md (Phase C, item 3).
                NSLog("Whistle: ID token refresh failed — surfacing as unauthenticated")
                return nil
            }
            return renewed.idToken
        #else
            return nil
        #endif
    }

    #if canImport(Auth0)
        /// Bridges `CredentialsManager.credentials` (callback) to async. Auto-
        /// renews only when the *access token* is expired (see `currentIdToken`).
        private func storedCredentials(_ manager: CredentialsManager) async -> Credentials? {
            await withCheckedContinuation { continuation in
                manager.credentials { result in
                    switch result {
                    case let .success(credentials): continuation.resume(returning: credentials)
                    case .failure: continuation.resume(returning: nil)
                    }
                }
            }
        }

        /// Bridges `CredentialsManager.renew` (callback) to async — a forced
        /// refresh-token exchange that returns (and persists) fresh credentials,
        /// including a new ID token, regardless of access-token validity.
        private func renewedCredentials(_ manager: CredentialsManager) async -> Credentials? {
            await withCheckedContinuation { continuation in
                manager.renew { result in
                    switch result {
                    case let .success(credentials): continuation.resume(returning: credentials)
                    case .failure: continuation.resume(returning: nil)
                    }
                }
            }
        }
    #endif

    /// Seconds remaining until a compact-JWS JWT's `exp` claim, or `nil` if the
    /// token can't be decoded or carries no numeric `exp`. Dependency-free (no
    /// JWTDecode import — it isn't a declared product dependency of this
    /// target): splits on `.`, base64url-decodes the payload segment, and reads
    /// `exp`. Pure and `static` so it's unit-testable without a live Auth0
    /// (`Auth0IdTokenExpiryTests`); the surrounding `currentIdToken()` renew
    /// orchestration can't be, per this file's MockAuthProvider note.
    static func idTokenSecondsRemaining(_ jwt: String, now: Date = Date()) -> TimeInterval? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return nil
        }
        // JSON numbers bridge to NSNumber; accept either an integer or
        // fractional `exp` (seconds since the Unix epoch).
        let exp: Double
        if let d = json["exp"] as? Double {
            exp = d
        } else if let i = json["exp"] as? Int {
            exp = Double(i)
        } else {
            return nil
        }
        return Date(timeIntervalSince1970: exp).timeIntervalSince(now)
    }

    /// Decodes a base64url segment (JWT-style: `-`/`_` alphabet, no padding).
    static func base64URLDecode(_ segment: String) -> Data? {
        var s = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s)
    }

    public var isAuthenticated: Bool {
        get async {
            #if canImport(Auth0)
                credentialsManager?.hasValid() ?? false
            #else
                false
            #endif
        }
    }

    // MARK: Interactive login (invoked by AuthController, not part of the
    // WhistleAuthProvider protocol — WhistleCore never presents login UI).

    /// Starts the interactive Auth0 login flow (Universal Login via
    /// `ASWebAuthenticationSession`). Must be called from the main actor
    /// context that owns a presentation anchor; `AuthController` is
    /// responsible for hopping to `@MainActor` around this call.
    public func login() async throws {
        guard config != nil else { throw Auth0AuthError.notConfigured }
        #if canImport(Auth0)
            guard let credentialsManager else { throw Auth0AuthError.notConfigured }
            let credentials = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Credentials, Error>) in
                Auth0
                    .webAuth(clientId: config!.clientId, domain: config!.domain)
                    .scope("openid profile email offline_access")
                    .start { result in
                        switch result {
                        case let .success(credentials):
                            continuation.resume(returning: credentials)
                        case let .failure(error):
                            continuation.resume(throwing: Auth0AuthError.loginFailed(error.localizedDescription))
                        }
                    }
            }
            _ = credentialsManager.store(credentials: credentials)
            hasAuthenticatedThisSession = true
        #else
            throw Auth0AuthError.notConfigured
        #endif
    }

    // MARK: WhistleAuthProvider (logout)

    /// Satisfies `WhistleAuthProvider.logout()` -- clears the Keychain-backed
    /// `CredentialsManager` entry so no later launch (or concurrent call)
    /// can mint a token for this session. Previously had zero callers; wired
    /// into `AuthController.signOut()`.
    public func logout() async {
        #if canImport(Auth0)
            _ = credentialsManager?.clear()
        #endif
        hasAuthenticatedThisSession = false
    }
}
