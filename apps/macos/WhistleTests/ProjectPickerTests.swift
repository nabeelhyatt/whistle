// ProjectPickerTests.swift
// Multi-org plan: `ProjectPicker.groupedByOrg`/`distinctOrgLabelCount` are
// pure functions over `[Project]` (no SwiftUI rendering asserted here, per
// the repo's rule that Menu sectioning is MANUAL-QA's job) —
//   - Happy: multiple distinct orgLabels group in first-appearance order,
//     with a leading unlabeled group for legacy (nil-orgLabel) projects.
//   - Happy: a single distinct orgLabel (or none at all) reports no
//     grouping is needed, matching today's flat menu.

import XCTest
@testable import Whistle
@testable import WhistleCore

final class ProjectPickerTests: XCTestCase {
    private func project(_ id: String, _ name: String, orgLabel: String?) -> Project {
        Project(id: id, name: name, gitRemote: "git@example.com:\(id).git", orgId: orgLabel.map { "org-\($0)" }, orgLabel: orgLabel)
    }

    // MARK: Happy: multi-org groups in first-appearance order, legacy group leads

    func testGroupedByOrgGroupsInFirstAppearanceOrderWithLeadingUnlabeledGroup() {
        let projects = [
            project("p1", "Legacy One", orgLabel: nil),
            project("p2", "Org B One", orgLabel: "Org B"),
            project("p3", "Org A One", orgLabel: "Org A"),
            project("p4", "Org B Two", orgLabel: "Org B"),
            project("p5", "Legacy Two", orgLabel: nil),
        ]

        let groups = ProjectPicker.groupedByOrg(projects)

        XCTAssertEqual(groups.map(\.orgLabel), [nil, "Org B", "Org A"])
        XCTAssertEqual(groups.map { $0.projects.map(\.id) }, [
            ["p1", "p5"],
            ["p2", "p4"],
            ["p3"],
        ])
    }

    func testDistinctOrgLabelCountCountsOnlyNonNilLabels() {
        let projects = [
            project("p1", "Legacy", orgLabel: nil),
            project("p2", "Org B", orgLabel: "Org B"),
            project("p3", "Org A", orgLabel: "Org A"),
        ]

        XCTAssertEqual(ProjectPicker.distinctOrgLabelCount(projects), 2)
    }

    // MARK: Happy: single (or no) distinct orgLabel -> no grouping needed, matches today's flat menu

    func testDistinctOrgLabelCountIsAtMostOneWhenSingleOrgOrAllLegacy() {
        let singleOrg = [
            project("p1", "One", orgLabel: "Only Org"),
            project("p2", "Two", orgLabel: "Only Org"),
        ]
        XCTAssertEqual(ProjectPicker.distinctOrgLabelCount(singleOrg), 1)

        let allLegacy = [
            project("p1", "One", orgLabel: nil),
            project("p2", "Two", orgLabel: nil),
        ]
        XCTAssertEqual(ProjectPicker.distinctOrgLabelCount(allLegacy), 0)
    }

    func testGroupedByOrgReturnsASingleGroupWhenNoProjectsHaveAnOrgLabel() {
        let projects = [
            project("p1", "One", orgLabel: nil),
            project("p2", "Two", orgLabel: nil),
        ]

        let groups = ProjectPicker.groupedByOrg(projects)

        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?.orgLabel)
        XCTAssertEqual(groups.first?.projects.map(\.id), ["p1", "p2"])
    }

    // MARK: F7: the `"unlabeled"` sentinel must not collide with a real org
    // labeled exactly that (pre-fix, `id` was `orgLabel ?? "__unlabeled__"`,
    // so an org literally named "__unlabeled__" would collide with the
    // legacy leading group's id).

    func testGroupIdsDoNotCollideWhenAnOrgIsLiterallyNamedTheOldSentinel() {
        let projects = [
            project("p1", "Legacy", orgLabel: nil),
            project("p2", "Sneaky", orgLabel: "__unlabeled__"),
        ]

        let groups = ProjectPicker.groupedByOrg(projects)

        XCTAssertEqual(groups.count, 2)
        let ids = Set(groups.map(\.id))
        XCTAssertEqual(ids.count, 2, "the legacy unlabeled group and a real org named \"__unlabeled__\" must get distinct ids")
    }

    func testGroupIdsAreStableAndUniqueForDistinctLabels() {
        let projects = [
            project("p1", "Legacy", orgLabel: nil),
            project("p2", "Org A One", orgLabel: "Org A"),
            project("p3", "Org B One", orgLabel: "Org B"),
        ]

        let groups = ProjectPicker.groupedByOrg(projects)
        let ids = groups.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count, "every group's id must be unique")
        // Stable: recomputing from the same input yields the same ids.
        XCTAssertEqual(ProjectPicker.groupedByOrg(projects).map(\.id), ids)
    }
}
