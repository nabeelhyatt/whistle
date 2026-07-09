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

/// Step-controllable fake `TranscriptionService`: unlike
/// `FakeTranscriptionService` (which replays a fixed script as fast as
/// possible), `emit(_:)` pushes exactly one `TranscriptUpdate` at a time so
/// a test can assert `CaptureViewModel.transcriptText` between each step --
/// needed to pin down the exact real-world sequence in the "pause then
/// resume wipes the box" regression (volatile -> final -> task-restart's
/// new volatile), one update at a time.
actor ManualTranscriptionService: TranscriptionService {
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    /// Buffers `emit(_:)` calls that arrive before `start()` has actually
    /// run -- `CaptureViewModel.beginCapture()`/`resumeDraft()` kick off
    /// `service.start()` from an unstructured `Task`, so a test calling
    /// `emit(_:)` right after `beginCapture()` can otherwise race ahead of
    /// that task and silently drop the update (`continuation` still `nil`).
    private var pending: [TranscriptUpdate] = []
    private(set) var stopCallCount = 0

    func start() -> AsyncStream<TranscriptUpdate> {
        let (stream, continuation) = AsyncStream<TranscriptUpdate>.makeStream()
        self.continuation = continuation
        for update in pending {
            continuation.yield(update)
        }
        pending.removeAll()
        return stream
    }

    func emit(_ update: TranscriptUpdate) {
        if let continuation {
            continuation.yield(update)
        } else {
            pending.append(update)
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
        speechAuthorized: Bool = true,
        transcriptionUpdates: [TranscriptUpdate] = []
    ) -> (viewModel: CaptureViewModel, transcription: FakeTranscriptionService) {
        let fake = FakeTranscriptionService(scriptedUpdates: transcriptionUpdates)
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionChecker: { micAuthorized },
            speechPermissionChecker: { speechAuthorized }
        )
        return (viewModel, fake)
    }

    static let sampleScreenshot = Data([0xFF, 0xD8, 0xFF, 0xD9]) // minimal JPEG-ish bytes, content irrelevant to tests
}

