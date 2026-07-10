// CaptureViewModelTests.swift
// Plan U8 scenarios:
//   - Happy: submit with transcript+notes+screenshot+project -> correct
//     CaptureDraft queued, panel closed. (Panel-close itself is
//     CapturePanelController's job; here we assert submit() queues the
//     draft and reports .submitted, which is what drives the controller
//     to close.) Run against both panel modes via CapturePanelModeTests.
//   - Edge: submit disabled when transcript, notes, and screenshot are all
//     empty; enabled for screenshot-only (auto-note injected).
//   - Edge: screenshot removed -> draft has nil screenshot.
//   - Edge: hotkey while panel open -> focuses existing panel, no second
//     screenshot (CapturePanelController-level; exercised here via a
//     dedicated test using CapturePanelController directly).
//   - Edge: Esc with content -> confirm; Esc empty -> close.
//   - Error: mic denied -> type-only mode flag set, panel still opens.
//   - Happy: last-used project preselected; selection updates app_state.
//   - Happy: opening with a pre-fill (duplicate-as-new-capture) populates
//     transcript/notes/screenshot and focuses the project picker, with a
//     freshly minted clientId.

import CoreGraphics
import XCTest
@testable import Whistle
@testable import WhistleCore

// MARK: - Fakes

/// Scriptable fake `TranscriptionService` — never touches real audio/
/// speech APIs. `start()` replays a scripted sequence of updates;
/// `stop()` just records that it was called.
actor FakeTranscriptionService: TranscriptionService {
    private var scriptedUpdates: [TranscriptUpdate]
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?

    init(scriptedUpdates: [TranscriptUpdate] = []) {
        self.scriptedUpdates = scriptedUpdates
    }

    func start() -> AsyncStream<TranscriptUpdate> {
        startCallCount += 1
        let updates = scriptedUpdates
        return AsyncStream { continuation in
            self.continuation = continuation
            Task {
                for update in updates {
                    continuation.yield(update)
                    await Task.yield()
                }
            }
        }
    }

    func stop() async {
        stopCallCount += 1
        continuation?.finish()
    }
}

@MainActor
private enum TestSupport {
    static func makeStore() throws -> (store: CaptureStore, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")
        let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        return (store, tempDir)
    }

    static let project1 = Project(id: "proj-1", name: "Project One", gitRemote: "git@example.com:one.git")
    static let project2 = Project(id: "proj-2", name: "Project Two", gitRemote: "git@example.com:two.git")

    static func makeViewModel(
        store: CaptureStore,
        micAuthorized: Bool = true,
        transcriptionUpdates: [TranscriptUpdate] = []
    ) -> (viewModel: CaptureViewModel, transcription: FakeTranscriptionService) {
        let fake = FakeTranscriptionService(scriptedUpdates: transcriptionUpdates)
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionChecker: { micAuthorized }
        )
        return (viewModel, fake)
    }

    static let sampleScreenshot = Data([0xFF, 0xD8, 0xFF, 0xD9]) // minimal JPEG-ish bytes, content irrelevant to tests
}

final class CaptureViewModelTests: XCTestCase {
    // MARK: Happy: submit with transcript+notes+screenshot+project -> correct CaptureDraft queued

