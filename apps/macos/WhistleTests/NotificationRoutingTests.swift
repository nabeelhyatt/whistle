// NotificationRoutingTests.swift
// Plan U9 scenarios (all against a fake ConvexService — no network):
//   - Happy: transition ->`ready` fires notification with question count;
//     click opens deepLink and calls `captures.markOpened`.
//   - Happy: ->`failed`/`auth` notification routes to Settings; ->`failed`
//     other offers Retry (calls `captures.retry`).
//   - Edge: ->`readyUnverified` uses "status unknown" copy, not success copy.
//   - Edge: app relaunch with existing `ready` rows -> no duplicate
//     notifications.
//   - Integration: local `syncFailed` row shows local-retry affordance;
//     server `failed` shows server-retry.
//   - Happy: opening a History row's deep link patches `openedAt`; the row
//     visually de-emphasizes; the ready-indicator count decrements; opening
//     it again does not re-patch or re-decrement.
//   - Happy: archiving a row calls `captures.archive`; row disappears from
//     the default History view.
//   - Happy: "Duplicate as new capture" on a row opens the capture panel
//     pre-filled with that row's content, project picker focused, and a
//     `clientId` distinct from the original.
//   - Edge: ready-indicator shows nothing when zero unopened-ready captures
//     exist; shows a count/dot as soon as one transitions to `ready`.

import XCTest
@testable import Whistle
@testable import WhistleCore

// MARK: - Fake ConvexService (scriptable subscription + call tracking)

