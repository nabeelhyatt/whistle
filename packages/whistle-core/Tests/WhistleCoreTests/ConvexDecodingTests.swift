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
    // MARK: Project (multi-org plan: orgId/orgLabel)

    func testProjectDecodesOldShapeWithNilOrgFields() throws {
        // A legacy `projects.list` payload predating the multi-org plan --
        // no `orgId`/`orgLabel` keys at all. Must decode with both nil, not
        // throw.
        let json = """
        {
            "id": "proj-1",
            "name": "Project One",
            "gitRemote": "git@example.com:proj-1.git"
        }
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.id, "proj-1")
        XCTAssertEqual(project.name, "Project One")
        XCTAssertEqual(project.gitRemote, "git@example.com:proj-1.git")
        XCTAssertNil(project.orgId)
        XCTAssertNil(project.orgLabel)
    }

    func testProjectDecodesNewShapeWithOrgFieldsPopulated() throws {
        let json = """
        {
            "id": "proj-1",
            "name": "Project One",
            "gitRemote": "git@example.com:proj-1.git",
            "orgId": "org-abc",
            "orgLabel": "Acme Inc"
        }
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.orgId, "org-abc")
        XCTAssertEqual(project.orgLabel, "Acme Inc")
    }

    func testProjectEncodeDecodeRoundTripsOrgFields() throws {
        let project = Project(id: "p1", name: "One", gitRemote: "r1", orgId: "org-1", orgLabel: "Org One")
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded, project)

        // And a project with no org (the common single-key/legacy case)
        // round-trips with both fields nil, not empty strings or omitted
        // keys that would break on an old client.
        let noOrgProject = Project(id: "p2", name: "Two", gitRemote: "r2")
        let noOrgData = try JSONEncoder().encode(noOrgProject)
        let noOrgDecoded = try JSONDecoder().decode(Project.self, from: noOrgData)
        XCTAssertEqual(noOrgDecoded, noOrgProject)
    }

    // MARK: OrgKeyInfo (orgs:list)

    func testOrgKeyInfoDecodesWithOrganizationNamePresent() throws {
        let json = """
        {
            "orgId": "org-abc",
            "label": "Default",
            "organizationName": "Acme Inc",
            "displayName": "Acme Inc",
            "lastFour": "1234",
            "environment": "prod",
            "createdAt": 1700000000000
        }
        """
        let info = try JSONDecoder().decode(OrgKeyInfo.self, from: Data(json.utf8))

        XCTAssertEqual(info.orgId, "org-abc")
        XCTAssertEqual(info.label, "Default")
        XCTAssertEqual(info.organizationName, "Acme Inc")
        XCTAssertEqual(info.displayName, "Acme Inc")
        XCTAssertEqual(info.lastFour, "1234")
        XCTAssertEqual(info.environment, .prod)
        XCTAssertEqual(info.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testOrgKeyInfoDecodesWithOrganizationNameAbsent() throws {
        // `organizationName` is absent (not null) until GET /me has ever
        // succeeded for this org -- `displayName` falls back to `label`
        // server-side, but the client must still decode this shape.
        let json = """
        {
            "orgId": "org-abc",
            "label": "Default",
            "displayName": "Default",
            "lastFour": "1234",
            "environment": "staging",
            "createdAt": 1700000000000
        }
        """
        let info = try JSONDecoder().decode(OrgKeyInfo.self, from: Data(json.utf8))

        XCTAssertNil(info.organizationName)
        XCTAssertEqual(info.displayName, "Default")
        XCTAssertEqual(info.environment, .staging)
    }

    func testOrgKeyInfoEncodeDecodeRoundTrips() throws {
        let info = OrgKeyInfo(
            orgId: "org-abc",
            label: "Default",
            organizationName: nil,
            displayName: "Default",
            lastFour: "5678",
            environment: .prod,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(OrgKeyInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

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

        // MARK: OrgAddKeyActionResult (orgs:addKey)

        private typealias AddKeyResult = OrgAddKeyActionResult

        func testOrgAddKeyActionResultDecodesOkShape() throws {
            let json = """
            {
                "ok": true,
                "orgId": "org-new",
                "environment": "prod",
                "projectsChanged": false
            }
            """
            let result = try JSONDecoder().decode(AddKeyResult.self, from: Data(json.utf8))

            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.orgId, "org-new")
            XCTAssertEqual(result.environment, ConductorEnvironment.prod)
            XCTAssertEqual(result.projectsChanged, false)
            XCTAssertNil(result.error)
        }

        func testOrgAddKeyActionResultDecodesFailureShape() throws {
            // On rejection the action only returns `{ ok: false, error }` --
            // `orgId`/`environment`/`projectsChanged` are absent, not null,
            // and must decode to nil rather than throwing.
            let json = """
            {
                "ok": false,
                "error": "invalid key"
            }
            """
            let result = try JSONDecoder().decode(AddKeyResult.self, from: Data(json.utf8))

            XCTAssertFalse(result.ok)
            XCTAssertNil(result.orgId)
            XCTAssertNil(result.environment)
            XCTAssertNil(result.projectsChanged)
            XCTAssertEqual(result.error, "invalid key")
        }
    #endif
}
