// CaptureViewModel.swift
// Orchestrates the capture panel's services (TECH-SPEC §4.1 `CaptureViewModel`
// row, plan U8): on open -> screenshot (already fired by
// `CapturePanelController` before the panel shows, per §4.2) + prewarmed
// `TranscriptionService.start()`; on submit -> build a `CaptureDraft`, hand
// it to `CaptureStore`, close the panel. No network on the submit path,
// ever -- `SyncEngine` drains the queue separately (plan U8 / TECH-SPEC
// §4.1 `SyncEngine` row).
//
// @MainActor per TECH-SPEC §4.1's concurrency map: UI controllers/view
// models carry a targeted @MainActor.

import AVFoundation
import Foundation
import os
import Speech
import WhistleCore

/// Unified-log destination for this file's diagnostics. NSLog content is
/// privacy-redacted to "<private>" in `log show` on modern macOS, which made
/// every message here unreadable in the field -- os.Logger with explicit
/// `privacy: .public` interpolations is the only way these stay legible.
private let captureLog = Logger(subsystem: "build.conductor.whistle.app", category: "transcription")

/// Optional pre-fill used by the "Duplicate as new capture" entry point
/// (TECH-SPEC §4.1 `HistoryWindow`/`CaptureViewModel` rows, wired fully by
/// U9): populates transcript/notes/screenshot from an existing capture and
/// requests the project picker be focused, while still minting a fresh
/// `clientId` for the new capture.
public struct CapturePreFill: Equatable, Sendable {
    public var transcript: String
    public var notes: String
    public var screenshotData: Data?
    public var focusProjectPicker: Bool

    public init(
        transcript: String,
        notes: String,
        screenshotData: Data? = nil,
        focusProjectPicker: Bool = true
    ) {
        self.transcript = transcript
        self.notes = notes
        self.screenshotData = screenshotData
        self.focusProjectPicker = focusProjectPicker
    }
}

/// Client-side auto-note injected when a capture is screenshot-only (plan
/// U8 edge scenario) -- recorded verbatim in `notes` so it's visible in
/// History later.
public enum CaptureAutoNote {
    public static let screenshotOnly = "screenshot-only capture"
}

/// Result of a submit attempt, communicated back to `CapturePanelController`
/// so it knows to close the panel.
public enum CaptureSubmitResult: Equatable {
    case submitted(clientId: String)
    /// Submit was attempted while disabled (all fields empty) -- should not
    /// happen if the UI respects `canSubmit`, but the view model still
    /// refuses defensively.
    case refusedEmpty
}

/// Actionable authentication state shown without discarding the capture.
public struct CaptureSubmissionAuthNotice: Equatable {
    public let message: String
    public let actionTitle: String
    public let isSigningIn: Bool
}

@MainActor
public final class CaptureViewModel: ObservableObject {
    // MARK: - Published UI state

    @Published public var transcriptText: String = ""
    @Published public var notesText: String = ""
    @Published public var screenshotData: Data?
    @Published public private(set) var isMicDenied: Bool = false
    /// Mirrors whether the transcription service is actually running --
    /// drives `FlapStatusView`'s mic-on indicator (capture-panel-redesign
    /// spec, "Manifest" V2: the flap is a mic-activity indicator, not a
    /// transcript readout). `true` once `startTranscriptionIfPermitted()`
    /// actually starts the service; `false` on `stopTranscription()` and
    /// when the update stream itself ends (service-side stop/error).
    @Published public private(set) var isListening: Bool = false
    /// Speech-recognition (SFSpeechRecognizer) authorization, tracked
    /// separately from `isMicDenied` (fix #1d) -- mic can be authorized
    /// while speech recognition alone is denied, which needs its own
    /// banner + System Settings deep link (Privacy_SpeechRecognition, not
    /// Privacy_Microphone).
    @Published public private(set) var isSpeechRecognitionDenied: Bool = false
    @Published public var selectedProjectId: String?
    @Published public private(set) var projects: [Project] = []
    @Published public var focusProjectPicker: Bool = false
    @Published public private(set) var submissionAuthNotice: CaptureSubmissionAuthNotice?

