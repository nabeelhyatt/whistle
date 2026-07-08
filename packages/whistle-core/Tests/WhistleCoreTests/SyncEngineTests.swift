// SyncEngineTests.swift
// Plan U5 scenarios: offline drain stays queued then drains in order;
// captures.create failure -> syncFailed -> local retry with same clientId;
// screenshot-upload failure keeps the whole capture queued (atomic).

import Foundation
import XCTest
@testable import WhistleCore

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
}
