// ProjectsSyncCoordinatorTests.swift
// Covers the capture-panel-shows-"No projects" bug fix: nothing was ever
// persisting `projects.list` subscription yields into
// `CaptureStore.projects_snapshot` -- the table the capture panel's
// `ProjectPicker` (via `CaptureViewModel.loadProjects()`) actually reads.
// `ProjectsSyncCoordinator` is the missing app-wide subscription + the
// stale-refresh trigger (TECH-SPEC §7: "conductor.refreshProjects ...
// called when stale (>1h) or on picker open"), both exercised here against
// a fake `ConvexServiceProtocol` -- no real network (plan U5 convention).

import Foundation
import XCTest
@testable import WhistleCore

final class ProjectsSyncCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Persistence wiring: fake ConvexService yield -> snapshot
    // written -> picker data available (CaptureStore.projectsSnapshot() is
    // exactly what CaptureViewModel.loadProjects() reads).

    func testProjectsListYieldIsPersistedIntoSnapshotAndAvailableToThePicker() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        // Before the coordinator ever runs, the snapshot is empty -- this
        // is the exact "picker shows No projects" starting state.
        XCTAssertEqual(try store.projectsSnapshot(), [])

        let convex = FakeConvexService()
        let coordinator = ProjectsSyncCoordinator(store: store, convex: convex)
        coordinator.setServerUpdatesEnabled(true)

        let projects = [
            Project(id: "proj-1", name: "Project One", gitRemote: "git@example.com:one.git"),
            Project(id: "proj-2", name: "Project Two", gitRemote: "git@example.com:two.git"),
        ]
        await convex.yieldProjects(projects)

        try await Whistle_waitUntil(timeout: 1) {
            (try? store.projectsSnapshot()) == projects
        }

        XCTAssertEqual(try store.projectsSnapshot(), projects, "the projects.list yield must be persisted into GRDB")
    }

    // MARK: - Re-entrant start() is idempotent (a single subscription, not
    // one per call).

    func testEnablingServerUpdatesIsIdempotent() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let convex = FakeConvexService()
        let coordinator = ProjectsSyncCoordinator(store: store, convex: convex)
        coordinator.setServerUpdatesEnabled(true)
        coordinator.setServerUpdatesEnabled(true) // second call must not duplicate the subscription

        let projects = [Project(id: "proj-1", name: "Project One", gitRemote: "git@example.com:one.git")]
        await convex.yieldProjects(projects)

        try await Whistle_waitUntil(timeout: 1) {
            (try? store.projectsSnapshot()) == projects
        }
        XCTAssertEqual(try store.projectsSnapshot(), projects)
    }

    func testAuthenticatedLifecycleStopsAndRestartsSubscription() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let convex = FakeConvexService()
        let coordinator = ProjectsSyncCoordinator(store: store, convex: convex)

        coordinator.setServerUpdatesEnabled(false)
        XCTAssertEqual(convex.activeProjectsSubscriptionCount, 0)

        coordinator.setServerUpdatesEnabled(true)
        try await Whistle_waitUntil(timeout: 1) {
            convex.activeProjectsSubscriptionCount == 1
        }
        coordinator.setServerUpdatesEnabled(true)
        XCTAssertEqual(convex.activeProjectsSubscriptionCount, 1)

        coordinator.setServerUpdatesEnabled(false)
        try await Whistle_waitUntil(timeout: 1) {
            convex.activeProjectsSubscriptionCount == 0
        }

        coordinator.setServerUpdatesEnabled(true)
        try await Whistle_waitUntil(timeout: 1) {
            convex.activeProjectsSubscriptionCount == 1
        }
        convex.finishProjectSubscriptions()
        try await Whistle_waitUntil(timeout: 1) {
            convex.activeProjectsSubscriptionCount == 0
        }
        try await Whistle_waitUntil(timeout: 1) {
            convex.activeProjectsSubscriptionCount == 1
        }
        XCTAssertEqual(convex.activeProjectsSubscriptionCount, 1)
    }

    // MARK: - Stale-refresh trigger (TECH-SPEC §7)

    func testRefreshIfStaleCallsConductorRefreshWhenNoSnapshotExistsYet() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let convex = FakeConvexService()
        let coordinator = ProjectsSyncCoordinator(store: store, convex: convex)

        await coordinator.refreshIfStale()

        XCTAssertEqual(convex.refreshProjectsCallCount, 1, "a missing snapshot must be treated as stale")
    }

    func testRefreshIfStaleSkipsWhenSnapshotIsFresh() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir
        try store.saveProjectsSnapshot([], fetchedAt: Date())

        let convex = FakeConvexService()
        let coordinator = ProjectsSyncCoordinator(store: store, convex: convex, staleAfter: 3600)

        await coordinator.refreshIfStale(now: Date())

        XCTAssertEqual(convex.refreshProjectsCallCount, 0, "a snapshot fetched moments ago must not be re-refreshed")
    }

    func testRefreshIfStaleTriggersWhenSnapshotIsOlderThanStaleWindow() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir
        let staleFetchedAt = Date().addingTimeInterval(-3700) // just over 1h old
        try store.saveProjectsSnapshot([], fetchedAt: staleFetchedAt)

        let convex = FakeConvexService()
        let coordinator = ProjectsSyncCoordinator(store: store, convex: convex, staleAfter: 3600)

        await coordinator.refreshIfStale(now: Date())

        XCTAssertEqual(convex.refreshProjectsCallCount, 1, "a >1h-old snapshot must trigger conductor.refreshProjects")
    }
}

/// Polls `condition` on a background context until it's true or the
/// timeout elapses -- mirrors `Whistle_waitUntil` from the app test target
/// (not shared across targets), needed here because `AsyncStream` delivery
/// through the coordinator's subscription `Task` is not synchronous with
/// `yieldProjects(_:)`.
private func Whistle_waitUntil(
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    if !condition() {
        XCTFail("condition was never met within \(timeout)s", file: file, line: line)
    }
}