/// Polls `condition` on the main actor until it's true or the timeout
/// elapses, so async-stream-driven `@Published` updates -- or AppKit window
/// visibility changes, which can lag behind `trigger()` under key-focus
/// contention in a shared test-runner window session -- have a chance to
/// land before assertions run. Fails loudly on timeout rather than letting
/// the caller's next assertion report a confusing, unrelated-looking value.
@MainActor
func Whistle_waitUntil(
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    if !condition() {
        XCTFail("condition was never met within \(timeout)s", file: file, line: line)
    }
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

    // MARK: Fix #4a: Clear empties transcript+notes+screenshot and mints a
    // fresh clientId, without needing to close the panel.

    @MainActor
    func testClearEmptiesAllFieldsAndMintsFreshClientId() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.transcriptText = "some transcript"
        viewModel.notesText = "some notes"
        viewModel.attachScreenshot(TestSupport.sampleScreenshot)
        let clientIdBeforeClear = viewModel.clientId

        viewModel.clear()

        XCTAssertEqual(viewModel.transcriptText, "")
        XCTAssertEqual(viewModel.notesText, "")
        XCTAssertNil(viewModel.screenshotData)
        XCTAssertFalse(viewModel.canSubmit)
        XCTAssertNotEqual(viewModel.clientId, clientIdBeforeClear, "Clear must mint a fresh clientId")
    }

    // MARK: Fix #4b/c: resumeDraft() restores an existing draft without
    // touching its content or re-fetching a screenshot.

    @MainActor
    func testResumeDraftPreservesExistingContentAndClientId() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        viewModel.transcriptText = "draft in progress"
        viewModel.notesText = "draft notes"
        viewModel.attachScreenshot(TestSupport.sampleScreenshot)
        let clientIdBeforeResume = viewModel.clientId

        viewModel.resumeDraft()

        XCTAssertEqual(viewModel.transcriptText, "draft in progress")
        XCTAssertEqual(viewModel.notesText, "draft notes")
        XCTAssertEqual(viewModel.screenshotData, TestSupport.sampleScreenshot)
        XCTAssertEqual(viewModel.clientId, clientIdBeforeResume, "resuming a draft must not mint a new clientId")
    }

    @MainActor
    func testResumeDraftBumpsFocusRequestTokenSoFocusReengages() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, _) = TestSupport.makeViewModel(store: store)
        viewModel.beginCapture()
        let tokenAfterOpen = viewModel.focusRequestToken

        viewModel.resumeDraft()

        XCTAssertGreaterThan(viewModel.focusRequestToken, tokenAfterOpen)
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

    // MARK: Fix #5: transcription must actually be gated on real speech
    // authorization, matching what onboarding's permission row displays --
    // even when mic access is granted, a denied/not-yet-granted speech
    // permission must not start transcription (silent type-only
    // degradation, same as mic-denied).

    @MainActor
    func testSpeechDeniedDoesNotStartTranscriptionEvenWhenMicAuthorized() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (viewModel, transcription) = TestSupport.makeViewModel(
            store: store,
            micAuthorized: true,
            speechAuthorized: false
        )
        viewModel.beginCapture()

        let expectation = expectation(description: "give async start() a chance to fire if it incorrectly does")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1)

        let startCount = await transcription.startCallCount
        XCTAssertEqual(startCount, 0, "transcription must not start when speech recognition isn't authorized")
        XCTAssertFalse(viewModel.isMicDenied, "mic itself is authorized -- only speech recognition is gating here")
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

    // MARK: Regression: pause then resume must never wipe the transcript
    // box (CRITICAL user-reported bug).
    //
    // Simulates the exact real-world sequence at the ViewModel/binding
    // level: a volatile hypothesis arrives, the user pauses (the segment
    // finalizes), the task cycles to a fresh segment on the same tap
    // (invisible at this layer), and a new volatile hypothesis arrives for
    // the resumed speech. At every step `transcriptText` must only grow --
    // never shrink, never reset to empty.

    @MainActor
    func testTranscriptSurvivesPauseThenResumeAcrossTaskRestartWithoutWiping() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manual = ManualTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { manual },
            micPermissionChecker: { true },
            speechPermissionChecker: { true }
        )
        viewModel.beginCapture()

        // 1. User starts speaking: a volatile hypothesis arrives.
        await manual.emit(TranscriptUpdate(committed: "", live: "Hello"))
        try await Self.waitUntil { viewModel.transcriptText == "Hello" }
        XCTAssertEqual(viewModel.transcriptText, "Hello")

        // 2. User pauses a beat: the segment finalizes (or, per the fixed
        // LegacySpeechTranscriber, an error mid-utterance folds the
        // volatile hypothesis into committed) -- either way the committed
        // text absorbs what was just said and live resets.
        await manual.emit(TranscriptUpdate(committed: "Hello", live: ""))
        try await Self.waitUntil { viewModel.transcriptText == "Hello" }
        XCTAssertEqual(viewModel.transcriptText, "Hello", "pausing must not wipe the box")

        // 3. Task restarts on the same running tap (invisible at this
        // layer) and the user resumes speaking: a fresh volatile hypothesis
        // for the new segment arrives, layered on top of the preserved
        // committed text.
        await manual.emit(TranscriptUpdate(committed: "Hello", live: "World"))
        try await Self.waitUntil { viewModel.transcriptText == "Hello World" }
        XCTAssertEqual(
            viewModel.transcriptText,
            "Hello World",
            "resuming after a pause must extend, not replace, the transcript"
        )

        viewModel.stopTranscription()
    }

    // MARK: Regression: manual edit mid-dictation is preserved -- dictation
    // appends to the edited text rather than rebuilding from scratch.

    @MainActor
    func testUserEditMidDictationIsPreservedAndDictationAppendsToIt() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manual = ManualTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { manual },
            micPermissionChecker: { true },
            speechPermissionChecker: { true }
        )
        viewModel.beginCapture()

        await manual.emit(TranscriptUpdate(committed: "", live: "Hello"))
        try await Self.waitUntil { viewModel.transcriptText == "Hello" }

        // User types more onto the end of the field while dictation is
        // still running.
        viewModel.transcriptText = "Hello there"

        // The next dictated update finalizes "Hello world" -- the "world"
        // is new material the service produced; it must be appended after
        // the user's own edit, not used to overwrite the field.
        await manual.emit(TranscriptUpdate(committed: "Hello world", live: ""))
        try await Self.waitUntil { viewModel.transcriptText == "Hello there world" }
        XCTAssertEqual(
            viewModel.transcriptText,
            "Hello there world",
            "dictation must append to a user's mid-dictation edit, not clobber it"
        )

        viewModel.stopTranscription()
    }

    private static func waitUntil(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        try await Whistle_waitUntil(timeout: timeout, file: file, line: line, condition)
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

            let controller = CapturePanelController(store: store, mode: mode)
            controller.trigger()
            // Poll rather than a fixed sleep: `.activating` mode's
            // NSApp.activate()/makeKeyAndOrderFront() can lag under
            // key-focus contention in a shared test-runner window session.
            try await Whistle_waitUntil { controller.isPanelOpen }
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
            let controller = CapturePanelController(store: store, screenshotService: screenshotService, mode: mode)

            controller.trigger()
            // Allow the async screenshot capture task to run.
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(counter.count, 1, "mode \(mode): first trigger should capture exactly one screenshot")

            controller.trigger()
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(counter.count, 1, "mode \(mode): duplicate trigger while open must not re-screenshot")
        }
    }

    // MARK: Fix #4b/c: dismissing (Esc / losing key) preserves the draft;
    // reopening restores it without retaking the screenshot.

    @MainActor
    func testDismissPreservesDraftAndReopenRestoresItWithoutNewScreenshot() async throws {
        for mode in [CapturePanelMode.nonActivating, CapturePanelMode.activating] {
            let (store, tempDir) = try makeStore()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let counter = CaptureCounter()
            let screenshotService = makeCountingScreenshotService(counter: counter)
            let controller = CapturePanelController(store: store, screenshotService: screenshotService, mode: mode)

            controller.trigger()
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(counter.count, 1, "mode \(mode): first trigger captures exactly one screenshot")

            controller.currentViewModel?.transcriptText = "unsent draft for \(mode)"
            controller.currentViewModel?.notesText = "draft notes for \(mode)"
            let clientIdBeforeDismiss = controller.currentViewModel?.clientId

            controller.dismissPreservingDraftForTesting()

            XCTAssertFalse(controller.isPanelOpen, "mode \(mode): dismiss must hide the panel")
            XCTAssertTrue(controller.hasPreservedDraft, "mode \(mode): dismiss must preserve the draft, not tear it down")

            controller.trigger()
            try await Whistle_waitUntil { controller.isPanelOpen }
            XCTAssertEqual(controller.currentViewModel?.transcriptText, "unsent draft for \(mode)")
            XCTAssertEqual(controller.currentViewModel?.notesText, "draft notes for \(mode)")
            XCTAssertEqual(
                controller.currentViewModel?.clientId,
                clientIdBeforeDismiss,
                "mode \(mode): reopening a preserved draft must not mint a new clientId"
            )
            XCTAssertEqual(counter.count, 1, "mode \(mode): reopening a preserved draft must not retake the screenshot")
        }
    }

    @MainActor
    func testEscOnEmptyPanelDismissesCleanly() async throws {
        let (store, tempDir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = CapturePanelController(store: store)
        controller.trigger()
        try await Whistle_waitUntil { controller.isPanelOpen }

        controller.dismissPreservingDraftForTesting()

        XCTAssertFalse(controller.isPanelOpen)
    }

    // MARK: Fix #4d (verify): Submit clears everything for the next capture
    // -- no preserved draft, and the next trigger takes a brand-new
    // screenshot.

    @MainActor
    func testSubmitClearsEverythingSoNextTriggerStartsFreshWithNewScreenshot() async throws {
        let (store, tempDir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try store.saveProjectsSnapshot([TestSupport.project1])

        let counter = CaptureCounter()
        let screenshotService = makeCountingScreenshotService(counter: counter)
        let controller = CapturePanelController(store: store, screenshotService: screenshotService)

        controller.trigger()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(counter.count, 1)

        controller.currentViewModel?.transcriptText = "first capture"
        controller.currentViewModel?.selectProject(TestSupport.project1.id)
        controller.submitCurrentForTesting()

        XCTAssertFalse(controller.isPanelOpen)
        XCTAssertFalse(controller.hasPreservedDraft, "submit must fully tear down, leaving nothing to resume")

        controller.trigger()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.currentViewModel?.transcriptText, "", "next capture after submit starts empty")
        XCTAssertEqual(counter.count, 2, "next capture after submit takes a brand-new screenshot")
    }
}

