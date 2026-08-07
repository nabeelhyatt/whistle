// CaptureStoreTests.swift
// Plan U5 scenarios: state round-trips through a real temp SQLite db;
// projects snapshot survives relaunch/offline.

import Foundation
import GRDB
import XCTest
@testable import WhistleCore

final class CaptureStoreTests: XCTestCase {
    private var tempDir: URL!

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - draft -> queued -> syncing -> synced round-trip

    func testDraftLifecycleRoundTripsThroughRealSQLiteDB() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        var draft = TestSupport.makeDraft()
        draft.localState = .draft
        try store.saveDraft(draft)

        XCTAssertEqual(try store.draft(clientId: draft.clientId)?.localState, .draft)

        try store.updateLocalState(clientId: draft.clientId, to: .queued)
        XCTAssertEqual(try store.draft(clientId: draft.clientId)?.localState, .queued)

        try store.updateLocalState(clientId: draft.clientId, to: .syncing)
        XCTAssertEqual(try store.draft(clientId: draft.clientId)?.localState, .syncing)

        try store.updateLocalState(clientId: draft.clientId, to: .synced, serverId: "server-123")
        let final = try store.draft(clientId: draft.clientId)
        XCTAssertEqual(final?.localState, .synced)
        XCTAssertEqual(final?.serverId, "server-123")
    }

    // Re-open the same DB file (simulating relaunch) and confirm the row
    // is still there with the same state — proves this isn't just an
    // in-memory round trip.
    func testDraftPersistsAcrossStoreReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDir = tempDir
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")

        let draft = TestSupport.makeDraft(transcript: "persist me")

        do {
            let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
            try store.saveDraft(draft)
        }

        // Fresh CaptureStore instance, same path — simulates app relaunch.
        let reopened = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        let fetched = try reopened.draft(clientId: draft.clientId)
        XCTAssertEqual(fetched?.transcript, "persist me")
        XCTAssertEqual(fetched?.localState, .queued)
    }

    func testUpdateLocalStateThrowsForUnknownClientId() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        XCTAssertThrowsError(try store.updateLocalState(clientId: "does-not-exist", to: .synced)) { error in
            XCTAssertEqual(error as? CaptureStoreError, .notFound(clientId: "does-not-exist"))
        }
    }

    func testIncrementLocalAttempt() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft()
        try store.saveDraft(draft)

        let updated1 = try store.incrementLocalAttempt(clientId: draft.clientId)
        XCTAssertEqual(updated1.localAttempt, 1)
        let updated2 = try store.incrementLocalAttempt(clientId: draft.clientId)
        XCTAssertEqual(updated2.localAttempt, 2)
    }

    func testDeleteDraftRemovesRow() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let draft = TestSupport.makeDraft()
        try store.saveDraft(draft)
        XCTAssertNotNil(try store.draft(clientId: draft.clientId))

        try store.deleteDraft(clientId: draft.clientId)
        XCTAssertNil(try store.draft(clientId: draft.clientId))
    }

    // MARK: - orgId (multi-org plan, v2_pending_captures_org_id)

    func testPendingCaptureOrgIdRoundTrips() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        var draft = TestSupport.makeDraft(clientId: "org-draft")
        draft.orgId = "org-abc"
        try store.saveDraft(draft)
        XCTAssertEqual(try store.draft(clientId: "org-draft")?.orgId, "org-abc")

        // A draft saved with no orgId (pre-multi-org, or a single-key
        // account) must round-trip as nil, not fail to decode.
        let noOrgDraft = TestSupport.makeDraft(clientId: "no-org-draft")
        try store.saveDraft(noOrgDraft)
        XCTAssertNil(try store.draft(clientId: "no-org-draft")?.orgId)
    }

    func testMigrationFromV1AddsOrgIdColumnWithoutDataLoss() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDir = tempDir
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")

        // Simulate a database that only ever ran the original
        // "v1_create_tables" migration (a client that hasn't picked up the
        // multi-org migration yet), with one existing pending capture row,
        // by building that exact v1 schema directly through GRDB -- then
        // open it through the real `CaptureStore`, proving
        // `v2_pending_captures_org_id` runs cleanly against real
        // pre-migration data (not just a fresh v1+v2 database) and the
        // pre-existing row decodes with `orgId == nil`.
        var v1Migrator = DatabaseMigrator()
        v1Migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "pending_captures") { t in
                t.column("clientId", .text).primaryKey()
                t.column("transcript", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("screenshotPath", .text)
                t.column("projectId", .text).notNull()
                t.column("projectName", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("model", .text)
                t.column("capturedAt", .datetime).notNull()
                t.column("localState", .text).notNull()
                t.column("localAttempt", .integer).notNull().defaults(to: 0)
                t.column("serverId", .text)
                t.column("localError", .text)
            }
            try db.create(table: "history_cache") { t in
                t.column("id", .text).primaryKey()
                t.column("capturedAt", .datetime).notNull()
                t.column("recordJSON", .blob).notNull()
            }
            try db.create(table: "projects_snapshot") { t in
                t.column("id", .integer).primaryKey()
                t.column("projectsJSON", .blob).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "app_state") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        let v1Queue = try DatabaseQueue(path: dbPath)
        try v1Migrator.migrate(v1Queue)
        try v1Queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_captures
                    (clientId, transcript, notes, projectId, projectName, agent, capturedAt, localState, localAttempt)
                VALUES ('pre-migration', 'old transcript', '', 'proj-1', 'Project One', 'claude', ?, 'queued', 0)
                """,
                arguments: [Date(timeIntervalSince1970: 1_700_000_000)]
            )
        }

        // Now open through the real CaptureStore -- runs "v1_create_tables"
        // (already applied, a no-op) then "v2_pending_captures_org_id"
        // (adds the column), against this exact file.
        let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        let migrated = try store.draft(clientId: "pre-migration")
        XCTAssertEqual(migrated?.transcript, "old transcript")
        XCTAssertNil(migrated?.orgId, "a pre-migration row must decode with orgId == nil, not fail the migration")

        // And the migrated store can read/write orgId going forward.
        var newDraft = TestSupport.makeDraft(clientId: "post-migration")
        newDraft.orgId = "org-xyz"
        try store.saveDraft(newDraft)
        XCTAssertEqual(try store.draft(clientId: "post-migration")?.orgId, "org-xyz")
    }

    // MARK: - drafts(in:) ordering

    func testDraftsInStatesReturnsOldestFirst() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let old = TestSupport.makeDraft(clientId: "old", capturedAt: Date(timeIntervalSince1970: 100))
        let mid = TestSupport.makeDraft(clientId: "mid", capturedAt: Date(timeIntervalSince1970: 200))
        let new = TestSupport.makeDraft(clientId: "new", capturedAt: Date(timeIntervalSince1970: 300))

        // Insert out of order to prove ordering comes from the query, not
        // insertion order.
        try store.saveDraft(new)
        try store.saveDraft(old)
        try store.saveDraft(mid)

        let drafts = try store.drafts(in: [.queued])
        XCTAssertEqual(drafts.map(\.clientId), ["old", "mid", "new"])
    }

    // MARK: - Screenshot temp-file handling

    func testWriteAndReadScreenshot() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let data = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        let path = try store.writeScreenshot(data, clientId: "abc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(store.screenshotData(atPath: path), data)
    }

    func testRemoveScreenshotDeletesFileAndClearsPath() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let data = Data([0x01, 0x02])
        let path = try store.writeScreenshot(data, clientId: "clientA")
        var draft = TestSupport.makeDraft(clientId: "clientA")
        draft.screenshotPath = path
        try store.saveDraft(draft)

        try store.removeScreenshot(clientId: "clientA")

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(try store.draft(clientId: "clientA")?.screenshotPath)
    }

    // MARK: - history_cache

    func testCacheHistoryRoundTrips() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let record = TestSupport.makeServerRecord(id: "rec-1", status: .ready, clarifyingQuestions: ["Q1?"])
        try store.cacheHistory([record])

        let cached = try store.cachedHistory()
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached.first?.id, "rec-1")
        XCTAssertEqual(cached.first?.clarifyingQuestions, ["Q1?"])

        let single = try store.cachedHistoryRecord(id: "rec-1")
        XCTAssertEqual(single?.status, .ready)
    }

    func testCachedHistoryNewestFirst() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        var older = TestSupport.makeServerRecord(id: "older", status: .queued)
        older.capturedAt = Date(timeIntervalSince1970: 100)
        var newer = TestSupport.makeServerRecord(id: "newer", status: .queued)
        newer.capturedAt = Date(timeIntervalSince1970: 200)

        try store.cacheHistory([older, newer])
        let cached = try store.cachedHistory()
        XCTAssertEqual(cached.map(\.id), ["newer", "older"])
    }

    // MARK: - projects_snapshot survives relaunch/offline

    func testProjectsSnapshotSurvivesRelaunch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDir = tempDir
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")

        let projects = [
            Project(id: "p1", name: "Project One", gitRemote: "git@example.com:p1.git"),
            Project(id: "p2", name: "Project Two", gitRemote: "git@example.com:p2.git"),
        ]

        do {
            let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
            try store.saveProjectsSnapshot(projects)
        }

        // Simulate relaunch (and, implicitly, offline — no network calls
        // happen here at all) by opening a fresh CaptureStore over the same
        // file.
        let reopened = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        let snapshot = try reopened.projectsSnapshot()
        XCTAssertEqual(snapshot, projects)
    }

    func testProjectsSnapshotOverwritesPreviousSnapshot() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        try store.saveProjectsSnapshot([Project(id: "p1", name: "One", gitRemote: "r1")])
        try store.saveProjectsSnapshot([Project(id: "p2", name: "Two", gitRemote: "r2")])

        let snapshot = try store.projectsSnapshot()
        XCTAssertEqual(snapshot, [Project(id: "p2", name: "Two", gitRemote: "r2")])
    }

    // MARK: - app_state (last-used project)

    func testLastUsedProjectIdRoundTrips() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        XCTAssertNil(try store.lastUsedProjectId())
        try store.setLastUsedProjectId("proj-42")
        XCTAssertEqual(try store.lastUsedProjectId(), "proj-42")

        try store.setLastUsedProjectId("proj-99")
        XCTAssertEqual(try store.lastUsedProjectId(), "proj-99")
    }

    // MARK: - AsyncSequence updates for UI

    func testPendingCapturesUpdatesEmitsOnChange() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let stream = store.pendingCapturesUpdates()
        var iterator = stream.makeAsyncIterator()

        // First value: current (empty) state.
        let initial = await iterator.next()
        XCTAssertEqual(initial, [])

        let draft = TestSupport.makeDraft(clientId: "watched")
        try store.saveDraft(draft)

        let afterSave = await iterator.next()
        XCTAssertEqual(afterSave?.map(\.clientId), ["watched"])
    }

    func testHistoryUpdatesEmitsOnChange() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let stream = store.historyUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [])

        try store.cacheHistory([TestSupport.makeServerRecord(id: "r1", status: .ready)])
        let afterCache = await iterator.next()
        XCTAssertEqual(afterCache?.map(\.id), ["r1"])
    }

    func testProjectsUpdatesEmitsOnChange() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        self.tempDir = tempDir

        let stream = store.projectsUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [])

        let projects = [Project(id: "p1", name: "One", gitRemote: "r1")]
        try store.saveProjectsSnapshot(projects)
        let afterSave = await iterator.next()
        XCTAssertEqual(afterSave, projects)
    }
}
