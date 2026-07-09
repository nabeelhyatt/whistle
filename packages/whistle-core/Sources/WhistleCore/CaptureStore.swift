// CaptureStore.swift
// GRDB-backed local persistence (TECH-SPEC §4.1 `CaptureStore` row):
// - pending_captures: the offline-first capture queue (draft/queued/syncing/
//   synced/syncFailed).
// - history_cache: a local mirror of recent server capture records, so
//   History has data offline.
// - projects_snapshot: the last-fetched `projects.list` result, so the
//   project picker works offline.
// - app_state: small key/value table; currently just last-used project.
//
// No AppKit/UIKit. Screenshot bytes are handled as on-disk temp files
// referenced by path (CaptureDraft.screenshotPath), not as blobs in SQLite.

import Foundation
import GRDB

// MARK: - Errors

public enum CaptureStoreError: Error, Equatable {
    case notFound(clientId: String)
    case screenshotWriteFailed(String)
}

// MARK: - Row types

/// GRDB row for `pending_captures`. Wraps `CaptureDraft` with the columns
/// GRDB needs (`clientId` is the primary key — the natural idempotency key).
private struct PendingCaptureRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pending_captures"

    var clientId: String
    var transcript: String
    var notes: String
    var screenshotPath: String?
    var projectId: String
    var projectName: String
    var agent: String
    var model: String?
    var capturedAt: Date
    var localState: String
    var localAttempt: Int
    var serverId: String?
    var localError: String?

    init(draft: CaptureDraft) {
        clientId = draft.clientId
        transcript = draft.transcript
        notes = draft.notes
        screenshotPath = draft.screenshotPath
        projectId = draft.projectId
        projectName = draft.projectName
        agent = draft.agent
        model = draft.model
        capturedAt = draft.capturedAt
        localState = draft.localState.rawValue
        localAttempt = draft.localAttempt
        serverId = draft.serverId
        localError = draft.localError
    }

    var asDraft: CaptureDraft {
        CaptureDraft(
            clientId: clientId,
            transcript: transcript,
            notes: notes,
            screenshotPath: screenshotPath,
            projectId: projectId,
            projectName: projectName,
            agent: agent,
            model: model,
            capturedAt: capturedAt,
            localState: LocalCaptureState(rawValue: localState) ?? .draft,
            localAttempt: localAttempt,
            serverId: serverId,
            localError: localError
        )
    }
}

/// GRDB row for `history_cache`: a local mirror of the last-known server
/// capture record, encoded as JSON in a single column for simplicity (this
/// table exists purely as an offline read cache, not a query surface beyond
/// "give me everything, newest first").
private struct HistoryCacheRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "history_cache"

    var id: String
    var capturedAt: Date
    var recordJSON: Data

    init(record: ServerCaptureRecord) throws {
        id = record.id
        capturedAt = record.capturedAt
        recordJSON = try CaptureStore.makeEncoder().encode(record)
    }

    var asRecord: ServerCaptureRecord? {
        try? CaptureStore.makeDecoder().decode(ServerCaptureRecord.self, from: recordJSON)
    }
}

/// GRDB row for `projects_snapshot`: the last-fetched projects list, stored
/// as a single row (id fixed at 1) containing the whole JSON array — the
/// picker only ever needs "the latest snapshot," never per-project queries.
private struct ProjectsSnapshotRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects_snapshot"

    var id: Int
    var projectsJSON: Data
    var fetchedAt: Date

    init(projects: [Project], fetchedAt: Date) throws {
        id = 1
        projectsJSON = try CaptureStore.makeEncoder().encode(projects)
        self.fetchedAt = fetchedAt
    }

    var asProjects: [Project] {
        (try? CaptureStore.makeDecoder().decode([Project].self, from: projectsJSON)) ?? []
    }
}

/// GRDB row for `app_state`: generic key/value for small persisted bits of
/// app state that belong in WhistleCore (not UserDefaults) so they're
/// testable and iOS-portable. Currently just `last_used_project_id`.
private struct AppStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_state"

    var key: String
    var value: String
}

private enum AppStateKey {
    static let lastUsedProjectId = "last_used_project_id"
}

// MARK: - CaptureStore

/// The single owner of the local SQLite database. All access goes through
/// GRDB's own serial queue (TECH-SPEC §4.1 concurrency note) — no extra
/// actor wrapper needed.
public final class CaptureStore: Sendable {
    private let dbQueue: DatabaseQueue
    private let screenshotsDirectory: URL