    /// Bumped every time the panel is shown -- fresh open, a resumed draft
    /// (fix #4b/c), or a refocus while already open -- so `CaptureView` can
    /// re-engage its `@FocusState` via `.onChange` even when SwiftUI's own
    /// `.onAppear` doesn't refire (it won't for a panel that's merely
    /// re-ordered front after being hidden, since the hosted view was never
    /// removed from the window's view hierarchy). Plan U8 fix #3: "keyboard
    /// focus must land in the main text box immediately... in BOTH panel
    /// modes."
    @Published public private(set) var focusRequestToken: Int = 0

    public func requestTranscriptFocus() {
        focusRequestToken += 1
    }

    /// Debug-log-friendly timestamp captured at `beginCapture()` entry, used
    /// by `CapturePanelController` to compute (and log) the
    /// trigger-to-interactive latency called out in TECH-SPEC §4.2. Manual
    /// QA reads this log; the timing itself is not asserted by automated
    /// tests (plan U8 verification note).
    public private(set) var captureBeganAt: Date?

    /// The `clientId` for the capture currently being composed. Freshly
    /// minted every time a new capture begins (including duplicate-as-new
    /// prefill), per plan U8's "freshly minted clientId" scenario.
    public private(set) var clientId: String = UUID().uuidString

    // MARK: - Dependencies

    private let store: CaptureStore
    private let screenshotService: ScreenshotService
    private let transcriptionServiceFactory: () -> any TranscriptionService
    /// Tri-state mic TCC status read (fix: reset-deadlock) -- distinct from
    /// `requestMicPermission` below so a status-only recheck (every panel
    /// open, `windowDidBecomeKey`) never itself prompts. `.notDetermined`
    /// must be told apart from `.denied`: only the latter is actionable via
    /// System Settings -- the former means the app hasn't asked yet, and
    /// doesn't even show up in Settings until it does.
    private let micPermissionStatus: () -> PermissionState
    /// Fires the real `AVCaptureDevice.requestAccess` TCC prompt -- called
    /// ONLY when `micPermissionStatus()` is `.notDetermined`, and only from
    /// `startTranscriptionIfPermitted()` at first real capture (never at
    /// launch/prewarm, per commit 5ff9c64's invariant). This is what
    /// actually registers the app in System Settings -> Privacy ->
    /// Microphone -- before any request, macOS won't list it there at all,
    /// which is what made the old "treat notDetermined as denied" bug an
    /// unrecoverable deadlock (banner says denied, but there's nothing to
    /// flip in Settings, because the app was never asked).
    private let requestMicPermission: () async -> Bool
    /// Real speech-recognition (SFSpeechRecognizer) TCC status, separate
    /// from `micPermissionStatus` -- fix #5: transcription must actually be
    /// gated on this, matching what the onboarding permission row displays,
    /// rather than blindly attempting recognition regardless of
    /// authorization (which would otherwise tight-loop retrying a task that
    /// immediately errors on every restart when speech isn't authorized).
    private let speechPermissionStatus: () -> PermissionState
    /// `SFSpeechRecognizer.requestAuthorization` counterpart to
    /// `requestMicPermission` -- same notDetermined-only, first-capture-only
    /// contract.
    private let requestSpeechPermission: () async -> Bool
    /// Fires whenever the panel opens (fix #2): lets the caller (wired by
    /// `CapturePanelController`/`WhistleApp` to `ProjectsSyncCoordinator.
    /// refreshIfStale()`) trigger a `conductor.refreshProjects` server call
    /// if the local `projects_snapshot` cache is stale (>1h) or missing,
    /// per TECH-SPEC §7. A plain synchronous closure -- `CaptureViewModel`
    /// itself never touches Convex/actors directly, matching the seam
    /// style of `micPermissionStatus`/`speechPermissionStatus` above.
    private let refreshProjectsIfStale: () -> Void
    private let defaultAgent: String
    private let defaultModel: String?

    private var transcriptionService: (any TranscriptionService)?
    private var transcriptionTask: Task<Void, Never>?
    private var projectsTask: Task<Void, Never>?
    /// Invalidates updates and completion callbacks from a stream that was
    /// stopped or superseded before they reach the main actor.
    private var transcriptionGeneration = 0
    /// Each screenshot request gets an identity so a late result from before
    /// Clear cannot repopulate the new capture with the old screenshot.
    private var screenshotRequestGeneration = 0
    /// Clear begins a new logical capture while leaving the panel open. Its
    /// screenshot must be taken after the user next hides and reopens the
    /// panel, so it captures the app they returned to rather than Whistle.
    private(set) var needsFreshScreenshotOnNextOpen = false