    @MainActor
    func testSubmitWithAllFieldsQueuesCorrectDraft() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1, TestSupport.project2])

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.transcriptText = "a transcript"
        viewModel.notesText = "some notes"
        viewModel.attachScreenshot(TestSupport.sampleScreenshot)
        viewModel.selectProject(TestSupport.project2.id)

        let result = viewModel.submit()

        guard case .submitted(let clientId) = result else {
            XCTFail("expected .submitted")
            return
        }

        let draft = try store.draft(clientId: clientId)
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.transcript, "a transcript")
        XCTAssertEqual(draft?.notes, "some notes")
        XCTAssertEqual(draft?.projectId, TestSupport.project2.id)
        XCTAssertEqual(draft?.projectName, TestSupport.project2.name)
        XCTAssertEqual(draft?.localState, .queued)
        XCTAssertNotNil(draft?.screenshotPath)
        if let path = draft?.screenshotPath {
            XCTAssertEqual(store.screenshotData(atPath: path), TestSupport.sampleScreenshot)
        }
    }

    // MARK: Edge: submit disabled when all empty; enabled for screenshot-only with auto-note

    @MainActor
    func testCanSubmitIsFalseWhenTranscriptNotesAndScreenshotAllEmpty() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()

        XCTAssertFalse(viewModel.canSubmit)

        let result = viewModel.submit()
        XCTAssertEqual(result, .refusedEmpty)
        XCTAssertTrue(try store.allDrafts().isEmpty)
    }

    @MainActor
    func testScreenshotOnlySubmitIsEnabledAndInjectsAutoNote() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1])

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.attachScreenshot(TestSupport.sampleScreenshot)

        XCTAssertTrue(viewModel.canSubmit)

        let result = viewModel.submit()
        guard case .submitted(let clientId) = result else {
            XCTFail("expected .submitted")
            return
        }

        let draft = try store.draft(clientId: clientId)
        XCTAssertEqual(draft?.notes, CaptureAutoNote.screenshotOnly)
        XCTAssertEqual(draft?.transcript, "")
    }

    // MARK: Edge: screenshot removed -> draft has nil screenshot

    @MainActor
    func testRemovedScreenshotResultsInNilScreenshotPathInDraft() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1])

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.transcriptText = "keep this"
        viewModel.attachScreenshot(TestSupport.sampleScreenshot)
        viewModel.removeScreenshot()

        let result = viewModel.submit()
        guard case .submitted(let clientId) = result else {
            XCTFail("expected .submitted")
            return
        }

        let draft = try store.draft(clientId: clientId)
        XCTAssertNil(draft?.screenshotPath)
    }

    // MARK: Edge: Esc with content -> confirm; Esc empty -> close

    @MainActor
    func testEscActionIsCloseWhenEmpty() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()

        XCTAssertEqual(viewModel.escAction(), .close)
    }

    @MainActor
    func testEscActionIsConfirmThenCloseWhenContentExists() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.transcriptText = "something"

        XCTAssertEqual(viewModel.escAction(), .confirmThenClose)
    }

    @MainActor
    func testEscActionIsConfirmThenCloseWhenOnlyScreenshotPresent() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.attachScreenshot(TestSupport.sampleScreenshot)

        XCTAssertEqual(viewModel.escAction(), .confirmThenClose)
    }

    // MARK: Error: mic denied -> type-only mode flag set, panel still opens

    @MainActor
    func testMicDeniedSetsTypeOnlyFlagAndDoesNotStartTranscription() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, transcription) = TestSupport.makeViewModel(store: store, micAuthorized: false)
        viewModel.beginCapture()

        XCTAssertTrue(viewModel.isMicDenied)

        let expectation = expectation(description: "give async start() a chance to fire if it incorrectly does")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1)

        let startCount = await transcription.startCallCount
        XCTAssertEqual(startCount, 0, "transcription must not start when mic is denied")

        // Panel still "opens" -- i.e. the view model is usable in type-only
        // mode: submit works with just typed content.
        viewModel.notesText = "typed while mic denied"
        XCTAssertTrue(viewModel.canSubmit)
    }

    @MainActor
    func testMicAuthorizedStartsTranscriptionAndAppliesUpdates() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, transcription) = TestSupport.makeViewModel(
            store: store,
            micAuthorized: true,
            transcriptionUpdates: [
                TranscriptUpdate(committed: "", live: "hello"),
                TranscriptUpdate(committed: "hello world", live: ""),
            ]
        )
        viewModel.beginCapture()

        // Poll briefly for the async stream to deliver both updates.
        for _ in 0..<50 where viewModel.transcriptText != "hello world" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(viewModel.isMicDenied)
        XCTAssertEqual(viewModel.transcriptText, "hello world")
        let startCount = await transcription.startCallCount
        XCTAssertEqual(startCount, 1)
    }

    // MARK: Happy: last-used project preselected; selection updates app_state

    @MainActor
    func testLastUsedProjectIsPreselected() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1, TestSupport.project2])
        try store.setLastUsedProjectId(TestSupport.project2.id)

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()

        XCTAssertEqual(viewModel.selectedProjectId, TestSupport.project2.id)
    }

    @MainActor
    func testSelectingProjectPersistsToAppState() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1, TestSupport.project2])

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.selectProject(TestSupport.project2.id)

        XCTAssertEqual(try store.lastUsedProjectId(), TestSupport.project2.id)
    }

    @MainActor
    func testFallsBackToFirstProjectWhenNoLastUsedRecorded() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1, TestSupport.project2])

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()

        XCTAssertEqual(viewModel.selectedProjectId, TestSupport.project1.id)
    }

    // MARK: Happy: pre-fill (duplicate-as-new-capture) populates fields, focuses picker, mints new clientId

    @MainActor
    func testPreFillPopulatesFieldsFocusesProjectPickerAndMintsFreshClientId() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1])

        let (viewModel, _) = TestSupport.makeViewModel(store: store)

        // First, an ordinary capture with some clientId.
        viewModel.beginCapture()
        let firstClientId = viewModel.clientId

        // Now open with a duplicate-as-new-capture pre-fill.
        let preFill = CapturePreFill(
            transcript: "original transcript",
            notes: "original notes",
            screenshotData: TestSupport.sampleScreenshot,
            focusProjectPicker: true
        )
        viewModel.beginCapture(preFill: preFill)

        XCTAssertEqual(viewModel.transcriptText, "original transcript")
        XCTAssertEqual(viewModel.notesText, "original notes")
        XCTAssertEqual(viewModel.screenshotData, TestSupport.sampleScreenshot)
        XCTAssertTrue(viewModel.focusProjectPicker)
        XCTAssertNotEqual(viewModel.clientId, firstClientId, "pre-fill must mint a fresh clientId")
    }

    @MainActor
    func testOrdinaryCaptureDoesNotRequestProjectPickerFocus() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()

        XCTAssertFalse(viewModel.focusProjectPicker)
    }
}