private final class FakeHistoryConvexService: ConvexServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[ServerCaptureRecord]>.Continuation] = [:]
    private var projectContinuations: [UUID: AsyncStream<[Project]>.Continuation] = [:]
    private var captureSubscriptionStarts = 0
    private var projectSubscriptionStarts = 0

    private(set) var markOpenedCalls: [String] = []
    private(set) var archiveCalls: [String] = []
    private(set) var retryCalls: [String] = []

    // MARK: users / settings / conductor / templates / files (unused stubs)

    func usersEnsure() async throws -> String { "user-1" }
    func settingsGet() async throws -> SettingsSnapshot {
        SettingsSnapshot(defaultProjectId: nil, agent: "claude", model: nil, screenshotsEnabled: true, hasKey: false, lastFour: nil)
    }
    func settingsUpdate(_ patch: SettingsPatch) async throws {}
    func settingsSetConductorKey(_ key: String) async throws {}
    func conductorValidateKey(key: String?) async throws -> Bool { true }
    func conductorRefreshProjects() async throws {}
    func projectsList() -> AsyncStream<[Project]> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.withLock {
                self.projectSubscriptionStarts += 1
                self.projectContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.projectContinuations.removeValue(forKey: id) }
            }
        }
    }
    func templatesGet() async throws -> TemplateSnapshot {
        TemplateSnapshot(body: "", isCustomized: false, updatedAt: Date(timeIntervalSince1970: 0))
    }
    func templatesUpdate(body: String) async throws {}
    func templatesReset() async throws {}
    func filesGenerateUploadUrl() async throws -> String { "https://example.convex.cloud/upload/fake" }

    // MARK: captures

    func capturesCreate(_ input: CaptureCreateInput) async throws -> String { "server-\(input.clientId)" }

    func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.withLock {
                self.captureSubscriptionStarts += 1
                self.continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func capturesList() async throws -> [ServerCaptureRecord] { [] }
    func capturesGet(id: String) async throws -> ServerCaptureRecord? { nil }

    func capturesRetry(id: String) async throws {
        lock.withLock { retryCalls.append(id) }
    }

    func capturesDeleteScreenshot(id: String) async throws {}

    func capturesMarkOpened(id: String) async throws {
        lock.withLock { markOpenedCalls.append(id) }
    }

    func capturesArchive(id: String) async throws {
        lock.withLock { archiveCalls.append(id) }
    }

    // MARK: test driver

    /// Publishes a new snapshot of records to every active subscriber.
    /// `capturesListRecent`'s `AsyncStream` only registers its continuation
    /// once something actually starts iterating it (i.e. once
    /// `HistoryViewModel.start()`'s `Task` gets scheduled) -- since that's
    /// asynchronous, a caller that immediately does
    /// `viewModel.start(); convex.yield(...)` synchronously can otherwise
    /// race ahead of subscription and drop the yield on the floor (no
    /// continuation registered yet to buffer it). `yield` is therefore
    /// `async` and waits (bounded) for at least one subscriber before
    /// publishing, so tests read naturally without a real network's
    /// keep-alive semantics leaking into them.
    func yield(_ records: [ServerCaptureRecord], timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let hasSubscriber = lock.withLock { !continuations.isEmpty }
            if hasSubscriber { break }
            if Date() >= deadline {
                XCTFail("FakeHistoryConvexService.yield timed out waiting for a subscriber")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        let subs = lock.withLock { Array(continuations.values) }
        for continuation in subs {
            continuation.yield(records)
        }
        // Give the MainActor-hopping `for await` consumer a chance to
        // process this yield before the caller makes assertions.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }

    var activeSubscriptionCount: Int {
        lock.withLock { continuations.count }
    }

    var activeProjectSubscriptionCount: Int {
        lock.withLock { projectContinuations.count }
    }

    var subscriptionStartCounts: (captures: Int, projects: Int) {
        lock.withLock { (captureSubscriptionStarts, projectSubscriptionStarts) }
    }

    func finishSubscriptions() {
        let subs = lock.withLock { Array(continuations.values) }
        subs.forEach { $0.finish() }
    }

    func finishProjectSubscriptions() {
        let subs = lock.withLock { Array(projectContinuations.values) }
        subs.forEach { $0.finish() }
    }
}

// MARK: - Test support

@MainActor
private enum HistoryTestSupport {
    static func makeStore() throws -> (store: CaptureStore, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")
        let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        return (store, tempDir)
    }

    static func record(
        id: String = "rec-1",
        clientId: String,
        transcript: String = "a transcript",
        notes: String = "",
        status: CaptureServerStatus,
        errorCode: CaptureErrorCode? = nil,
        error: String? = nil,
        deepLink: String? = "https://conductor.build/workspace/1",
        clarifyingQuestions: [String]? = nil,
        openedAt: Date? = nil,
        archivedAt: Date? = nil
    ) -> ServerCaptureRecord {
        ServerCaptureRecord(
            id: id,
            userId: "user-1",
            clientId: clientId,
            transcript: transcript,
            notes: notes,
            projectId: "proj-1",
            projectName: "Project One",
            agent: "claude",
            capturedAt: Date(),
            status: status,
            errorCode: errorCode,
            error: error,
            deepLink: deepLink,
            clarifyingQuestions: clarifyingQuestions,
            openedAt: openedAt,
            archivedAt: archivedAt
        )
    }

    /// Polls until `condition` is true or the timeout elapses, letting async
    /// Task-hops (subscription -> MainActor.run) land deterministically
    /// without a fixed sleep.
    static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Tests

@MainActor
final class NotificationRoutingTests: XCTestCase {
    func testServerSubscriptionFollowsAuthenticationAndRestartsAfterCompletion() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let viewModel = HistoryViewModel(
            store: store,
            convex: convex,
            notificationService: NotificationService(center: FakeUserNotificationCenter()),
            lastSeenStore: InMemoryLastSeenStatusStore()
        )
        try store.saveDraft(CaptureDraft(
            clientId: "auth-restart",
            transcript: "queued locally",
            notes: "",
            projectId: "proj-1",
            projectName: "Project One",
            agent: "claude",
            localState: .synced
        ))

        viewModel.start(serverUpdatesEnabled: false)
        XCTAssertEqual(convex.activeSubscriptionCount, 0)

        viewModel.setServerUpdatesEnabled(true)
        await HistoryTestSupport.waitUntil { convex.activeSubscriptionCount == 1 }
        viewModel.setServerUpdatesEnabled(true)
        XCTAssertEqual(convex.activeSubscriptionCount, 1, "repeated signed-in state must not duplicate subscriptions")

        let ready = HistoryTestSupport.record(clientId: "auth-restart", status: .ready)
        await convex.yield([ready])
        await HistoryTestSupport.waitUntil { viewModel.rows.first?.serverRecord?.status == .ready }
        XCTAssertEqual(viewModel.rows.first?.presentation.chip, "Ready")

        viewModel.setServerUpdatesEnabled(false)
        await HistoryTestSupport.waitUntil { convex.activeSubscriptionCount == 0 }
        XCTAssertNil(viewModel.rows.first?.serverRecord)
        XCTAssertEqual(viewModel.rows.first?.presentation.chip, "Queued")

        viewModel.setServerUpdatesEnabled(true)
        await HistoryTestSupport.waitUntil { convex.activeSubscriptionCount == 1 }
        let startsBeforeTermination = convex.subscriptionStartCounts.captures
        convex.finishSubscriptions()
        await HistoryTestSupport.waitUntil {
            convex.subscriptionStartCounts.captures > startsBeforeTermination
        }
        XCTAssertEqual(convex.activeSubscriptionCount, 1)
    }

    func testRepeatedStartDoesNotBypassSignedOutServerGate() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let convex = FakeHistoryConvexService()
        let viewModel = HistoryViewModel(
            store: store,
            convex: convex,
            notificationService: NotificationService(center: FakeUserNotificationCenter()),
            lastSeenStore: InMemoryLastSeenStatusStore()
        )

        viewModel.start(serverUpdatesEnabled: false)
        viewModel.start()
        await Task.yield()

        XCTAssertEqual(convex.activeSubscriptionCount, 0)
    }

    func testAuthPublisherOrdersAllSubscriptionLifecycleTransitions() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let convex = FakeHistoryConvexService()
        let auth = AuthController(
            authProvider: MockAuthProvider(fixedToken: "mock-id-token"),
            convexService: convex
        )
        let history = HistoryViewModel(
            store: store,
            convex: convex,
            notificationService: NotificationService(center: FakeUserNotificationCenter()),
            lastSeenStore: InMemoryLastSeenStatusStore()
        )
        history.start(serverUpdatesEnabled: false)
        let projects = ProjectsSyncCoordinator(store: store, convex: convex)
        let coordinator = AuthenticatedServerUpdatesCoordinator(
            auth: auth,
            history: history,
            projects: projects
        )

        await auth.signIn()
        await HistoryTestSupport.waitUntil {
            convex.activeSubscriptionCount == 1 && convex.activeProjectSubscriptionCount == 1
        }

        convex.finishSubscriptions()
        convex.finishProjectSubscriptions()
        await HistoryTestSupport.waitUntil {
            let starts = convex.subscriptionStartCounts
            return starts.captures >= 2 && starts.projects >= 2
        }

        auth.handleTokenRefreshFailure()
        await HistoryTestSupport.waitUntil {
            convex.activeSubscriptionCount == 0 && convex.activeProjectSubscriptionCount == 0
        }

        await auth.signIn()
        await HistoryTestSupport.waitUntil {
            convex.activeSubscriptionCount == 1 && convex.activeProjectSubscriptionCount == 1
        }
        _ = coordinator
    }

    // MARK: Happy: ->ready fires notification with question count; click opens deepLink + marks opened

    func testReadyTransitionFiresNotificationWithQuestionCountAndClickOpensDeepLinkAndMarksOpened() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let lastSeen = InMemoryLastSeenStatusStore()
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: lastSeen)

        // Simulate this capture having been created locally this session
        // (so the transition is "observed," not a stale relaunch sighting).
        try store.saveDraft(CaptureDraft(clientId: "client-1", transcript: "t", notes: "", projectId: "proj-1", projectName: "Project One", agent: "claude", localState: .synced))

        viewModel.start()

        let readyRecord = HistoryTestSupport.record(
            clientId: "client-1",
            status: .ready,
            clarifyingQuestions: ["What database?", "Which env?"]
        )
        await convex.yield([readyRecord])

        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }

        XCTAssertEqual(fakeCenter.posted.count, 1)
        XCTAssertEqual(fakeCenter.posted.first?.body.contains("2"), true, "body should include question count")

        var openedURLs: [URL] = []
        var routedRecordId: String?
        notificationService.onRoute = { route in
            if case .openDeepLink(let recordId) = route {
                routedRecordId = recordId
            }
        }
        // Simulate the notification click routing through to HistoryViewModel,
        // the way AppDelegate wires it.
        notificationService.onRoute = { route in
            if case .openDeepLink(let recordId) = route,
               let row = viewModel.rows.first(where: { $0.serverRecord?.id == recordId }) {
                routedRecordId = recordId
                viewModel.openDeepLink(for: row, urlOpener: { openedURLs.append($0) })
            }
        }
        notificationService.onRoute(.openDeepLink(recordId: readyRecord.id))

        XCTAssertEqual(routedRecordId, readyRecord.id)
        XCTAssertEqual(openedURLs, [URL(string: readyRecord.deepLink!)!])

        await HistoryTestSupport.waitUntil { !convex.markOpenedCalls.isEmpty }
        XCTAssertEqual(convex.markOpenedCalls, [readyRecord.id])
    }

    // MARK: Happy: ->failed/auth routes to Settings; ->failed other offers Retry

    func testFailedAuthNotificationRoutesToSettingsPlaceholder() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())

        try store.saveDraft(CaptureDraft(clientId: "client-auth", transcript: "t", notes: "", projectId: "proj-1", projectName: "Project One", agent: "claude", localState: .synced))
        viewModel.start()

        let failedAuthRecord = HistoryTestSupport.record(clientId: "client-auth", status: .failed, errorCode: .auth)
        await convex.yield([failedAuthRecord])

        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }

        var settingsRouteFired = false
        notificationService.onRoute = { route in
            if case .openSettingsApiKey = route {
                settingsRouteFired = true
            }
        }
        let route = NotificationService.decodeRoute(from: fakeCenter.posted[0].userInfo)
        XCTAssertEqual(route, .openSettingsApiKey)
        notificationService.onRoute(route!)
        XCTAssertTrue(settingsRouteFired)
    }

    func testFailedOtherNotificationOffersRetryAndTriggersCapturesRetry() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())

        try store.saveDraft(CaptureDraft(clientId: "client-fail", transcript: "t", notes: "", projectId: "proj-1", projectName: "Project One", agent: "claude", localState: .synced))
        viewModel.start()

        let failedRecord = HistoryTestSupport.record(clientId: "client-fail", status: .failed, errorCode: .workspaceSetup, error: "workspace could not be created")
        await convex.yield([failedRecord])

        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }
        XCTAssertTrue(fakeCenter.posted[0].body.contains("workspace could not be created"))

        notificationService.onRoute = { route in
            if case .retry(let recordId) = route, let row = viewModel.rows.first(where: { $0.serverRecord?.id == recordId }) {
                viewModel.retry(row)
            }
        }
        let route = NotificationService.decodeRoute(from: fakeCenter.posted[0].userInfo)
        XCTAssertEqual(route, .retry(recordId: failedRecord.id))
        notificationService.onRoute(route!)

        await HistoryTestSupport.waitUntil { !convex.retryCalls.isEmpty }
        XCTAssertEqual(convex.retryCalls, [failedRecord.id])
    }

    // MARK: Edge: ->readyUnverified uses "status unknown" copy, not success copy

    func testReadyUnverifiedUsesStatusUnknownCopyNotSuccessCopy() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())

        try store.saveDraft(CaptureDraft(clientId: "client-unverified", transcript: "t", notes: "", projectId: "proj-1", projectName: "Project One", agent: "claude", localState: .synced))
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-unverified", status: .readyUnverified)
        await convex.yield([record])

        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }

        let posted = fakeCenter.posted[0]
        XCTAssertTrue(posted.body.lowercased().contains("unknown"))
        XCTAssertFalse(posted.title.lowercased().contains("ready"))
    }

    // MARK: Edge: app relaunch with existing ready rows -> no duplicate notifications

    func testRelaunchWithExistingReadyRowDoesNotReNotify() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)

        // Simulate a persisted last-seen store from a PRIOR app run that
        // already observed this capture as ready -- no local draft exists
        // this session (as if the app relaunched fresh and CaptureStore's
        // queue was already drained/cleared).
        let lastSeen = InMemoryLastSeenStatusStore(initial: ["client-relaunch": .ready])
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: lastSeen)
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-relaunch", status: .ready)
        await convex.yield([record])

        // Give the subscription a moment to process -- then assert nothing
        // was posted (status unchanged from the persisted last-seen value).
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fakeCenter.posted.isEmpty, "relaunch must not re-fire for an already-seen ready row")
    }

    func testRelaunchThenGenuineTransitionToReadyStillNotifiesExactlyOnce() async throws {
        // A capture that was `agentWorking` at the end of a prior session
        // (persisted last-seen status) and progresses to `ready` in this
        // session must still notify -- relaunch dedup only suppresses
        // re-observing the SAME status, never a genuine transition that
        // happens to be first observed shortly after relaunch.
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let lastSeen = InMemoryLastSeenStatusStore(initial: ["client-progress": .agentWorking])
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: lastSeen)
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-progress", status: .ready)
        await convex.yield([record])

        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }
        XCTAssertEqual(fakeCenter.posted.count, 1)

        // A second identical snapshot (e.g. the subscription re-yielding
        // the same data) must not re-fire.
        await convex.yield([record])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fakeCenter.posted.count, 1, "an unchanged status must not re-notify")
    }

    func testFreshCaptureReachingReadyForTheFirstTimeNotifiesEvenWithNoPriorLastSeenEntry() async throws {
        // A brand-new capture has no entry in lastSeenStore at all
        // (previous == nil). This must still notify -- there is nothing to
        // have silently pre-seen, unlike the relaunch case where the
        // persisted store already recorded the row's current status.
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-brand-new", status: .ready)
        await convex.yield([record])

        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }
        XCTAssertEqual(fakeCenter.posted.count, 1)
    }

    // MARK: Integration: local syncFailed shows local-retry; server failed shows server-retry

    func testLocalSyncFailedRowShowsLocalRetryAffordance() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())

        try store.saveDraft(CaptureDraft(clientId: "client-syncfail", transcript: "t", notes: "", projectId: "proj-1", projectName: "Project One", agent: "claude", localState: .syncFailed, localError: "network down"))

        viewModel.start()
        await HistoryTestSupport.waitUntil { !viewModel.rows.isEmpty }

        let row = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-syncfail" })
        XCTAssertEqual(row.presentation.affordance, .localRetry)
        XCTAssertEqual(row.presentation.chip, "Sync failed")
    }

    // U4: `.localRetry` affordance's "Retry" button (`HistoryRow.onLocalRetry`)
    // is wired through `HistoryViewModel.localRetry(_:)` to
    // `onLocalRetryRequested`, which `AppDelegate` wires to
    // `syncEngine.drainOnce()` -- there is no server record yet for a
    // local-only `syncFailed` row, so `captures.retry` doesn't apply.
    func testLocalRetryOnLocalSyncFailedRowInvokesOnLocalRetryRequested() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())

        try store.saveDraft(CaptureDraft(clientId: "client-localretry", transcript: "t", notes: "", projectId: "proj-1", projectName: "Project One", agent: "claude", localState: .syncFailed, localError: "network down"))

        viewModel.start()
        await HistoryTestSupport.waitUntil { !viewModel.rows.isEmpty }

        let row = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-localretry" })
        XCTAssertEqual(row.presentation.affordance, .localRetry)

        var localRetryRequestedCount = 0
        viewModel.onLocalRetryRequested = { localRetryRequestedCount += 1 }

        viewModel.localRetry()

        XCTAssertEqual(localRetryRequestedCount, 1)
    }

    func testServerFailedRowShowsServerRetryAffordance() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-serverfail", status: .failed, errorCode: .workspaceSetup, error: "boom")
        await convex.yield([record])

        await HistoryTestSupport.waitUntil { !viewModel.rows.isEmpty }

        let row = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-serverfail" })
        XCTAssertEqual(row.presentation.affordance, .serverRetry)
        XCTAssertEqual(row.presentation.chip, "Failed: boom")
    }

    // MARK: Happy: opening deep link patches openedAt, de-emphasizes, decrements ready-indicator; idempotent

    func testOpeningDeepLinkMarksOpenedDeemphasizesAndDecrementsReadyIndicatorIdempotently() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-open", status: .ready)
        await convex.yield([record])

        await HistoryTestSupport.waitUntil { !viewModel.rows.isEmpty }
        XCTAssertTrue(viewModel.hasUnreadReadyCaptures)

        let row = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-open" })
        XCTAssertFalse(row.presentation.isDeemphasized)

        var openedCount = 0
        viewModel.openDeepLink(for: row, urlOpener: { _ in openedCount += 1 })

        await HistoryTestSupport.waitUntil { !convex.markOpenedCalls.isEmpty }
        XCTAssertEqual(convex.markOpenedCalls, [record.id])
        XCTAssertEqual(openedCount, 1)

        // Server round-trip: subscription re-yields with openedAt now set.
        let openedRecord = HistoryTestSupport.record(clientId: "client-open", status: .ready, openedAt: Date())
        await convex.yield([openedRecord])

        await HistoryTestSupport.waitUntil {
            viewModel.rows.first(where: { $0.clientId == "client-open" })?.presentation.isDeemphasized == true
        }
        XCTAssertFalse(viewModel.hasUnreadReadyCaptures, "ready-indicator should clear once the only ready row is opened")

        // Opening again must not re-patch or re-decrement (idempotent).
        let reopenedRow = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-open" })
        viewModel.openDeepLink(for: reopenedRow, urlOpener: { _ in openedCount += 1 })
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(convex.markOpenedCalls, [record.id], "re-opening an already-opened row must not re-call markOpened")
        XCTAssertEqual(openedCount, 2, "the URL still opens again -- only the server patch is idempotent-guarded")
    }

    // MARK: Happy: archiving calls captures.archive; row disappears from default view

    func testArchivingRowCallsCapturesArchiveAndRemovesFromDefaultView() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-archive", status: .ready)
        await convex.yield([record])
        await HistoryTestSupport.waitUntil { !viewModel.rows.isEmpty }

        let row = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-archive" })
        viewModel.archive(row)

        await HistoryTestSupport.waitUntil { !convex.archiveCalls.isEmpty }
        XCTAssertEqual(convex.archiveCalls, [record.id])

        // Server round-trip: subscription re-yields with archivedAt set.
        let archivedRecord = HistoryTestSupport.record(clientId: "client-archive", status: .ready, archivedAt: Date())
        await convex.yield([archivedRecord])

        await HistoryTestSupport.waitUntil {
            !viewModel.visibleRows.contains { $0.clientId == "client-archive" }
        }
        XCTAssertFalse(viewModel.visibleRows.contains { $0.clientId == "client-archive" })

        // But it's still reachable via the archived filter.
        viewModel.showArchived = true
        XCTAssertTrue(viewModel.visibleRows.contains { $0.clientId == "client-archive" })
    }

    // MARK: Happy: Duplicate as new capture pre-fills content, focuses picker, mints new clientId

    func testDuplicateAsNewCapturePreFillsContentWithFocusedPickerAndFreshClientId() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([Project(id: "proj-1", name: "Project One", gitRemote: "git@example.com:one.git")])

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let record = HistoryTestSupport.record(clientId: "client-dup", transcript: "original transcript", notes: "original notes", status: .ready)
        await convex.yield([record])
        await HistoryTestSupport.waitUntil { !viewModel.rows.isEmpty }

        let row = try XCTUnwrap(viewModel.rows.first { $0.clientId == "client-dup" })
        let preFill = viewModel.duplicatePreFill(for: row, screenshotData: nil)

        XCTAssertEqual(preFill.transcript, "original transcript")
        XCTAssertEqual(preFill.notes, "original notes")
        XCTAssertTrue(preFill.focusProjectPicker)

        // Feed the pre-fill into a real CaptureViewModel the way
        // CapturePanelController.trigger(preFill:) does, and assert a fresh
        // clientId distinct from the original row's.
        let captureViewModel = CaptureViewModel(store: store, transcriptionServiceFactory: { FakeTranscriptionService() }, micPermissionStatus: { .granted })
        captureViewModel.beginCapture(preFill: preFill)

        XCTAssertEqual(captureViewModel.transcriptText, "original transcript")
        XCTAssertEqual(captureViewModel.notesText, "original notes")
        XCTAssertTrue(captureViewModel.focusProjectPicker)
        XCTAssertNotEqual(captureViewModel.clientId, "client-dup", "duplicate must mint a fresh clientId, distinct from the original")
    }

    // MARK: Edge: ready-indicator on/off transitions

    func testReadyIndicatorIsOffWithZeroUnopenedReadyAndTurnsOnAsSoonAsOneTransitionsToReady() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        // Nothing yet.
        await convex.yield([])
        await HistoryTestSupport.waitUntil { true } // let the empty snapshot land
        XCTAssertFalse(viewModel.hasUnreadReadyCaptures)

        // A non-ready capture shouldn't turn it on.
        let working = HistoryTestSupport.record(clientId: "client-working", status: .agentWorking)
        await convex.yield([working])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(viewModel.hasUnreadReadyCaptures)

        // Transition to ready -> indicator turns on.
        let ready = HistoryTestSupport.record(clientId: "client-working", status: .ready)
        await convex.yield([ready])
        await HistoryTestSupport.waitUntil { viewModel.hasUnreadReadyCaptures }
        XCTAssertTrue(viewModel.hasUnreadReadyCaptures)
    }

    func testReadyIndicatorIgnoresAlreadyOpenedReadyRows() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let readyOpened = HistoryTestSupport.record(clientId: "client-opened-already", status: .ready, openedAt: Date())
        await convex.yield([readyOpened])

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(viewModel.hasUnreadReadyCaptures)
    }

    // MARK: Happy: search filters by transcript/notes/project (plan U9: "searchable (transcript/notes/project)")

    func testSearchFiltersRowsByTranscriptNotesAndProjectName() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let notificationService = NotificationService(center: FakeUserNotificationCenter())
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let recordA = ServerCaptureRecord(
            id: "rec-a", userId: "user-1", clientId: "client-a",
            transcript: "refactor the login flow", notes: "",
            projectId: "proj-1", projectName: "Whistle", agent: "claude",
            capturedAt: Date(), status: .agentWorking
        )
        let recordB = ServerCaptureRecord(
            id: "rec-b", userId: "user-1", clientId: "client-b",
            transcript: "totally unrelated idea", notes: "mentions billing",
            projectId: "proj-2", projectName: "Marketing Site", agent: "claude",
            capturedAt: Date(), status: .agentWorking
        )
        await convex.yield([recordA, recordB])
        await HistoryTestSupport.waitUntil { viewModel.rows.count == 2 }

        viewModel.searchText = "login"
        XCTAssertEqual(viewModel.visibleRows.map(\.clientId), ["client-a"])

        viewModel.searchText = "billing"
        XCTAssertEqual(viewModel.visibleRows.map(\.clientId), ["client-b"])

        viewModel.searchText = "marketing"
        XCTAssertEqual(viewModel.visibleRows.map(\.clientId), ["client-b"])

        viewModel.searchText = ""
        XCTAssertEqual(Set(viewModel.visibleRows.map(\.clientId)), Set(["client-a", "client-b"]))
    }

    // MARK: Happy: failed-other notification body includes the userMessage verbatim

    func testFailedOtherNotificationBodyIncludesUserMessageVerbatim() async throws {
        let (store, tempDir) = try HistoryTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let convex = FakeHistoryConvexService()
        let fakeCenter = FakeUserNotificationCenter()
        let notificationService = NotificationService(center: fakeCenter)
        let viewModel = HistoryViewModel(store: store, convex: convex, notificationService: notificationService, lastSeenStore: InMemoryLastSeenStatusStore())
        viewModel.start()

        let record = HistoryTestSupport.record(
            clientId: "client-usermessage",
            status: .failed,
            errorCode: .network,
            error: "Conductor is temporarily unreachable — please retry shortly."
        )
        await convex.yield([record])
        await HistoryTestSupport.waitUntil { !fakeCenter.posted.isEmpty }

        XCTAssertEqual(fakeCenter.posted[0].body, "Conductor is temporarily unreachable — please retry shortly.")
    }
}
