// Fakes.swift
// Test doubles shared across WhistleCoreTests. No network, no real Convex —
// per plan U5: "Fake ConvexService via the protocol — no network in tests."

import Foundation
import XCTest
@testable import WhistleCore

// MARK: - FakeConvexService

/// In-memory `ConvexServiceProtocol` double. Every method is scriptable via
/// closures/properties so individual tests can simulate specific failures
/// (e.g. `captures.create` throwing) without any real I/O.
final class FakeConvexService: ConvexServiceProtocol, @unchecked Sendable {
    // MARK: Scripting hooks

    /// Called for every `capturesCreate`; return a storageId or throw.
    var onCapturesCreate: (@Sendable (CaptureCreateInput) async throws -> String) = { input in
        "server-\(input.clientId)"
    }
    /// Called for every `filesGenerateUploadUrl`; return a URL string or throw.
    var onGenerateUploadUrl: (@Sendable () async throws -> String) = {
        "https://example.convex.cloud/upload/fake"
    }

    // MARK: Call recording (for assertions)

    private let lock = NSLock()
    private(set) var capturesCreateCalls: [CaptureCreateInput] = []
    private(set) var generateUploadUrlCallCount = 0
    private(set) var markOpenedCalls: [String] = []
    private(set) var archiveCalls: [String] = []
    private(set) var retryCalls: [String] = []

    private func record<T>(_ mutate: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return mutate()
    }

    // MARK: users

    func usersEnsure() async throws -> String { "user-1" }

    // MARK: settings

    var settingsSnapshot = SettingsSnapshot(
        defaultProjectId: nil, agent: "claude", model: nil, screenshotsEnabled: true, hasKey: false, lastFour: nil
    )

    func settingsGet() async throws -> SettingsSnapshot { settingsSnapshot }
    func settingsUpdate(_ patch: SettingsPatch) async throws {}
    func settingsSetConductorKey(_ key: String) async throws {}

    // MARK: conductor

    var validateKeyResult = true
    func conductorValidateKey(key: String?) async throws -> Bool { validateKeyResult }

    private(set) var refreshProjectsCallCount = 0
    func conductorRefreshProjects() async throws {
        _ = record { refreshProjectsCallCount += 1 }
    }

    // MARK: projects

    private var projectsContinuations: [UUID: AsyncStream<[Project]>.Continuation] = [:]
    func projectsList() -> AsyncStream<[Project]> {
        AsyncStream { continuation in
            let id = UUID()
            self.record { self.projectsContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.record { self.projectsContinuations.removeValue(forKey: id) }
            }
        }
    }

