// ConvexDecodingTests.swift
// Round-trip coverage for the custom `Decodable` paths introduced alongside
// the arg-encoding fix (see ConvexArgEncodingTests): `SettingsSnapshot`'s
// hand-rolled `init(from:)` (lenient `environment` decode, R4) and
// `ConductorSetAndValidateActionResult`'s all-optional
// `{ ok, environment?, projectsChanged?, error? }` shape from
// `projects:setAndValidateKey`. Both decode real JSON strings (not
// `Codable`-encoded-then-decoded round trips) so a change to the wire shape
// -- or to the leniency behavior -- fails loudly here instead of only in
// production.

import XCTest

@testable import WhistleCore

final class ConvexDecodingTests: XCTestCase {
    // MARK: SettingsSnapshot

    func testSettingsSnapshotDecodesWithEnvironmentPresent() throws {
        let json = """
        {
            "defaultProjectId": "proj-1",
            "agent": "claude",
            "model": "opus-4.8",
            "screenshotsEnabled": true,
            "hasKey": true,
            "lastFour": "1234",
            "environment": "staging"
        }
        """
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.defaultProjectId, "proj-1")
        XCTAssertEqual(snapshot.agent, "claude")
        XCTAssertEqual(snapshot.model, "opus-4.8")
        XCTAssertTrue(snapshot.screenshotsEnabled)
        XCTAssertTrue(snapshot.hasKey)
        XCTAssertEqual(snapshot.lastFour, "1234")
        XCTAssertEqual(snapshot.environment, .staging)
    }

    func testSettingsSnapshotDefaultsEnvironmentToProdWhenAbsent() throws {
        // Legacy/pre-rollout rows omit `environment` entirely (R4) -- the
        // custom `init(from:)` must default to `.prod` instead of throwing.
        let json = """
        {
            "defaultProjectId": null,
            "agent": "claude",
            "model": null,
            "screenshotsEnabled": false,
            "hasKey": false,
            "lastFour": null
        }
        """
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(snapshot.defaultProjectId)
        XCTAssertEqual(snapshot.agent, "claude")
        XCTAssertNil(snapshot.model)
        XCTAssertFalse(snapshot.screenshotsEnabled)
        XCTAssertFalse(snapshot.hasKey)
        XCTAssertNil(snapshot.lastFour)
        XCTAssertEqual(snapshot.environment, .prod, "absent `environment` must default to .prod, not throw")
    }

    #if canImport(ConvexMobile)
        // MARK: ConductorSetAndValidateActionResult (projects:setAndValidateKey)

        private typealias ActionResult = ConductorSetAndValidateActionResult

        func testConductorSetAndValidateActionResultDecodesOkShape() throws {
            let json = """
            {
                "ok": true,
                "environment": "prod",
                "projectsChanged": true
            }
            """
            let data = Data(json.utf8)
            let decoder = JSONDecoder()
            let result: ActionResult = try decoder.decode(ActionResult.self, from: data)

            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.environment, ConductorEnvironment.prod)
            XCTAssertEqual(result.projectsChanged, true)
            XCTAssertNil(result.error)
        }

        func testConductorSetAndValidateActionResultDecodesFailureShape() throws {
            // On rejection the action only returns `{ ok: false, error }` --
            // `environment`/`projectsChanged` are absent, not null, and must
            // decode to nil rather than throwing.
            let json = """
            {
                "ok": false,
                "error": "invalid key"
            }
            """
            let data = Data(json.utf8)
            let decoder = JSONDecoder()
            let result: ActionResult = try decoder.decode(ActionResult.self, from: data)

            XCTAssertFalse(result.ok)
            XCTAssertNil(result.environment)
            XCTAssertNil(result.projectsChanged)
            XCTAssertEqual(result.error, "invalid key")
        }
    #endif
}
