// Auth0IdTokenExpiryTests.swift
// Covers `Auth0AuthProvider.idTokenSecondsRemaining` — the pure, dependency-
// free JWT `exp` decode that drives the proactive refresh in
// `currentIdToken()`. The renew orchestration around it can't be unit-tested
// without a live Auth0 (this file's provider talks to a real
// `CredentialsManager`), so the decode seam is where the logic gets proven:
// it decides whether Convex is handed a fresh or an about-to-expire ID token.

import XCTest
@testable import Whistle

final class Auth0IdTokenExpiryTests: XCTestCase {
    /// Builds a compact-JWS JWT (`header.payload.signature`) whose payload is
    /// the given claims, base64url-encoded without padding — mirroring what a
    /// real Auth0 ID token looks like on the wire.
    private func makeJWT(claims: [String: Any]) -> String {
        let header = base64URLEncode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = base64URLEncode(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).c2lnbmF0dXJl"
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFutureExpReturnsPositiveTTL() {
        let jwt = makeJWT(claims: ["exp": now.timeIntervalSince1970 + 3600])
        let ttl = Auth0AuthProvider.idTokenSecondsRemaining(jwt, now: now)
        XCTAssertEqual(try XCTUnwrap(ttl), 3600, accuracy: 1)
    }

    func testPastExpReturnsNegativeTTL() {
        let jwt = makeJWT(claims: ["exp": now.timeIntervalSince1970 - 600])
        let ttl = Auth0AuthProvider.idTokenSecondsRemaining(jwt, now: now)
        XCTAssertEqual(try XCTUnwrap(ttl), -600, accuracy: 1)
    }

    func testIntegerExpIsDecoded() {
        // `exp` as a JSON integer (the common shape) decodes the same as a
        // fractional value.
        let jwt = makeJWT(claims: ["exp": Int(now.timeIntervalSince1970) + 120])
        let ttl = Auth0AuthProvider.idTokenSecondsRemaining(jwt, now: now)
        XCTAssertEqual(try XCTUnwrap(ttl), 120, accuracy: 1)
    }

    func testTwoSegmentTokenDecodes() {
        // The decoder accepts `header.payload` with no signature segment
        // (`segments.count >= 2`, not `== 3`). Assert that boundary actually
        // decodes rather than being rejected as malformed.
        let header = base64URLEncode(Data(#"{"alg":"RS256"}"#.utf8))
        let payload = base64URLEncode(try! JSONSerialization.data(withJSONObject: ["exp": now.timeIntervalSince1970 + 500]))
        let ttl = Auth0AuthProvider.idTokenSecondsRemaining("\(header).\(payload)", now: now)
        XCTAssertEqual(try XCTUnwrap(ttl), 500, accuracy: 1)
    }

    func testMissingExpClaimReturnsNil() {
        let jwt = makeJWT(claims: ["sub": "auth0|abc", "aud": "client"])
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining(jwt, now: now))
    }

    func testNonNumericExpReturnsNil() {
        let jwt = makeJWT(claims: ["exp": "not-a-number"])
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining(jwt, now: now))
    }

    func testMalformedTokenReturnsNil() {
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining("not-a-jwt", now: now))
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining("", now: now))
        // Payload segment present but not valid base64url (non-alphabet chars) —
        // fails at the base64url-decode stage before JSON parsing.
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining("aaa.!!!.bbb", now: now))
    }

    func testValidBase64ButNotJSONObjectReturnsNil() {
        // Payload decodes as valid base64url but the bytes are NOT a JSON object —
        // exercises the `JSONSerialization ... as? [String: Any]` failure branch,
        // which the base64url-failure cases above never reach.
        let header = base64URLEncode(Data(#"{"alg":"RS256"}"#.utf8))
        // (a) valid base64url, but the decoded bytes aren't JSON at all.
        let notJSON = "\(header).\(base64URLEncode(Data("this is not json".utf8))).sig"
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining(notJSON, now: now))
        // (b) valid JSON, but a top-level array rather than an object.
        let jsonArray = "\(header).\(base64URLEncode(try! JSONSerialization.data(withJSONObject: [1, 2, 3]))).sig"
        XCTAssertNil(Auth0AuthProvider.idTokenSecondsRemaining(jsonArray, now: now))
    }

    func testPayloadNeedingBase64URLPaddingDecodes() {
        // Exercise several claim sizes so at least one produces a payload whose
        // base64url length isn't a multiple of 4 (needs re-padding to decode).
        for i in 0..<4 {
            let claims: [String: Any] = [
                "exp": now.timeIntervalSince1970 + 1000,
                "sub": String(repeating: "x", count: i),
            ]
            let ttl = Auth0AuthProvider.idTokenSecondsRemaining(makeJWT(claims: claims), now: now)
            XCTAssertEqual(try XCTUnwrap(ttl), 1000, accuracy: 1, "padding case i=\(i)")
        }
    }
}