    /// - Parameters:
    ///   - path: Path to the SQLite file. Pass `nil` for an in-memory DB
    ///     (mostly for quick tests); production/tests-that-need-persistence
    ///     should pass a real temp-file path per TECH-SPEC §13 U5 ("real temp
    ///     SQLite db").
    ///   - screenshotsDirectory: Directory used to stage screenshot JPEGs
    ///     referenced by `CaptureDraft.screenshotPath`. Created if missing.
    public init(path: String?, screenshotsDirectory: URL) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        self.screenshotsDirectory = screenshotsDirectory
        try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
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

        return migrator
    }

    // MARK: JSON coding (shared Date strategy for all JSON blob columns)

    fileprivate static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    fileprivate static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - pending_captures (the queue)

    /// Inserts or replaces a draft by `clientId` (upsert — safe to call
    /// repeatedly for the same clientId, e.g. after local field edits).
    public func saveDraft(_ draft: CaptureDraft) throws {
        try dbQueue.write { db in
            try PendingCaptureRow(draft: draft).save(db)
        }
        notifyPendingChanged()
    }

    public func draft(clientId: String) throws -> CaptureDraft? {
        try dbQueue.read { db in
            try PendingCaptureRow.fetchOne(db, key: clientId)?.asDraft
        }
    }

    /// All drafts in a given local state, oldest-captured first — the order
    /// SyncEngine drains in (TECH-SPEC §13 U5: "drains in order").
    public func drafts(in states: [LocalCaptureState]) throws -> [CaptureDraft] {
        let rawStates = states.map { $0.rawValue }
        return try dbQueue.read { db in
            try PendingCaptureRow
                .filter(rawStates.contains(Column("localState")))
                .order(Column("capturedAt").asc)
                .fetchAll(db)
                .map { $0.asDraft }
        }
    }

    public func allDrafts() throws -> [CaptureDraft] {
        try dbQueue.read { db in
            try PendingCaptureRow
                .order(Column("capturedAt").asc)
                .fetchAll(db)
                .map { $0.asDraft }
        }
    }

    /// Updates a draft's local state (and optionally serverId/localError),
    /// throwing if no such clientId exists.
    @discardableResult
    public func updateLocalState(
        clientId: String,
        to state: LocalCaptureState,
        serverId: String? = nil,
        localError: String? = nil
    ) throws -> CaptureDraft {
        let updated: CaptureDraft = try dbQueue.write { db in
            guard var row = try PendingCaptureRow.fetchOne(db, key: clientId) else {
                throw CaptureStoreError.notFound(clientId: clientId)
            }
            row.localState = state.rawValue
            if let serverId {
                row.serverId = serverId
            }
            // localError is explicitly reset to nil on any successful
            // transition away from syncFailed by passing localError: nil
            // is indistinguishable from "don't touch it" with Optional, so
            // callers that want to clear it pass an empty string instead of
            // relying on this parameter's nil case; simplest: always set it
            // to whatever was passed (nil clears, matching "retry succeeded"
            // semantics for the common call sites in SyncEngine).
            row.localError = localError
            try row.save(db)
            return row.asDraft
        }
        notifyPendingChanged()
        return updated
    }

    /// Increments `localAttempt` for a draft (used by SyncEngine backoff).
    @discardableResult
    public func incrementLocalAttempt(clientId: String) throws -> CaptureDraft {
        let updated: CaptureDraft = try dbQueue.write { db in
            guard var row = try PendingCaptureRow.fetchOne(db, key: clientId) else {
                throw CaptureStoreError.notFound(clientId: clientId)
            }
            row.localAttempt += 1
            try row.save(db)
            return row.asDraft
        }
        notifyPendingChanged()
        return updated
    }

    /// Removes a draft entirely from the local queue (e.g. once `synced`
    /// and mirrored into history_cache, it no longer needs to live in the
    /// queue — callers decide when that is; CaptureStore doesn't do this
    /// automatically so SyncEngine controls the exact handoff moment).
    public func deleteDraft(clientId: String) throws {
        _ = try dbQueue.write { db in
            try PendingCaptureRow.deleteOne(db, key: clientId)
        }
        notifyPendingChanged()
    }

    // MARK: - Screenshot temp-file handling

    /// Writes `data` to a fresh temp file under the store's screenshots
    /// directory, named after `clientId`, and returns its path. Overwrites
    /// any existing screenshot for this clientId.
    @discardableResult
    public func writeScreenshot(_ data: Data, clientId: String) throws -> String {
        let url = screenshotsDirectory.appendingPathComponent("\(clientId).jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureStoreError.screenshotWriteFailed(error.localizedDescription)
        }
        return url.path
    }

    public func screenshotData(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// Deletes the on-disk screenshot file for a draft, if any, and clears
    /// `screenshotPath` on the stored row.
    public func removeScreenshot(clientId: String) throws {
        try dbQueue.write { db in
            guard var row = try PendingCaptureRow.fetchOne(db, key: clientId) else {
                return
            }
            if let path = row.screenshotPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            row.screenshotPath = nil
            try row.save(db)
        }
        notifyPendingChanged()
    }

    // MARK: - history_cache

    /// Replaces (or inserts) the cached copy of a server record. Called
    /// whenever a `captures.listRecent`/`captures.list`/`captures.get`
    /// subscription yields, so History has data offline.
    public func cacheHistory(_ records: [ServerCaptureRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try HistoryCacheRow(record: record).save(db)
            }
        }
        notifyHistoryChanged()
    }

    /// All cached server records, newest-captured first.
    public func cachedHistory() throws -> [ServerCaptureRecord] {
        try dbQueue.read { db in
            try HistoryCacheRow
                .order(Column("capturedAt").desc)
                .fetchAll(db)
                .compactMap { $0.asRecord }
        }
    }

    public func cachedHistoryRecord(id: String) throws -> ServerCaptureRecord? {
        try dbQueue.read { db in
            try HistoryCacheRow.fetchOne(db, key: id)?.asRecord
        }
    }

    // MARK: - projects_snapshot

    /// Overwrites the single projects snapshot row. Called whenever
    /// `projects.list` yields.
    public func saveProjectsSnapshot(_ projects: [Project], fetchedAt: Date = Date()) throws {
        try dbQueue.write { db in
            try ProjectsSnapshotRow(projects: projects, fetchedAt: fetchedAt).save(db)
        }
        notifyProjectsChanged()
    }

    public func projectsSnapshot() throws -> [Project] {
        try dbQueue.read { db in
            try ProjectsSnapshotRow.fetchOne(db, key: 1)?.asProjects ?? []
        }
    }

    public func projectsSnapshotFetchedAt() throws -> Date? {
        try dbQueue.read { db in
            try ProjectsSnapshotRow.fetchOne(db, key: 1)?.fetchedAt
        }
    }

    // MARK: - app_state (last-used project)

    public func setLastUsedProjectId(_ projectId: String) throws {
        try dbQueue.write { db in
            try AppStateRow(key: AppStateKey.lastUsedProjectId, value: projectId).save(db)
        }
    }

    public func lastUsedProjectId() throws -> String? {
        try dbQueue.read { db in
            try AppStateRow.fetchOne(db, key: AppStateKey.lastUsedProjectId)?.value
        }
    }

    // MARK: - AsyncSequence updates for UI

    private let pendingContinuations = ContinuationRegistry<[CaptureDraft]>()
    private let historyContinuations = ContinuationRegistry<[ServerCaptureRecord]>()
    private let projectsContinuations = ContinuationRegistry<[Project]>()

    /// Emits the full current queue every time `pending_captures` changes,
    /// starting with the current contents immediately upon subscription.
    public func pendingCapturesUpdates() -> AsyncStream<[CaptureDraft]> {
        pendingContinuations.makeStream { [weak self] in
            (try? self?.allDrafts()) ?? []
        }
    }

    /// Emits the full cached history every time it changes, starting with
    /// current contents immediately upon subscription.
    public func historyUpdates() -> AsyncStream<[ServerCaptureRecord]> {
        historyContinuations.makeStream { [weak self] in
            (try? self?.cachedHistory()) ?? []
        }
    }

    /// Emits the projects snapshot every time it changes, starting with
    /// current contents immediately upon subscription.
    public func projectsUpdates() -> AsyncStream<[Project]> {
        projectsContinuations.makeStream { [weak self] in
            (try? self?.projectsSnapshot()) ?? []
        }
    }

    private func notifyPendingChanged() {
        let drafts = (try? allDrafts()) ?? []
        pendingContinuations.yield(drafts)
    }

    private func notifyHistoryChanged() {
        let records = (try? cachedHistory()) ?? []
        historyContinuations.yield(records)
    }

    private func notifyProjectsChanged() {
        let projects = (try? projectsSnapshot()) ?? []
        projectsContinuations.yield(projects)
    }
}

// MARK: - ContinuationRegistry

/// Small helper that fans a single "value changed" event out to any number
/// of `AsyncStream` subscribers, each of which also gets the current value
/// immediately on subscription. Thread-safe via a lock (CaptureStore itself
/// synchronizes actual data access through GRDB's serial queue; this only
/// protects the continuation bookkeeping).
private final class ContinuationRegistry<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
    private var nextId = 0

    func makeStream(currentValue: @escaping () -> Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id: Int = lock.withLock {
                let id = nextId
                nextId += 1
                continuations[id] = continuation
                return id
            }
            continuation.yield(currentValue())
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    func yield(_ value: Value) {
        lock.withLock {
            for continuation in continuations.values {
                continuation.yield(value)
            }
        }
    }

    private func remove(_ id: Int) {
        lock.withLock {
            _ = continuations.removeValue(forKey: id)
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
