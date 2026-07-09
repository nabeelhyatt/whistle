// DevSignInAuthProvider.swift
// Local development fallback for builds without a configured Auth0 tenant
// (fresh checkouts where Config/Auth0.xcconfig still carries placeholder
// values, or a deliberately unconfigured build). Wraps WhistleCore's
// `MockAuthProvider` but gates it behind an explicit user action, so the
// onboarding sign-in step still shows its gate (with a clear "Auth0 isn't
// configured" message + "Continue with local dev sign-in" button) instead
// of silently auto-signing-in at launch.
//
// The mock token is NOT a real JWT — the Convex backend will reject it for
// authenticated calls. `AuthController` treats a `users.ensure` failure as
// non-fatal in dev mode so the wizard/UI stay usable locally; account state
// is labeled "Dev sign-in" wherever it surfaces (status item menu,
// Settings → Account).

import Foundation
import WhistleCore

public actor DevSignInAuthProvider: WhistleAuthProvider {
    private let mock = MockAuthProvider()
    private var signedIn = false

    public init() {}

    // MARK: WhistleAuthProvider

    public func currentIdToken() async -> String? {
        guard signedIn else { return nil }
        return await mock.currentIdToken()
    }

    public var isAuthenticated: Bool {
        get async { signedIn }
    }

    // MARK: Interactive "login" (invoked by AuthController's
    // performInteractiveLogin seam, mirroring Auth0AuthProvider.login()).

    public func login() {
        signedIn = true
    }

    public func logout() {
        signedIn = false
    }
}