    /// The transcription service's own running display text as of the last
    /// update, kept separately from `transcriptText` (the transcript field
    /// is editable per PRD F1.3) so `applyTranscriptUpdate` can always
    /// compute what's *newly* dictated and append just that, whether or not
    /// the user has edited the field in the meantime -- the field must only
    /// ever grow, never shrink or get silently rebuilt from scratch.
    private var lastServiceText: String = ""

    public init(
        store: CaptureStore,
        screenshotService: ScreenshotService = ScreenshotService(),
        transcriptionServiceFactory: @escaping () -> any TranscriptionService = { TranscriptionServiceFactory.make() },
        micPermissionStatus: @escaping @MainActor () -> PermissionState = { MicPermission.status() },
        requestMicPermission: @escaping @MainActor () async -> Bool = { await MicPermission.request() },
        speechPermissionStatus: @escaping @MainActor () -> PermissionState = { SpeechRecognitionPermission.status() },
        requestSpeechPermission: @escaping @MainActor () async -> Bool = { await SpeechRecognitionPermission.request() },
        refreshProjectsIfStale: @escaping () -> Void = {},
        defaultAgent: String = "claude",
        defaultModel: String? = nil
    ) {
        self.store = store
        self.screenshotService = screenshotService
        self.transcriptionServiceFactory = transcriptionServiceFactory
        self.micPermissionStatus = micPermissionStatus
        self.requestMicPermission = requestMicPermission
        self.speechPermissionStatus = speechPermissionStatus
        self.requestSpeechPermission = requestSpeechPermission
        self.refreshProjectsIfStale = refreshProjectsIfStale
        self.defaultAgent = defaultAgent
        self.defaultModel = defaultModel
    }

    deinit {
        transcriptionTask?.cancel()
        projectsTask?.cancel()
    }

    // MARK: - Lifecycle: open

    /// Called once per panel-open (never on a duplicate-trigger-while-open,
    /// which instead just refocuses the existing panel -- plan U8: "hotkey
    /// while panel open -> focuses existing panel, no second screenshot").
    /// Screenshot capture itself happens in `CapturePanelController` BEFORE
    /// the panel is shown (TECH-SPEC §4.2 sequencing); this method receives
    /// the already-in-flight screenshot task's eventual result via
    /// `attachScreenshot(_:requestGeneration:)` rather than firing its own.
    public func beginCapture(preFill: CapturePreFill? = nil) {
        captureBeganAt = Date()
        clientId = UUID().uuidString
        transcriptText = preFill?.transcript ?? ""
        notesText = preFill?.notes ?? ""
        screenshotData = preFill?.screenshotData
        focusProjectPicker = preFill?.focusProjectPicker ?? false
        lastServiceText = ""
        // Fix #1b (fresh recheck) + reset-deadlock fix: `isMicDenied`/
        // `isSpeechRecognitionDenied` are (re)computed from the OS fresh
        // here, rather than trusting whatever they last held -- a grant
        // recovered via System Settings must be picked up without an app
        // relaunch. This happens inside `startTranscriptionIfPermitted()`
        // below, which also fires the actual TCC request when a status
        // comes back `.notDetermined` (first real capture only -- never at
        // launch/prewarm).
        loadProjects()
        // Fix #2: "on picker open" per TECH-SPEC §7 -- triggers
        // `conductor.refreshProjects` if the local snapshot is stale/
        // missing.
        refreshProjectsIfStale()
        startTranscriptionIfPermitted()
        requestTranscriptFocus()
    }

    /// Re-activates a preserved but unsent draft (plan U8 fix #4b/c): the
    /// panel was dismissed (Esc, or losing key/focus) while `transcriptText`/
    /// `notesText`/`screenshotData` held content, and is now reopening.
    /// Unlike `beginCapture`, this must NEVER reset those fields or
    /// `clientId` -- the whole point is that the draft survives until
    /// `clear()` or `submit()` -- and it never touches `screenshotData`, so
    /// the controller must not fire a new screenshot capture on this path
    /// either (fix #4c: "do NOT retake the screenshot over the draft's").
    /// Transcription itself does restart (it was stopped on dismiss);
    /// `lastServiceText` resets to `""` so the fresh transcription stream's
    /// output is appended after the existing draft text rather than
    /// replacing it, via the same reconciliation `applyTranscriptUpdate`
    /// already does for a mid-dictation manual edit.
    public func resumeDraft() {
        captureBeganAt = Date()
        lastServiceText = ""
        refreshProjectsIfStale()
        startTranscriptionIfPermitted()
        requestTranscriptFocus()
    }

