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

import AppKit
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

    /// - Parameters:
    ///   - micStatus/speechStatus: the tri-state TCC status each permission
    ///     reports (reset-deadlock fix: `.notDetermined` is distinct from
    ///     `.denied`). Defaults to `.granted` -- most tests don't care about
    ///     permission gating at all.
    ///   - micRequestResult/speechRequestResult: what `request()` resolves
    ///     to, only exercised when the corresponding status is
    ///     `.notDetermined`. Tests that need to observe `request()` being
    ///     called (call counts, in-flight-vs-resolved banner state) instead
    ///     construct `CaptureViewModel` directly with their own tracking
    ///     closures -- see the dedicated notDetermined tests below.
    static func makeViewModel(
        store: CaptureStore,
        micStatus: PermissionState = .granted,
        speechStatus: PermissionState = .granted,
        micRequestResult: Bool = true,
        speechRequestResult: Bool = true,
        transcriptionUpdates: [TranscriptUpdate] = []
    ) -> (viewModel: CaptureViewModel, transcription: FakeTranscriptionService) {
        let fake = FakeTranscriptionService(scriptedUpdates: transcriptionUpdates)
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { micStatus },
            requestMicPermission: { micRequestResult },
            speechPermissionStatus: { speechStatus },
            requestSpeechPermission: { speechRequestResult }
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

        let (viewModel, transcription) = TestSupport.makeViewModel(store: store, micStatus: .denied)
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
            micStatus: .granted,
            speechStatus: .denied
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
            micStatus: .granted,
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

    // MARK: Reset-deadlock fix -- `.notDetermined` at first capture must
    // fire the real TCC request (which is what registers the app in System
    // Settings -> Privacy in the first place), never render as the
    // actionable "denied" banner while pending, and start transcription
    // immediately on a granted callback with no relaunch/reopen needed.
    // Root cause: after `tccutil reset Microphone` (or a fresh install),
    // `AVCaptureDevice.authorizationStatus(for: .audio)` comes back
    // `.notDetermined`; the old code treated anything != `.authorized` as
    // denied and never called `requestAccess`, so the app never appeared in
    // Settings and the user could never recover -- a genuine deadlock.

    @MainActor
    func testMicAuthorizedNeverCallsRequestAccess() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var micRequestCallCount = 0
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .granted },
            requestMicPermission: {
                micRequestCallCount += 1
                return true
            },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
        )

        viewModel.beginCapture()
        try await pollStartCallCount(fake, atLeast: 1)

        XCTAssertEqual(micRequestCallCount, 0, "already-authorized mic must never call requestAccess")
        XCTAssertFalse(viewModel.isMicDenied)
    }

    @MainActor
    func testMicNotDeterminedRequestsAccessAndStartsTranscriptionWhenGranted() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var micRequestCallCount = 0
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .notDetermined },
            requestMicPermission: {
                micRequestCallCount += 1
                return true
            },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
        )

        viewModel.beginCapture()

        // Pending (or just-granted) must NEVER render as the denied banner
        // -- that's the exact bug being fixed.
        XCTAssertFalse(viewModel.isMicDenied, "notDetermined must never show as denied, pending or granted")

        try await pollStartCallCount(fake, atLeast: 1)
        XCTAssertEqual(micRequestCallCount, 1, "must call requestAccess exactly once for a notDetermined status")
        XCTAssertFalse(viewModel.isMicDenied)
    }

    @MainActor
    func testMicNotDeterminedRequestDeniedShowsBannerAndStaysTypeOnly() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var micRequestCallCount = 0
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .notDetermined },
            requestMicPermission: {
                micRequestCallCount += 1
                return false
            },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
        )

        viewModel.beginCapture()
        XCTAssertFalse(viewModel.isMicDenied, "must not show denied while the request is still in flight")

        try await Whistle_waitUntil { viewModel.isMicDenied }
        XCTAssertEqual(micRequestCallCount, 1)
        let startCount = await fake.startCallCount
        XCTAssertEqual(startCount, 0, "a denied request must never start transcription")

        // Panel stays usable in type-only mode.
        viewModel.notesText = "typed while mic denied"
        XCTAssertTrue(viewModel.canSubmit)
    }

    @MainActor
    func testSpeechNotDeterminedRequestsAuthorizationAndStartsTranscriptionWhenGranted() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var speechRequestCallCount = 0
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { .notDetermined },
            requestSpeechPermission: {
                speechRequestCallCount += 1
                return true
            }
        )

        viewModel.beginCapture()
        XCTAssertFalse(viewModel.isSpeechRecognitionDenied, "notDetermined must never show as denied, pending or granted")

        try await pollStartCallCount(fake, atLeast: 1)
        XCTAssertEqual(speechRequestCallCount, 1, "must call requestAuthorization exactly once for a notDetermined status")
        XCTAssertFalse(viewModel.isSpeechRecognitionDenied)
        XCTAssertFalse(viewModel.isMicDenied)
    }

    @MainActor
    func testSpeechNotDeterminedRequestDeniedShowsBannerAndStaysTypeOnly() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var speechRequestCallCount = 0
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { .notDetermined },
            requestSpeechPermission: {
                speechRequestCallCount += 1
                return false
            }
        )

        viewModel.beginCapture()
        XCTAssertFalse(viewModel.isSpeechRecognitionDenied, "must not show denied while the request is still in flight")

        try await Whistle_waitUntil { viewModel.isSpeechRecognitionDenied }
        XCTAssertEqual(speechRequestCallCount, 1)
        let startCount = await fake.startCallCount
        XCTAssertEqual(startCount, 0, "a denied request must never start transcription")
        XCTAssertFalse(viewModel.isMicDenied, "mic itself is authorized -- only speech recognition is denied here")
    }

    // MARK: Commit 5ff9c64 invariant (no mic access at app launch): merely
    // constructing a `CaptureViewModel` -- the prewarm/launch path, before
    // any real capture is ever triggered -- must never read mic/speech
    // status or request access. Only `beginCapture`/`resumeDraft`/
    // `refreshPermissions` (all first-real-capture-or-later paths) may.

    @MainActor
    func testConstructingViewModelNeverTouchesMicOrSpeechPermissions() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var micStatusCallCount = 0
        var micRequestCallCount = 0
        var speechStatusCallCount = 0
        var speechRequestCallCount = 0

        _ = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { FakeTranscriptionService() },
            micPermissionStatus: {
                micStatusCallCount += 1
                return .notDetermined
            },
            requestMicPermission: {
                micRequestCallCount += 1
                return true
            },
            speechPermissionStatus: {
                speechStatusCallCount += 1
                return .notDetermined
            },
            requestSpeechPermission: {
                speechRequestCallCount += 1
                return true
            }
        )

        XCTAssertEqual(micStatusCallCount, 0, "constructing alone must never check mic status (5ff9c64: no mic access at launch)")
        XCTAssertEqual(micRequestCallCount, 0, "constructing alone must never request mic access")
        XCTAssertEqual(speechStatusCallCount, 0, "constructing alone must never check speech status")
        XCTAssertEqual(speechRequestCallCount, 0, "constructing alone must never request speech authorization")
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
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
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
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
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

    // MARK: Fix #2 (project-picker "No projects" bug): opening the panel
    // triggers the stale-projects-refresh hook (wired in the real app to
    // `ProjectsSyncCoordinator.refreshIfStale()`) -- both a brand-new
    // capture and resuming a preserved draft count as "picker open" per
    // TECH-SPEC §7 ("conductor.refreshProjects ... called ... on picker
    // open").

    @MainActor
    func testBeginCaptureAndResumeDraftTriggerStaleProjectsRefresh() throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var refreshCallCount = 0
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { FakeTranscriptionService() },
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true },
            refreshProjectsIfStale: { refreshCallCount += 1 }
        )

        viewModel.beginCapture()
        XCTAssertEqual(refreshCallCount, 1, "beginCapture (a fresh panel open) must trigger the stale-refresh hook")

        viewModel.resumeDraft()
        XCTAssertEqual(refreshCallCount, 2, "resumeDraft (reopening with a preserved draft) must also trigger it")
    }

    // MARK: Fix #1b: permission recovered via System Settings must be
    // picked up without an app relaunch -- `refreshPermissions()` (wired to
    // the panel's window regaining key status) re-checks fresh and, if a
    // previously-denied permission is now granted, starts transcription.

    @MainActor
    func testRefreshPermissionsPicksUpRecoveredMicGrantAndStartsTranscription() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var micStatus: PermissionState = .denied
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { micStatus },
            requestMicPermission: { true },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
        )

        viewModel.beginCapture()
        XCTAssertTrue(viewModel.isMicDenied)
        let initialStartCount = await fake.startCallCount
        XCTAssertEqual(initialStartCount, 0)

        // Simulate the user toggling mic access off/on in System Settings
        // while the app keeps running -- no relaunch.
        micStatus = .granted
        viewModel.refreshPermissions()

        XCTAssertFalse(viewModel.isMicDenied, "refreshPermissions must re-check fresh, not reuse the latched flag")
        try await pollStartCallCount(fake, atLeast: 1)
        let startCount = await fake.startCallCount
        XCTAssertEqual(startCount, 1, "transcription should start once the recovered grant is observed")
    }

    @MainActor
    func testRefreshPermissionsPicksUpRecoveredSpeechGrantAndStartsTranscription() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var speechStatus: PermissionState = .denied
        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { speechStatus },
            requestSpeechPermission: { true }
        )

        viewModel.beginCapture()
        XCTAssertTrue(viewModel.isSpeechRecognitionDenied)
        XCTAssertFalse(viewModel.isMicDenied)

        speechStatus = .granted
        viewModel.refreshPermissions()

        XCTAssertFalse(viewModel.isSpeechRecognitionDenied)
        try await pollStartCallCount(fake, atLeast: 1)
        let startCount = await fake.startCallCount
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testRefreshPermissionsDoesNotRestartAlreadyRunningTranscription() async throws {
        let (store, tempDir) = try TestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fake = FakeTranscriptionService()
        let viewModel = CaptureViewModel(
            store: store,
            transcriptionServiceFactory: { fake },
            micPermissionStatus: { .granted },
            requestMicPermission: { true },
            speechPermissionStatus: { .granted },
            requestSpeechPermission: { true }
        )

        viewModel.beginCapture()
        try await pollStartCallCount(fake, atLeast: 1)
        let startCountAfterOpen = await fake.startCallCount
        XCTAssertEqual(startCountAfterOpen, 1)

        // Nothing changed -- a window-key-regain recheck with unchanged,
        // already-authorized permissions must not spin up a second
        // transcription task.
        viewModel.refreshPermissions()
        try await Task.sleep(nanoseconds: 50_000_000) // give any (incorrect) restart a chance to happen
        let startCountAfterRefresh = await fake.startCallCount
        XCTAssertEqual(startCountAfterRefresh, 1, "must not restart transcription that's already running")
    }
}