    /// `projectsList()`'s continuation is only registered once something
    /// actually starts iterating the stream (e.g. once
    /// `ProjectsSyncCoordinator.start()`'s unstructured `Task` gets
    /// scheduled) -- since that's asynchronous, a caller that immediately
    /// enables the coordinator and immediately calls `yieldProjects(...)`
    /// can otherwise race ahead of subscription and drop the yield (no
    /// continuation registered yet to receive it). Bounded-wait for a
    /// subscriber first, mirroring `FakeHistoryConvexService.yield`'s same
    /// fix for the identical race on `capturesListRecent`.
    func yieldProjects(_ projects: [Project], timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while activeProjectsSubscriptionCount == 0 {
            if Date() >= deadline {
                XCTFail("FakeConvexService.yieldProjects timed out waiting for a subscriber")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let continuations = record { Array(projectsContinuations.values) }
        continuations.forEach { $0.yield(projects) }
    }

    var activeProjectsSubscriptionCount: Int {
        record { projectsContinuations.count }
    }

    func finishProjectSubscriptions() {
        let continuations = record { Array(projectsContinuations.values) }
        continuations.forEach { $0.finish() }
    }

    // MARK: templates

    var templateSnapshot = TemplateSnapshot(body: "default", isCustomized: false, updatedAt: Date(timeIntervalSince1970: 0))
    func templatesGet() async throws -> TemplateSnapshot { templateSnapshot }
    func templatesUpdate(body: String) async throws {}
    func templatesReset() async throws {}

    // MARK: files

    func filesGenerateUploadUrl() async throws -> String {
        _ = record { generateUploadUrlCallCount += 1 }
        return try await onGenerateUploadUrl()
    }

    // MARK: captures

    func capturesCreate(_ input: CaptureCreateInput) async throws -> String {
        _ = record { capturesCreateCalls.append(input) }
        return try await onCapturesCreate(input)
    }

    private var listRecentContinuation: AsyncStream<[ServerCaptureRecord]>.Continuation?
    func capturesListRecent(limit: Int) -> AsyncStream<[ServerCaptureRecord]> {
        AsyncStream { continuation in
            self.listRecentContinuation = continuation
        }
    }

    func yieldListRecent(_ records: [ServerCaptureRecord]) {
        listRecentContinuation?.yield(records)
    }

    var capturesListResult: [ServerCaptureRecord] = []
    func capturesList() async throws -> [ServerCaptureRecord] { capturesListResult }

    var capturesGetResult: ServerCaptureRecord?
    func capturesGet(id: String) async throws -> ServerCaptureRecord? { capturesGetResult }

    func capturesRetry(id: String) async throws {
        _ = record { retryCalls.append(id) }
    }

    func capturesDeleteScreenshot(id: String) async throws {}

    func capturesMarkOpened(id: String) async throws {
        _ = record { markOpenedCalls.append(id) }
    }

    func capturesArchive(id: String) async throws {
        _ = record { archiveCalls.append(id) }
    }
}

// MARK: - FakeScreenshotUploader

final class FakeScreenshotUploader: ScreenshotUploading, @unchecked Sendable {
    var onUpload: (@Sendable (Data, URL) async throws -> String) = { _, _ in "fake-storage-id" }
    private let lock = NSLock()
    private(set) var uploadCallCount = 0

    func upload(data: Data, to uploadUrl: URL) async throws -> String {
        lock.lock()
        uploadCallCount += 1
        lock.unlock()
        return try await onUpload(data, uploadUrl)
    }
}

// MARK: - FakeNetworkMonitor

final class FakeNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var online: Bool
    private var continuations: [AsyncStream<Bool>.Continuation] = []

    init(online: Bool = true) {
        self.online = online
    }

    var isOnline: Bool {
        get async {
            lock.lock()
            defer { lock.unlock() }
            return online
        }
    }

    func setOnline(_ value: Bool) {
        lock.lock()
        online = value
        let current = continuations
        lock.unlock()
        for continuation in current {
            continuation.yield(value)
        }
    }

    func pathUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            lock.lock()
            continuations.append(continuation)
            let current = online
            lock.unlock()
            continuation.yield(current)
        }
    }
}

// MARK: - Test helpers

enum TestSupport {
    /// Creates a `CaptureStore` backed by a real temp-file SQLite DB (per
    /// plan U5: "state round-trips through a real temp SQLite db"), plus a
    /// scratch screenshots directory. Both are under a fresh temp directory
    /// per call so tests never collide.
    static func makeStore() throws -> (store: CaptureStore, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")
        let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        return (store, tempDir)
    }

    static func makeDraft(
        clientId: String = UUID().uuidString,
        transcript: String = "a transcript",
        notes: String = "",
        screenshotPath: String? = nil,
        projectId: String = "proj-1",
        projectName: String = "Project One",
        capturedAt: Date = Date()
    ) -> CaptureDraft {
        CaptureDraft(
            clientId: clientId,
            transcript: transcript,
            notes: notes,
            screenshotPath: screenshotPath,
            projectId: projectId,
            projectName: projectName,
            agent: "claude",
            model: nil,
            capturedAt: capturedAt,
            localState: .queued
        )
    }

    static func makeServerRecord(
        id: String = UUID().uuidString,
        clientId: String = UUID().uuidString,
        status: CaptureServerStatus,
        errorCode: CaptureErrorCode? = nil,
        error: String? = nil,
        clarifyingQuestions: [String]? = nil,
        openedAt: Date? = nil,
        archivedAt: Date? = nil
    ) -> ServerCaptureRecord {
        ServerCaptureRecord(
            id: id,
            userId: "user-1",
            clientId: clientId,
            transcript: "t",
            notes: "n",
            projectId: "proj-1",
            projectName: "Project One",
            agent: "claude",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: status,
            errorCode: errorCode,
            error: error,
            clarifyingQuestions: clarifyingQuestions,
            openedAt: openedAt,
            archivedAt: archivedAt
        )
    }
}
