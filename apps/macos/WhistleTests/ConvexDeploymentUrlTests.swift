// ConvexDeploymentUrlTests.swift
// Guard-rail tests for `AppDelegate.usableDeploymentUrl`, the validator that
// decides whether the Info.plist `CONVEX_URL` value is connectable or the app
// must fall back to the known-good default. The reject cases are not
// hypothetical: `"https:"` is what the xcconfig `//`-comment trap actually
// produced once (a literal URL truncates at `//`, see Config/Convex.xcconfig),
// and `"$(CONVEX_URL)"` is what an unsubstituted build setting looks like.
// Regressing to the old lax guard (non-empty + no "$(" prefix) turns these
// tests red — that guard let `"https:"` through to LiveConvexService as an
// address it could never reach.

import XCTest
@testable import Whistle

final class ConvexDeploymentUrlTests: XCTestCase {
    private let prodUrl = "https://precious-loris-637.convex.cloud"
    private let devUrl = "https://grandiose-alpaca-243.convex.cloud"

    func testValidHttpsUrlsPassThroughUnchanged() {
        XCTAssertEqual(AppDelegate.usableDeploymentUrl(prodUrl), prodUrl)
        XCTAssertEqual(AppDelegate.usableDeploymentUrl(devUrl), devUrl)
    }

    func testMissingAndEmptyValuesAreRejected() {
        XCTAssertNil(AppDelegate.usableDeploymentUrl(nil))
        XCTAssertNil(AppDelegate.usableDeploymentUrl(""))
    }

    func testUnsubstitutedXcconfigTokenIsRejected() {
        XCTAssertNil(AppDelegate.usableDeploymentUrl("$(CONVEX_URL)"))
    }

    func testCommentTruncatedSchemeOnlyValueIsRejected() {
        // The exact artifact the xcconfig `//`-comment trap shipped once:
        // scheme present, host absent. This is the case the old guard missed.
        XCTAssertNil(AppDelegate.usableDeploymentUrl("https:"))
        XCTAssertNil(AppDelegate.usableDeploymentUrl("https://"))
    }

    func testNonHttpsSchemeIsRejected() {
        XCTAssertNil(AppDelegate.usableDeploymentUrl("http://precious-loris-637.convex.cloud"))
        XCTAssertNil(AppDelegate.usableDeploymentUrl("ws://precious-loris-637.convex.cloud"))
    }

    func testBareHostWithoutSchemeIsRejected() {
        XCTAssertNil(AppDelegate.usableDeploymentUrl("precious-loris-637.convex.cloud"))
    }

    func testSchemeCaseIsNormalized() {
        // URL(string:) preserves case in the scheme; the guard lowercases it.
        let mixedCase = "HTTPS://precious-loris-637.convex.cloud"
        XCTAssertEqual(AppDelegate.usableDeploymentUrl(mixedCase), mixedCase)
    }
}