    /// Re-checks mic + speech-recognition authorization fresh from the OS
    /// (fix #1b), independent of a full `beginCapture`/`resumeDraft`.
    /// Wired by `CapturePanelController.windowDidBecomeKey` so a
    /// permission grant recovered via System Settings is picked up the
    /// moment the panel's window regains key status, even on a path that
    /// doesn't go through `trigger()` at all. If a previously-denied
    /// permission is now granted and transcription isn't already running,
    /// starts it -- the user shouldn't have to dismiss/reopen the panel to
    /// benefit from a permission they just granted.
    public func refreshPermissions() {
        let wasMicDenied = isMicDenied
        let wasSpeechDenied = isSpeechRecognitionDenied
        // Status-only recheck (never requests) -- mirrors the denied-flag
        // half of `startTranscriptionIfPermitted()` below without touching
        // `transcriptionService`, so a plain window-key-regain recheck can
        // never itself spin up a second transcription task.
        syncDeniedFlags()

        let recovered = (wasMicDenied && !isMicDenied) || (wasSpeechDenied && !isSpeechRecognitionDenied)
        if recovered, transcriptionService == nil {
            startTranscriptionIfPermitted()
        }
    }

    /// "Clear" button (plan U8 fix #4a): empties transcript, notes, and
    /// screenshot, and mints a fresh `clientId` so a subsequent submit is
    /// recorded as a distinct capture. Transcription is restarted (rather
    /// than left running) because the service actor accumulates its own
    /// `committedTranscript` across the whole session and only resets that
    /// buffer in `start()` -- it is never told about `clear()`. Resetting
    /// only `lastServiceText` here would desync the view model from the
    /// service: the next update's `displayText` still carries the old,
    /// supposedly-cleared text (committed service-side), and
    /// `applyTranscriptUpdate`'s fast path (fired because `transcriptText`
    /// is now empty) adopts it wholesale -- the old text reappears, prefixed
    /// to the new speech. Stopping and restarting mints a fresh service
    /// instance whose buffers are empty in lockstep with the view model's,
    /// so the next update has nothing stale to reintroduce.
    public func clear() {
        transcriptText = ""
        notesText = ""
        screenshotData = nil
        screenshotRequestGeneration &+= 1
        needsFreshScreenshotOnNextOpen = true
        lastServiceText = ""
        clientId = UUID().uuidString
        stopTranscription()
        startTranscriptionIfPermitted()
    }

    /// Applies a resolved screenshot. Only reached via the generation-
    /// checked `attachScreenshot(_:requestGeneration:)` overload below --
    /// callers outside this file must go through that overload so a result
    /// superseded by `clear()` can never land here.
    func attachScreenshot(_ data: Data?) {
        guard let data else { return }
        screenshotData = data
    }

    /// Starts a screenshot request for the current capture. The controller
    /// calls this before it shows the panel, then returns the request token
    /// when the asynchronous capture finishes.
    func beginScreenshotRequest() -> Int {
        screenshotRequestGeneration &+= 1
        needsFreshScreenshotOnNextOpen = false
        return screenshotRequestGeneration
    }

    /// Ignores a screenshot that belongs to a capture superseded by Clear.
    func attachScreenshot(_ data: Data?, requestGeneration: Int) {
        guard requestGeneration == screenshotRequestGeneration else { return }
        attachScreenshot(data)
    }

    public func removeScreenshot() {
        screenshotData = nil
    }

    // MARK: - Transcription

