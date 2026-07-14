// SyncEngineTests.swift
// Plan U5 scenarios: offline drain stays queued then drains in order;
// captures.create failure -> syncFailed -> local retry with same clientId;
// screenshot-upload failure keeps the whole capture queued (atomic).

import Foundation
import XCTest
@testable import WhistleCore

// MARK: - Log collector for the injected SyncEngine logger

/// Minimal thread-safe sink for `SyncEngine`'s injected `logger` closure so
/// tests can assert on emitted messages without touching real `NSLog`
/// output (plan U2: logger seam for Console.app/`log stream` visibility).
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func log(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }
}

// MARK: - Test signal for deterministic concurrency tests

/// A one-shot flag a producer fires and a waiter polls for, so a test can
/// deterministically sequence two concurrent `drainOnce()` calls without
/// reaching into `SyncEngine`'s internals. Mirrors the bounded-wait polling
/// style already used by `FakeConvexService.yieldProjects`.
final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    func wait(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            let isFired = fired
            lock.unlock()
            if isFired { return }
            if Date() >= deadline {
                XCTFail("TestSignal.wait timed out")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

final class SyncEngineTests: XCTestCase {
    private var tempDir: URL!

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Offline: stays queued, no crash

    func testOfflineDrainLeavesDraftsQueued() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "offline-1")
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        let network = FakeNetworkMonitor(online: false)
        let engine = SyncEngine(store: store, convex: convex, networkMonitor: network)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, [])
        XCTAssertEqual(try store.draft(clientId: "offline-1")?.localState, .queued)
        XCTAssertEqual(convex.capturesCreateCalls.count, 0)
    }

    // MARK: - Connectivity restored -> drains in order

    func testDrainsInCaptureOrderOnceOnline() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let first = TestSupport.makeDraft(clientId: "first", capturedAt: Date(timeIntervalSince1970: 100))
        let second = TestSupport.makeDraft(clientId: "second", capturedAt: Date(timeIntervalSince1970: 200))
        // Insert out of order.
        try store.saveDraft(second)
        try store.saveDraft(first)

        let convex = FakeConvexService()
        let network = FakeNetworkMonitor(online: true)
        let engine = SyncEngine(store: store, convex: convex, networkMonitor: network)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, ["first", "second"])
        XCTAssertEqual(convex.capturesCreateCalls.map(\.clientId), ["first", "second"])
        XCTAssertEqual(try store.draft(clientId: "first")?.localState, .synced)
        XCTAssertEqual(try store.draft(clientId: "second")?.localState, .synced)
    }

    // MARK: - captures.create failure -> syncFailed -> local retry, same clientId

    func testCapturesCreateFailureMarksSyncFailedThenLocalRetrySucceedsWithSameClientId() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "retry-me")
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        var shouldFail = true
        convex.onCapturesCreate = { input in
            if shouldFail {
                throw ConvexServiceError.requestFailed("simulated failure")
            }
            return "server-\(input.clientId)"
        }

        let engine = SyncEngine(store: store, convex: convex)

        let firstAttempt = await engine.drainOnce()
        XCTAssertEqual(firstAttempt, [])
        XCTAssertEqual(try store.draft(clientId: "retry-me")?.localState, .syncFailed)
        XCTAssertEqual(try store.draft(clientId: "retry-me")?.localAttempt, 1)

        // Local retry: SyncEngine drains syncFailed drafts too, reusing the
        // same clientId (the server dedupes on (userId, clientId)).
        shouldFail = false
        let secondAttempt = await engine.drainOnce()

        XCTAssertEqual(secondAttempt, ["retry-me"])
        XCTAssertEqual(try store.draft(clientId: "retry-me")?.localState, .synced)
        XCTAssertEqual(convex.capturesCreateCalls.map(\.clientId), ["retry-me", "retry-me"])
        XCTAssertEqual(Set(convex.capturesCreateCalls.map(\.clientId)), ["retry-me"])
    }

    // MARK: - Screenshot upload failure keeps the whole capture queued (atomic)

    func testScreenshotUploadFailureKeepsCaptureQueuedAndNeverCallsCapturesCreate() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let screenshotPath = try store.writeScreenshot(Data([0x01, 0x02, 0x03]), clientId: "with-screenshot")
        var draft = TestSupport.makeDraft(clientId: "with-screenshot")
        draft.screenshotPath = screenshotPath
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        let uploader = FakeScreenshotUploader()
        uploader.onUpload = { _, _ in throw SyncEngineError.uploadFailed(statusCode: 500) }

        let engine = SyncEngine(store: store, convex: convex, uploader: uploader)
        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, [])
        XCTAssertEqual(try store.draft(clientId: "with-screenshot")?.localState, .syncFailed)
        // The mutation must never have been attempted — upload-then-create
        // is atomic from the queue's point of view.
        XCTAssertEqual(convex.capturesCreateCalls.count, 0)
        XCTAssertEqual(uploader.uploadCallCount, 1)
    }

    func testSuccessfulScreenshotUploadPassesStorageIdToCapturesCreate() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let screenshotPath = try store.writeScreenshot(Data([0x01, 0x02, 0x03]), clientId: "shot-ok")
        var draft = TestSupport.makeDraft(clientId: "shot-ok")
        draft.screenshotPath = screenshotPath
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        let uploader = FakeScreenshotUploader()
        uploader.onUpload = { _, _ in "storage-abc" }

        let engine = SyncEngine(store: store, convex: convex, uploader: uploader)
        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, ["shot-ok"])
        XCTAssertEqual(convex.capturesCreateCalls.first?.screenshotStorageId, "storage-abc")
    }

    func testDraftWithoutScreenshotNeverCallsUploader() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "no-shot")
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        let uploader = FakeScreenshotUploader()
        let engine = SyncEngine(store: store, convex: convex, uploader: uploader)

        _ = await engine.drainOnce()

        XCTAssertEqual(uploader.uploadCallCount, 0)
        XCTAssertNil(convex.capturesCreateCalls.first?.screenshotStorageId)
    }

    // MARK: - Independent failures: one draft failing doesn't stop others

    func testOneDraftFailingDoesNotBlockOthersInSameDrain() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let good = TestSupport.makeDraft(clientId: "good", capturedAt: Date(timeIntervalSince1970: 1))
        let bad = TestSupport.makeDraft(clientId: "bad", capturedAt: Date(timeIntervalSince1970: 2))
        try store.saveDraft(good)
        try store.saveDraft(bad)

        let convex = FakeConvexService()
        convex.onCapturesCreate = { input in
            if input.clientId == "bad" {
                throw ConvexServiceError.requestFailed("nope")
            }
            return "server-\(input.clientId)"
        }

        let engine = SyncEngine(store: store, convex: convex)
        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, ["good"])
        XCTAssertEqual(try store.draft(clientId: "good")?.localState, .synced)
        XCTAssertEqual(try store.draft(clientId: "bad")?.localState, .syncFailed)
    }

    // MARK: - Logging (plan U2): failures visible via the injected logger seam

    func testSuccessfulSyncLogsSyncedMessage() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "log-happy")
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        let logs = LogCollector()
        let engine = SyncEngine(store: store, convex: convex, logger: logs.log)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, ["log-happy"])
        XCTAssertTrue(
            logs.messages.contains { $0.contains("synced log-happy") },
            "expected a 'synced <clientId>' log message, got: \(logs.messages)"
        )
    }

    func testCapturesCreateFailureLogsSyncFailedMessage() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "log-fail")
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        convex.onCapturesCreate = { _ in
            throw ConvexServiceError.requestFailed("simulated failure")
        }

        let logs = LogCollector()
        let engine = SyncEngine(store: store, convex: convex, logger: logs.log)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, [])
        XCTAssertEqual(try store.draft(clientId: "log-fail")?.localState, .syncFailed)
        XCTAssertTrue(
            logs.messages.contains { $0.contains("sync failed for log-fail") },
            "expected a 'sync failed for <clientId>' log message, got: \(logs.messages)"
        )
    }

    func testNotAuthenticatedFailureRevertsToQueuedInsteadOfSyncFailed() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "not-signed-in")
        try store.saveDraft(draft)

        let convex = FakeConvexService()
        convex.onCapturesCreate = { _ in
            throw ConvexServiceError.notAuthenticated
        }

        let logs = LogCollector()
        let engine = SyncEngine(store: store, convex: convex, logger: logs.log)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, [])
        // Not `.syncFailed`: there's no server-record/local-sync problem to
        // retry-with-backoff, and `.syncFailed` would surface a misleading
        // ".localRetry" button for a condition a local retry can't fix.
        // Also must not be left `.syncing` (which has no retry affordance
        // at all) -- reverts to `.queued` so the next drain, once signed
        // in, picks it back up.
        let reverted = try store.draft(clientId: "not-signed-in")
        XCTAssertEqual(reverted?.localState, .queued)
        XCTAssertEqual(reverted?.localAttempt, 0, "must not consume a retry attempt for an auth failure")
        XCTAssertTrue(
            logs.messages.contains { $0.contains("sync deferred for not-signed-in") },
            "expected a 'sync deferred for <clientId>' log message, got: \(logs.messages)"
        )
    }

    func testEmptyQueueLogsNoDrainStartMessage() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let convex = FakeConvexService()
        let logs = LogCollector()
        let engine = SyncEngine(store: store, convex: convex, logger: logs.log)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, [])
        XCTAssertTrue(logs.messages.isEmpty, "expected no log messages for an empty queue, got: \(logs.messages)")
    }

    // MARK: - Reentrancy guard: overlapping drainOnce() calls coalesce
    // instead of double-processing the same draft

    func testConcurrentDrainOnceCallsDoNotDoubleProcessSameDraft() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let first = TestSupport.makeDraft(clientId: "concurrent-first", capturedAt: Date(timeIntervalSince1970: 100))
        let second = TestSupport.makeDraft(clientId: "concurrent-second", capturedAt: Date(timeIntervalSince1970: 200))
        try store.saveDraft(first)
        try store.saveDraft(second)

        let convex = FakeConvexService()
        // Blocks the first drainOnce() call's loop mid-`syncOne` for
        // "concurrent-first" until the test explicitly releases it, so a
        // second drainOnce() call can be started while the first is
        // provably still draining -- the exact race the reentrancy guard
        // exists to prevent.
        let firstCallStarted = TestSignal()
        let releaseFirstCall = TestSignal()
        convex.onCapturesCreate = { input in
            if input.clientId == "concurrent-first" {
                firstCallStarted.fire()
                await releaseFirstCall.wait()
            }
            return "server-\(input.clientId)"
        }

        let logs = LogCollector()
        let engine = SyncEngine(store: store, convex: convex, logger: logs.log)

        async let firstDrain = engine.drainOnce()
        await firstCallStarted.wait()

        // At this point the first call has snapshotted both drafts, marked
        // "concurrent-first" `.syncing`, and is suspended inside
        // `syncOne` -- "concurrent-second" is still sitting `.queued` from
        // any other caller's point of view. Pre-fix, a second drainOnce()
        // call here would take its own snapshot (seeing "concurrent-second"
        // as queued), sync it, and then the *first* call would sync it
        // again once it resumed to its own original snapshot -- two
        // `capturesCreate` calls for the same clientId.
        async let secondDrain = engine.drainOnce()

        // Give the second call's actor-isolated code a moment to actually
        // run (and coalesce at the `isDraining` guard) before unblocking the
        // first call.
        try await Task.sleep(nanoseconds: 50_000_000)
        releaseFirstCall.fire()

        let (firstResult, secondResult) = await (firstDrain, secondDrain)
        let allSynced = firstResult + secondResult

        XCTAssertEqual(
            Set(allSynced), ["concurrent-first", "concurrent-second"],
            "expected both drafts synced exactly once across both calls, got: \(allSynced)"
        )
        XCTAssertEqual(allSynced.count, 2, "expected no draft synced twice, got: \(allSynced)")

        XCTAssertTrue(
            logs.messages.contains { $0.contains("drain already in flight, requesting rerun") },
            "expected the coalesced second drainOnce() call to log that a drain was already in flight, got: \(logs.messages)"
        )

        let clientIds = convex.capturesCreateCalls.map(\.clientId)
        XCTAssertEqual(
            clientIds.filter { $0 == "concurrent-first" }.count, 1,
            "expected exactly one capturesCreate call for concurrent-first, got: \(clientIds)"
        )
        XCTAssertEqual(
            clientIds.filter { $0 == "concurrent-second" }.count, 1,
            "expected exactly one capturesCreate call for concurrent-second, got: \(clientIds)"
        )
        XCTAssertEqual(try store.draft(clientId: "concurrent-first")?.localState, .synced)
        XCTAssertEqual(try store.draft(clientId: "concurrent-second")?.localState, .synced)
    }

    // MARK: - Periodic drain (safety net for a missed/failed trigger, U2)

    /// Polls `condition` until it's true, mirroring `TestSignal.wait`'s
    /// bounded-wait polling style for assertions that can't be driven by a
    /// single one-shot flag (here: a call count that increases over
    /// multiple ticks of `runPeriodicDrain`'s loop).
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("waitUntil timed out")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testRunPeriodicDrainCallsDrainOnceRepeatedlyOverBoundedWindow() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let convex = FakeConvexService()
        let engine = SyncEngine(store: store, convex: convex)

        // A short interval keeps this test's window well under a second;
        // real usage is minutes (see `runPeriodicDrain`'s default), never
        // wall-clock milliseconds.
        let periodicTask = Task { await engine.runPeriodicDrain(interval: .milliseconds(10)) }

        // Queue a draft and wait for the loop's own (not test-driven) next
        // tick to drain it -- this proves runPeriodicDrain is invoking
        // drainOnce() on its own with no external trigger.
        try store.saveDraft(TestSupport.makeDraft(clientId: "tick-1"))
        await waitUntil { convex.capturesCreateCalls.count >= 1 }

        // Only queue the second draft after the first has already synced,
        // so a second successful capturesCreate call can only be produced
        // by a *subsequent* tick of the same loop, not a single call.
        try store.saveDraft(TestSupport.makeDraft(clientId: "tick-2"))
        await waitUntil { convex.capturesCreateCalls.count >= 2 }

        periodicTask.cancel()

        XCTAssertGreaterThanOrEqual(convex.capturesCreateCalls.count, 2)
        XCTAssertEqual(Set(convex.capturesCreateCalls.map(\.clientId)), ["tick-1", "tick-2"])
        XCTAssertEqual(try store.draft(clientId: "tick-1")?.localState, .synced)
        XCTAssertEqual(try store.draft(clientId: "tick-2")?.localState, .synced)
    }

    func testPeriodicDrainOverlappingWithExplicitDrainOnceCoalescesWithoutDoubleProcessing() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let first = TestSupport.makeDraft(clientId: "periodic-first", capturedAt: Date(timeIntervalSince1970: 100))
        let second = TestSupport.makeDraft(clientId: "periodic-second", capturedAt: Date(timeIntervalSince1970: 200))
        try store.saveDraft(first)
        try store.saveDraft(second)

        let convex = FakeConvexService()
        // Same technique as
        // testConcurrentDrainOnceCallsDoNotDoubleProcessSameDraft: block the
        // periodic loop's first tick mid-`syncOne` for "periodic-first"
        // until the test explicitly releases it, so an explicit drainOnce()
        // call (simulating e.g. a capture-submit trigger) can be started
        // while the periodic loop's own drainOnce() call is provably still
        // draining -- the exact race the `isDraining` guard exists to
        // prevent, now exercised across two independent loops instead of
        // two direct calls.
        let firstCallStarted = TestSignal()
        let releaseFirstCall = TestSignal()
        convex.onCapturesCreate = { input in
            if input.clientId == "periodic-first" {
                firstCallStarted.fire()
                await releaseFirstCall.wait()
            }
            return "server-\(input.clientId)"
        }

        let engine = SyncEngine(store: store, convex: convex)

        // Short interval so the periodic loop's first tick fires almost
        // immediately -- the test only needs that one tick to overlap with
        // the explicit call below.
        let periodicTask = Task { await engine.runPeriodicDrain(interval: .milliseconds(5)) }

        await firstCallStarted.wait()

        // At this point the periodic loop's drainOnce() has snapshotted
        // both drafts, marked "periodic-first" `.syncing`, and is suspended
        // inside `syncOne` -- an explicit drainOnce() call here must
        // coalesce via the `isDraining` guard rather than taking its own
        // snapshot and double-processing "periodic-second".
        async let explicitDrain = engine.drainOnce()

        try await Task.sleep(nanoseconds: 50_000_000)
        releaseFirstCall.fire()

        _ = await explicitDrain
        // Let the periodic loop's in-flight pass (which may loop once more
        // via `rerunRequested`) finish before cancelling and asserting.
        await waitUntil { (try? store.draft(clientId: "periodic-second")?.localState) == .synced }
        periodicTask.cancel()

        let clientIds = convex.capturesCreateCalls.map(\.clientId)
        XCTAssertEqual(
            clientIds.filter { $0 == "periodic-first" }.count, 1,
            "expected exactly one capturesCreate call for periodic-first, got: \(clientIds)"
        )
        XCTAssertEqual(
            clientIds.filter { $0 == "periodic-second" }.count, 1,
            "expected exactly one capturesCreate call for periodic-second, got: \(clientIds)"
        )
        XCTAssertEqual(try store.draft(clientId: "periodic-first")?.localState, .synced)
        XCTAssertEqual(try store.draft(clientId: "periodic-second")?.localState, .synced)
    }

    // MARK: - Currently-silent `store.drafts(in:)` read failure is now logged

    func testDraftsReadFailureLogsReadFailureMessage() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft(clientId: "will-be-orphaned")
        try store.saveDraft(draft)

        // CaptureStore has no public API to simulate a read failure, so this
        // reaches past it and drops the underlying table via the sqlite3 CLI
        // -- the same failure shape a real corrupted/locked DB would produce
        // for `store.drafts(in:)`, which today fails silently inside
        // `drainOnce()`.
        let dbURL = try XCTUnwrap(
            try FileManager.default
                .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "sqlite" }
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbURL.path, "DROP TABLE pending_captures;"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "expected sqlite3 CLI to drop the table successfully")

        let convex = FakeConvexService()
        let logs = LogCollector()
        let engine = SyncEngine(store: store, convex: convex, logger: logs.log)

        let synced = await engine.drainOnce()

        XCTAssertEqual(synced, [])
        XCTAssertTrue(
            logs.messages.contains { $0.contains("read") },
            "expected a log message describing the drafts-read failure, got: \(logs.messages)"
        )
    }
}