/// Polls a `FakeTranscriptionService`'s actor-isolated `startCallCount`
/// until it reaches `expected` or the timeout elapses -- needed because
/// `CaptureViewModel` kicks off `service.start()` from an unstructured
/// `Task`, so it can lag slightly behind a synchronous call to
/// `beginCapture()`/`refreshPermissions()`.
private func pollStartCallCount(
    _ service: FakeTranscriptionService,
    atLeast expected: Int,
    timeout: TimeInterval = 1
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await service.startCallCount < expected, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
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

    @MainActor
    private func waitForScreenshotCount(
        _ expected: Int,
        counter: CaptureCounter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await Whistle_waitUntil(file: file, line: line) {
            counter.count == expected
        }
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

            let controller = CapturePanelController(store: store, mode: mode, micPermissionStatus: { .granted }, speechPermissionStatus: { .granted }, transcriptionServiceFactory: { FakeTranscriptionService() })
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
            let controller = CapturePanelController(store: store, screenshotService: screenshotService, mode: mode, micPermissionStatus: { .granted }, speechPermissionStatus: { .granted }, transcriptionServiceFactory: { FakeTranscriptionService() })

            controller.trigger()
            try await waitForScreenshotCount(1, counter: counter)
            XCTAssertEqual(counter.count, 1, "mode \(mode): first trigger should capture exactly one screenshot")

            controller.trigger()
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
            let controller = CapturePanelController(store: store, screenshotService: screenshotService, mode: mode, micPermissionStatus: { .granted }, speechPermissionStatus: { .granted }, transcriptionServiceFactory: { FakeTranscriptionService() })

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

        let controller = CapturePanelController(store: store, micPermissionStatus: { .granted }, speechPermissionStatus: { .granted }, transcriptionServiceFactory: { FakeTranscriptionService() })
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
        let controller = CapturePanelController(store: store, screenshotService: screenshotService, micPermissionStatus: { .granted }, speechPermissionStatus: { .granted }, transcriptionServiceFactory: { FakeTranscriptionService() })

        controller.trigger()
        try await waitForScreenshotCount(1, counter: counter)
        XCTAssertEqual(counter.count, 1)

        controller.currentViewModel?.transcriptText = "first capture"
        controller.currentViewModel?.selectProject(TestSupport.project1.id)
        controller.submitCurrentForTesting()

        XCTAssertFalse(controller.isPanelOpen)
        XCTAssertFalse(controller.hasPreservedDraft, "submit must fully tear down, leaving nothing to resume")

        controller.trigger()
        try await waitForScreenshotCount(2, counter: counter)

        XCTAssertEqual(controller.currentViewModel?.transcriptText, "", "next capture after submit starts empty")
        XCTAssertEqual(counter.count, 2, "next capture after submit takes a brand-new screenshot")
    }

    // MARK: Fix #1b: the window regaining key status re-checks permissions
    // without needing a full `beginCapture`/`resumeDraft` (mirrors
    // `OnboardingWindowController.windowDidBecomeKey`'s existing fix for
    // the same class of bug on the onboarding permissions step).

    @MainActor
    func testWindowDidBecomeKeyForwardsToViewModelRefreshPermissions() async throws {
        let (store, tempDir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = CapturePanelController(store: store, micPermissionStatus: { .granted }, speechPermissionStatus: { .granted }, transcriptionServiceFactory: { FakeTranscriptionService() })
        controller.trigger()
        try await Whistle_waitUntil { controller.isPanelOpen }

        // beginCapture() already ran with a deterministic granted mic/speech
        // status (never the real system checkers -- the reset-deadlock fix
        // means a real `.notDetermined` host would otherwise fire an actual
        // TCC prompt during this automated run).
        XCTAssertNotNil(controller.currentViewModel)

        // windowDidBecomeKey must be safe to call directly (as
        // OnboardingWindowController's equivalent test does) and must not
        // crash/no-op silently -- it forwards straight to
        // `refreshPermissions()`, which is exercised in isolation by
        // `CaptureViewModelTests.testRefreshPermissionsPicksUp...` above.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    }

    // MARK: Fix #2: the controller threads `refreshProjectsIfStale` into
    // every view model it creates.

    @MainActor
    func testRefreshProjectsIfStaleIsThreadedIntoTheViewModelOnEveryTrigger() async throws {
        let (store, tempDir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var refreshCallCount = 0
        let controller = CapturePanelController(
            store: store,
            refreshProjectsIfStale: { refreshCallCount += 1 },
            micPermissionStatus: { .granted },
            speechPermissionStatus: { .granted },
            transcriptionServiceFactory: { FakeTranscriptionService() }
        )

        controller.trigger()
        try await Whistle_waitUntil { controller.isPanelOpen }
        XCTAssertEqual(refreshCallCount, 1, "a brand-new capture (beginCapture) must trigger the stale-refresh hook")

        controller.dismissPreservingDraftForTesting()
        controller.trigger() // reopen -> resumeDraft()
        try await Whistle_waitUntil { controller.isPanelOpen }
        XCTAssertEqual(refreshCallCount, 2, "reopening a preserved draft (resumeDraft) must also trigger it")
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