    /// Re-reads both TCC statuses and updates the two `@Published` denied
    /// flags accordingly. Only `.denied`/`.restricted` renders as denied --
    /// the reset-deadlock fix: `.notDetermined` must NEVER show the
    /// actionable "denied -- enable in Settings" banner. There's nothing to
    /// flip in Settings yet at that point (the app isn't even listed there
    /// until it's actually requested access once), so treating
    /// notDetermined as denied is a dead end for the user -- the exact bug
    /// this fixes. Status-only: never itself prompts.
    @discardableResult
    private func syncDeniedFlags() -> (mic: PermissionState, speech: PermissionState) {
        let mic = micPermissionStatus()
        let speech = speechPermissionStatus()
        isMicDenied = mic == .denied
        isSpeechRecognitionDenied = speech == .denied
        return (mic, speech)
    }

    /// The three-way permission handling at the heart of the reset-deadlock
    /// fix. For each of mic/speech independently:
    ///   - `.denied`/`.restricted` -> `isMicDenied`/`isSpeechRecognitionDenied`
    ///     already set by `syncDeniedFlags()`; nothing more to do here.
    ///   - `.notDetermined` -> fire the real TCC request (this is what
    ///     registers the app in System Settings -> Privacy in the first
    ///     place). Granted -> starts transcription immediately, no relaunch
    ///     or reopen needed; denied -> falls to the denied-banner state.
    ///     While the request is in flight, neither denied flag is set (it's
    ///     pending, not denied), so the panel stays usable in type-only mode
    ///     without showing the "go to Settings" banner.
    ///   - `.granted` -> no request needed.
    /// Transcription only actually starts once BOTH mic and speech
    /// authorization resolve to granted (fix #5's existing gate).
    ///
    /// Only called from `beginCapture`/`resumeDraft` (fresh, real capture)
    /// and `refreshPermissions` (recovered-grant case) -- never at
    /// launch/prewarm (commit 5ff9c64's invariant: constructing a
    /// `CaptureViewModel` alone must never touch mic/speech permissions).
    private func startTranscriptionIfPermitted() {
        let (micStatus, speechStatus) = syncDeniedFlags()
        guard micStatus != .denied, speechStatus != .denied else { return }

        guard micStatus == .notDetermined || speechStatus == .notDetermined else {
            // Both already granted -- no request needed, start right away.
            beginRunningTranscription()
            return
        }

        // Capture the request closures locally rather than reading
        // `self.requestMicPermission`/`self.requestSpeechPermission` from
        // inside the unstructured `Task` below, matching this file's
        // existing weak-self + explicit `MainActor.run` hop style.
        let requestMic = requestMicPermission
        let requestSpeech = requestSpeechPermission

        Task { [weak self] in
            var micGranted = micStatus == .granted
            if micStatus == .notDetermined {
                let granted = await requestMic()
                micGranted = granted
                await MainActor.run { self?.isMicDenied = !granted }
            }

            var speechGranted = speechStatus == .granted
            if speechStatus == .notDetermined {
                let granted = await requestSpeech()
                speechGranted = granted
                await MainActor.run { self?.isSpeechRecognitionDenied = !granted }
            }

            guard micGranted, speechGranted else { return }
            await MainActor.run { self?.beginRunningTranscription() }
        }
    }

    /// Actually spins up the transcription service + its update-consuming
    /// task. Split out from `startTranscriptionIfPermitted()` so both the
    /// synchronous already-granted path and the async post-request path
    /// share one implementation.
    private func beginRunningTranscription() {
        // Double-start hardening: `startTranscriptionIfPermitted()` can be
        // in flight twice at once -- e.g. `clear()`'s restart racing a
        // mid-flight TCC permission request whose unstructured `Task` was
        // kicked off by an earlier `beginCapture()`/`resumeDraft()` and only
        // reaches here later. Without this guard, the earlier flow's
        // `Task` would still call `beginRunningTranscription()` after this
        // one already has, silently overwriting `transcriptionService` and
        // `transcriptionTask` -- the generation token bump below keeps that
        // orphaned stream's text from reaching the field, but nothing would
        // ever call `stop()` on its service, leaking a service whose audio
        // tap runs forever (mic indicator stays hot). Stopping first makes
        // any double-start self-healing: at most one service is ever live.
        if transcriptionService != nil {
            let supersededGeneration = transcriptionGeneration
            captureLog.notice("CaptureViewModel: beginRunningTranscription found a live service (gen \(supersededGeneration)) — stopping it first")
            stopTranscription()
        }

        let service = transcriptionServiceFactory()
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        transcriptionService = service
        isListening = true
        captureLog.notice("CaptureViewModel: starting transcription (gen \(generation))")
        transcriptionTask = Task { [weak self] in
            let stream = await service.start()
            for await update in stream {
                guard let self else { return }
                await MainActor.run {
                    guard self.transcriptionGeneration == generation else { return }
                    self.applyTranscriptUpdate(update)
                }
            }
            // Stream ended on its own (service-side stop/error) rather than
            // via `stopTranscription()` -- still clear the indicator so the
            // flap doesn't churn against a dead service.
            captureLog.notice("CaptureViewModel: transcription stream ended (gen \(generation))")
            await MainActor.run {
                guard self?.transcriptionGeneration == generation else { return }
                self?.isListening = false
            }
        }
    }

