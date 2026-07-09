// Auth0ConfigTests.swift
// Placeholder-detection for Auth0 tenant config: values that are unfilled
// `$(…)` xcconfig tokens OR the literal pre-provisioning placeholders
// ("your-tenant.us.auth0.com" / "REPLACE_WITH_…" / "placeholder.…") must be
// rejected so the app degrades to the dev sign-in fallback instead of
// attempting a network call against a nonexistent host ("Unknown host").

import XCTest
@testable import Whistle

final class Auth0ConfigTests: XCTestCase {
    private let realDomain = "dev-jrm7z08z1lx4u3pg.us.auth0.com"
    private let realClientId = "jvCvc5uGUuTJjirvZMI7RAl7A3wrduYj"

    func testRealValuesAreAccepted() {
        let config = Auth0Config.validated(domain: realDomain, clientId: realClientId)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.domain, realDomain)
        XCTAssertEqual(config?.clientId, realClientId)
    }

    func testUnfilledXcconfigTokensAreRejected() {
        XCTAssertNil(Auth0Config.validated(domain: "$(AUTH0_DOMAIN)", clientId: realClientId))
        XCTAssertNil(Auth0Config.validated(domain: realDomain, clientId: "$(AUTH0_CLIENT_ID)"))
    }

    func testLiteralPlaceholderDomainIsRejected() {
        XCTAssertNil(Auth0Config.validated(domain: "your-tenant.us.auth0.com", clientId: realClientId))
        XCTAssertNil(Auth0Config.validated(domain: "placeholder.us.auth0.com", clientId: realClientId))
    }

    func testLiteralPlaceholderClientIdIsRejected() {
        XCTAssertNil(Auth0Config.validated(domain: realDomain, clientId: "REPLACE_WITH_REAL_AUTH0_CLIENT_ID"))
    }

    func testEmptyValuesAreRejected() {
        XCTAssertNil(Auth0Config.validated(domain: "", clientId: realClientId))
        XCTAssertNil(Auth0Config.validated(domain: realDomain, clientId: ""))
    }
}
