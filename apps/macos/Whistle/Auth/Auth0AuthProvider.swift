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
// project.yml + Config/*.xcconfig) — never hardcoded here. No real Auth0
// tenant exists yet; the checked-in xcconfig values are placeholders
// (documented in SECRETS.md, added in a later unit).

import Foundation
import WhistleCore

#if canImport(Auth0)
    import Auth0
#endif

/// Reads Auth0 tenant configuration from the app's Info.plist (populated at
/// build time from xcconfig `AUTH0_DOMAIN` / `AUTH0_CLIENT_ID` — see
/// `apps/macos/project.yml`). Both are placeholder values in this one-shot
/// build; there is no real Auth0 tenant yet.
public struct Auth0Config: Sendable {
    public let domain: String
    public let clientId: String

    public init(domain: String, clientId: String) {
        self.domain = domain
        self.clientId = clientId
    }

    /// Reads `AUTH0_DOMAIN` / `AUTH0_CLIENT_ID` from the given bundle's
    /// Info.plist. Returns `nil` if either key is missing or still the
    /// unfilled `$(AUTH0_DOMAIN)`-style xcconfig placeholder token (i.e. the
    /// xcconfig substitution never ran), so callers can degrade cleanly
    /// instead of attempting a doomed network call.
    public static func fromInfoPlist(bundle: Bundle = .main) -> Auth0Config? {
        guard
            let domain = bundle.object(forInfoDictionaryKey: "AUTH0_DOMAIN") as? String,
            let clientId = bundle.object(forInfoDictionaryKey: "AUTH0_CLIENT_ID") as? String,
            !domain.isEmpty, !clientId.isEmpty,
            !domain.hasPrefix("$("), !clientId.hasPrefix("$(")
        else {
            return nil
        }
        return Auth0Config(domain: domain, clientId: clientId)
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

    public func currentIdToken() async -> String? {
        #if canImport(Auth0)
            guard let credentialsManager else { return nil }
            return await withCheckedContinuation { continuation in
                credentialsManager.credentials { result in
                    switch result {
                    case let .success(credentials):
                        continuation.resume(returning: credentials.idToken)
                    case .failure:
                        continuation.resume(returning: nil)
                    }
                }
            }
        #else
            return nil
        #endif
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

    public func logout() async {
        #if canImport(Auth0)
            _ = credentialsManager?.clear()
        #endif
        hasAuthenticatedThisSession = false
    }
}