    /// Reconciles a fresh `TranscriptUpdate` against whatever's currently in
    /// the box. The field must only ever grow, never shrink or get wiped
    /// out from under the user (the "pause then resume wipes the box" bug
    /// this guards against) -- and a manual mid-dictation edit must never be
    /// clobbered by a later update.
    private func applyTranscriptUpdate(_ update: TranscriptUpdate) {
        let newServiceText = update.displayText

        // Defensive, and deliberately not covered by a unit test: a blank
        // update never improves on text already on screen, so drop it rather
        // than letting the fast path below adopt it and momentarily clear the
        // box. Neither shipping transcriber emits a blank update after having
        // produced text (both fold `live` into `committed` instead), and the
        // effect is a single-frame flicker that converges on the next update
        // -- so no final-state assertion can observe it. The guard is here
        // because new transcribers are coming (SpeechAnalyzer has never run
        // against the real API; a third-party engine may follow) and a
        // flash-cleared transcript box is the one failure this screen must
        // never show again.
        //
        // Placed *before* the `defer` below on purpose: `lastServiceText`
        // must keep pointing at the last text the service really produced.
        // Letting it fall to "" would leave the next genuine update nothing
        // to diff against, and `appendDictated` would then append a whole
        // utterance on top of the field.
        guard !newServiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptText.isEmpty else { return }

        defer { lastServiceText = newServiceText }

        if transcriptText.isEmpty || transcriptText == lastServiceText {
            // Common case: no user edits since the last update, so the
            // service is authoritative -- adopt its text wholesale.
            //
            // This deliberately does NOT require `newServiceText` to be a
            // prefix-extension of `lastServiceText`. Recognizer hypotheses
            // are not monotonic: both SFSpeechRecognizer and
            // SpeechAnalyzer revise earlier words as later context arrives
            // ("sink engine" -> "sync engine"). Requiring a clean extension
            // here sent every such revision down the `appendDictated` path,
            // which -- having no prefix to strip -- appended the entire
            // utterance a second time. That is what produced the
            // user-reported "garbles and repeats itself" transcript.
            transcriptText = newServiceText
            return
        }

        // The user has diverged from the dictated text (a manual edit
        // mid-dictation). Never rebuild the field from scratch: append only
        // the newly-dictated material onto whatever is already on screen, so
        // dictation extends the user's edits instead of overwriting them.
        appendDictated(newServiceText)
    }

    /// Appends the portion of `newServiceText` that's new since
    /// `lastServiceText` onto `transcriptText`, rather than replacing the
    /// field outright.
    ///
    /// Reached only when the user has diverged from the dictated text, so the
    /// field cannot be rebuilt from the service's version -- the user's own
    /// words would be lost. The new material is therefore identified by
    /// diffing against `lastServiceText` rather than by replacement.
    private func appendDictated(_ newServiceText: String) {
        let keep = Self.commonWordPrefixCount(newServiceText, lastServiceText)
        let addition = String(newServiceText.dropFirst(keep))
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddition.isEmpty else { return }

        if transcriptText.isEmpty || transcriptText.hasSuffix(" ") {
            transcriptText += trimmedAddition
        } else {
            transcriptText += " " + trimmedAddition
        }
    }