// MARK: - CapturePanelPositioning (plan U8 fix #2): pure math, no AppKit
// screen/panel objects needed.

final class CapturePanelPositioningTests: XCTestCase {
    func testCentersPanelHorizontallyBeneathStatusItemButton() {
        let statusItemButtonFrame = NSRect(x: 900, y: 1000, width: 24, height: 22)
        let panelSize = NSSize(width: 460, height: 360)
        let screenVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CapturePanelPositioning.origin(
            statusItemButtonFrame: statusItemButtonFrame,
            panelSize: panelSize,
            screenVisibleFrame: screenVisibleFrame
        )

        // Centered under the button's midX, directly below its bottom edge.
        XCTAssertEqual(origin.x, statusItemButtonFrame.midX - panelSize.width / 2)
        XCTAssertEqual(origin.y, statusItemButtonFrame.minY - panelSize.height - 8)
    }

    func testClampsToScreenLeftEdgeWhenStatusItemIsNearTheLeftCorner() {
        let statusItemButtonFrame = NSRect(x: 4, y: 1000, width: 24, height: 22)
        let panelSize = NSSize(width: 460, height: 360)
        let screenVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CapturePanelPositioning.origin(
            statusItemButtonFrame: statusItemButtonFrame,
            panelSize: panelSize,
            screenVisibleFrame: screenVisibleFrame
        )

        XCTAssertEqual(origin.x, screenVisibleFrame.minX + 8, "must clamp instead of running off the left edge")
    }

    func testClampsToScreenRightEdgeWhenStatusItemIsNearTheRightCorner() {
        let statusItemButtonFrame = NSRect(x: 1420, y: 1000, width: 24, height: 22)
        let panelSize = NSSize(width: 460, height: 360)
        let screenVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = CapturePanelPositioning.origin(
            statusItemButtonFrame: statusItemButtonFrame,
            panelSize: panelSize,
            screenVisibleFrame: screenVisibleFrame
        )

        XCTAssertEqual(
            origin.x,
            screenVisibleFrame.maxX - panelSize.width - 8,
            "must clamp instead of running off the right edge"
        )
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