// MARK: - CapturePanelController: duplicate-trigger + both panel modes

final class CapturePanelControllerTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> (store: CaptureStore, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-panel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let screenshotsDir = tempDir.appendingPathComponent("screenshots")
        let store = try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        return (store, tempDir)
    }

    /// Fake screenshot service that counts capture() invocations, so the
    /// "duplicate trigger while open -> no second screenshot" scenario is
    /// directly assertable.
    private func makeCountingScreenshotService(counter: CaptureCounter) -> ScreenshotService {
        ScreenshotService(
            preflight: CountingPreflight(counter: counter),
            capturer: CountingCapturer()
        )
    }

    // MARK: Happy: submit with all fields, run against BOTH panel modes ->
    // draft queued, panel closed (plan U8 verification: "Run against both
    // panel modes").

    @MainActor
    func testSubmitQueuesDraftAndClosesPanelUnderBothModes() async throws {
        for mode in [CapturePanelMode.nonActivating, CapturePanelMode.activating] {
            let (store, tempDir) = try makeStore()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try store.saveProjectsSnapshot([TestSupport.project1])

            let controller = CapturePanelController(
                store: store,
                mode: mode,
                transcriptionServiceFactory: { FakeTranscriptionService() },
                micPermissionChecker: { true }
            )
            controller.trigger()
            try await Task.sleep(nanoseconds: 20_000_000)

            XCTAssertTrue(controller.isPanelOpen, "mode \(mode): panel should be open after trigger()")
            controller.currentViewModel?.transcriptText = "transcript for \(mode)"
            controller.currentViewModel?.selectProject(TestSupport.project1.id)

            controller.submitCurrentForTesting()

            XCTAssertFalse(controller.isPanelOpen, "mode \(mode): panel should close after submit")

            let drafts = try store.allDrafts()
            XCTAssertEqual(drafts.count, 1, "mode \(mode): exactly one draft queued")
            XCTAssertEqual(drafts.first?.transcript, "transcript for \(mode)")
            XCTAssertEqual(drafts.first?.projectId, TestSupport.project1.id)
        }
    }

    @MainActor
    func testDuplicateTriggerWhilePanelOpenFocusesExistingPanelWithoutSecondScreenshot() async throws {
        for mode in [CapturePanelMode.nonActivating, CapturePanelMode.activating] {
            let (store, tempDir) = try makeStore()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let counter = CaptureCounter()
            let screenshotService = makeCountingScreenshotService(counter: counter)
            let controller = CapturePanelController(
                store: store,
                screenshotService: screenshotService,
                mode: mode,
                transcriptionServiceFactory: { FakeTranscriptionService() },
                micPermissionChecker: { true }
            )

            controller.trigger()
            // Allow the async screenshot capture task to run.
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(counter.count, 1, "mode \(mode): first trigger should capture exactly one screenshot")

            controller.trigger()
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(counter.count, 1, "mode \(mode): duplicate trigger while open must not re-screenshot")
        }
    }
}

private final class CaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
    func increment() {
        lock.lock(); _count += 1; lock.unlock()
    }
}

private struct CountingPreflight: ScreenCapturePreflightChecking {
    let counter: CaptureCounter
    func isScreenCaptureAccessGranted() -> Bool {
        counter.increment()
        return true
    }
}

private struct CountingCapturer: DisplayImageCapturing {
    func captureDisplayUnderCursor() async -> CGImage? { nil }
}