    /// How many leading characters of `newText` are already accounted for by
    /// `previousText`, cut only on a word boundary.
    ///
    /// When `newText` cleanly extends `previousText` this is just
    /// `previousText.count` -- the ordinary streaming case. When the service
    /// *revised* a word instead ("...the sink engine" -> "...the sync
    /// engine") the two diverge mid-word, and a raw character-level common
    /// prefix would splice a word fragment onto the field ("...the sink
    /// engine ync engine"). Backing off to the last whitespace keeps the
    /// appended material whole words, so the worst case is a duplicated tail
    /// rather than a duplicated utterance or a mangled one.
    private static func commonWordPrefixCount(_ newText: String, _ previousText: String) -> Int {
        let common = newText.commonPrefix(with: previousText)
        // One string is a prefix of the other: nothing was revised, so the
        // whole common run is safe to skip.
        if common.count == newText.count {
            return common.count
        }
        if common.count == previousText.count {
            let next = newText.index(newText.startIndex, offsetBy: common.count)
            if common.last?.isWhitespace == true || newText[next].isWhitespace {
                return common.count
            }
        }
        guard let lastBoundary = common.lastIndex(where: { $0.isWhitespace }) else {
            // Diverged inside the very first word -- keep nothing.
            return 0
        }
        return common.distance(from: common.startIndex, to: lastBoundary) + 1
    }

    /// Stops the transcription service (e.g. panel closing). Safe to call
    /// multiple times.
    public func stopTranscription() {
        transcriptionGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        let service = transcriptionService
        transcriptionService = nil
        isListening = false
        if let service {
            let newGeneration = transcriptionGeneration
            captureLog.notice("CaptureViewModel: stopTranscription (now gen \(newGeneration)) — stopping service")
            Task { await service.stop() }
        }
    }

    // MARK: - Projects

    private func loadProjects() {
        applyProjectsUpdate((try? store.projectsSnapshot()) ?? [])

        projectsTask?.cancel()
        projectsTask = Task { [weak self] in
            guard let self else { return }
            for await updated in self.store.projectsUpdates() {
                await MainActor.run {
                    self.applyProjectsUpdate(updated)
                }
            }
        }
    }

    /// Applies a fresh projects list (initial snapshot read or a later
    /// `projectsUpdates()` yield -- e.g. the app-wide `ProjectsSyncCoordinator`
    /// persisting a `projects.list` subscription result into `CaptureStore`
    /// for the first time after the picker opened with an empty/stale
    /// snapshot, fix #2) and ensures a selection exists once projects do:
    /// keeps the current selection if it's still valid, otherwise prefers
    /// the last-used project, falling back to the first.
    private func applyProjectsUpdate(_ updated: [Project]) {
        projects = updated
        guard selectedProjectId == nil || !updated.contains(where: { $0.id == selectedProjectId }) else { return }
        if let lastUsed = try? store.lastUsedProjectId(), updated.contains(where: { $0.id == lastUsed }) {
            selectedProjectId = lastUsed
        } else {
            selectedProjectId = updated.first?.id
        }
    }

    /// Called by the UI whenever the user changes the project picker
    /// selection -- persists immediately so it's the new "last used" value
    /// (plan U8: "selection updates app_state").
    public func selectProject(_ projectId: String) {
        selectedProjectId = projectId
        try? store.setLastUsedProjectId(projectId)
    }

    // MARK: - Submit gating

    /// Submit is disabled when transcript, notes, and screenshot are all
    /// empty (plan U8 edge scenario); screenshot-only is allowed.
    public var canSubmit: Bool {
        !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || screenshotData != nil
    }

    public var hasContent: Bool {
        !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || screenshotData != nil
    }

    /// Authentication failures retain the draft; the user explicitly submits
    /// again once sign-in succeeds.
    public func updateSubmissionAuthState(_ state: AuthState, errorMessage: String? = nil) {
        switch state {
        case .signedIn:
            submissionAuthNotice = nil
        case .signingIn:
            submissionAuthNotice = .init(message: "Signing in… your capture is still here.", actionTitle: "Signing In…", isSigningIn: true)
        case .reauthRequired:
            submissionAuthNotice = .init(message: errorMessage ?? "Your session expired. Sign in again to send this capture.", actionTitle: "Sign In Again", isSigningIn: false)
        case .signedOut:
            submissionAuthNotice = .init(message: errorMessage ?? "Sign in to send this capture.", actionTitle: "Sign In", isSigningIn: false)
        }
    }

    // MARK: - Submit

    /// Builds and queues a `CaptureDraft`, never touching the network
    /// (TECH-SPEC F2.1 / plan U8: "NO network on the submit path, ever").
    /// Returns `.refusedEmpty` (and queues nothing) if called while
    /// `canSubmit` is false.
    @discardableResult
    public func submit() -> CaptureSubmitResult {
        guard canSubmit else { return .refusedEmpty }

        var finalNotes = notesText
        let isScreenshotOnly = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && screenshotData != nil
        if isScreenshotOnly {
            finalNotes = CaptureAutoNote.screenshotOnly
        }

        var screenshotPath: String?
        if let screenshotData {
            screenshotPath = try? store.writeScreenshot(screenshotData, clientId: clientId)
        }

        guard let projectId = selectedProjectId,
              let project = projects.first(where: { $0.id == projectId }) else {
            // No project available at all (e.g. projects haven't loaded
            // yet / offline with an empty snapshot) -- still queue with an
            // empty projectId rather than silently dropping the capture;
            // SyncEngine/UI upstream is responsible for requiring a
            // project selection before this is reachable in the real UI
            // (ProjectPicker always has a selection once any project
            // exists). This keeps submit()'s network-free contract intact
            // even in that degraded case.
            let draft = CaptureDraft(
                clientId: clientId,
                transcript: transcriptText,
                notes: finalNotes,
                screenshotPath: screenshotPath,
                projectId: selectedProjectId ?? "",
                projectName: "",
                agent: defaultAgent,
                model: defaultModel,
                localState: .queued
            )
            try? store.saveDraft(draft)
            return .submitted(clientId: clientId)
        }

        try? store.setLastUsedProjectId(project.id)

        let draft = CaptureDraft(
            clientId: clientId,
            transcript: transcriptText,
            notes: finalNotes,
            screenshotPath: screenshotPath,
            projectId: project.id,
            projectName: project.name,
            agent: defaultAgent,
            model: defaultModel,
            localState: .queued
        )
        try? store.saveDraft(draft)

        return .submitted(clientId: clientId)
    }
}

// MARK: - Mic permission seam

/// Seam over `AVCaptureDevice.authorizationStatus(for: .audio)` /
/// `AVCaptureDevice.requestAccess(for: .audio)` so tests can simulate any
/// mic TCC host -- including the `.notDetermined -> request -> granted/
/// denied` transition (the reset-deadlock fix) -- without touching real TCC
/// state.
///
/// Previously this only exposed a status-only `isAuthorized() -> Bool`
/// check, on the theory that requesting was an onboarding-only concern.
/// That over-corrected: after `tccutil reset Microphone` (or on a fresh
/// install), `authorizationStatus(for: .audio)` comes back
/// `.notDetermined`, and treating "not authorized" as "denied" everywhere
/// meant capture's actionable-denied banner fired for a permission that was
/// never actually asked for -- and since `requestAccess` was never called
/// from the capture path either, the app never appeared in System Settings
/// -> Privacy & Security -> Microphone at all (apps only list there after
/// their first request). Banner says denied, Settings has nothing to flip,
/// app never asks: a genuine deadlock. `request()` below is the fix --
/// called from `CaptureViewModel.startTranscriptionIfPermitted()` only at
/// first real capture (never at launch/prewarm).
public enum MicPermission {
    /// Tri-state status read (`PermissionState`, shared with
    /// `PermissionStep.swift`'s onboarding row) -- never itself prompts.
    public static func status() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Fires the real system TCC prompt (only meaningful when `status()`
    /// is `.notDetermined`) -- this is what actually registers the app in
    /// System Settings -> Privacy & Security -> Microphone.
    public static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: - Speech recognition permission seam

/// Seam over `SFSpeechRecognizer.authorizationStatus()` / `.requestAuthorization`
/// (fix #5) -- the same real status `PermissionStep.swift`'s onboarding row
/// displays, so transcription's gating and the onboarding display can never
/// disagree. Same reset-deadlock class of bug as `MicPermission` (speech
/// recognition needs its own TCC grant, and also only appears in Settings
/// once requested), and the same fix: `request()` is called from
/// `CaptureViewModel` only when `status()` is `.notDetermined`, only at
/// first real capture.
public enum SpeechRecognitionPermission {
    /// Tri-state status read -- never itself prompts.
    public static func status() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Fires the real system TCC prompt (only meaningful when `status()`
    /// is `.notDetermined`) -- this is what actually registers the app in
    /// System Settings -> Privacy & Security -> Speech Recognition.
    public static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
