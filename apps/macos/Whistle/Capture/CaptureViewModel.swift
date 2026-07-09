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
import Speech
import WhistleCore

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
    private let micPermissionChecker: () -> Bool
    /// Real speech-recognition (SFSpeechRecognizer) TCC authorization,
    /// separate from `micPermissionChecker` -- fix #5: transcription must
    /// actually be gated on this, matching what the onboarding permission
    /// row displays, rather than blindly attempting recognition regardless
    /// of authorization (which would otherwise tight-loop retrying a task
    /// that immediately errors on every restart when speech isn't
    /// authorized).
    private let speechPermissionChecker: () -> Bool
    /// Fires whenever the panel opens (fix #2): lets the caller (wired by
    /// `CapturePanelController`/`WhistleApp` to `ProjectsSyncCoordinator.
    /// refreshIfStale()`) trigger a `conductor.refreshProjects` server call
    /// if the local `projects_snapshot` cache is stale (>1h) or missing,
    /// per TECH-SPEC §7. A plain synchronous closure -- `CaptureViewModel`
    /// itself never touches Convex/actors directly, matching the seam
    /// style of `micPermissionChecker`/`speechPermissionChecker` above.
    private let refreshProjectsIfStale: () -> Void
    private let defaultAgent: String
    private let defaultModel: String?

    private var transcriptionService: (any TranscriptionService)?
    private var transcriptionTask: Task<Void, Never>?
    private var projectsTask: Task<Void, Never>?

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
        micPermissionChecker: @escaping () -> Bool = { MicPermission.isAuthorized() },
        speechPermissionChecker: @escaping () -> Bool = { SpeechRecognitionPermission.isAuthorized() },
        refreshProjectsIfStale: @escaping () -> Void = {},
        defaultAgent: String = "claude",
        defaultModel: String? = nil
    ) {
        self.store = store
        self.screenshotService = screenshotService
        self.transcriptionServiceFactory = transcriptionServiceFactory
        self.micPermissionChecker = micPermissionChecker
        self.speechPermissionChecker = speechPermissionChecker
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
    /// `attachScreenshot(_:)` rather than firing its own.
    public func beginCapture(preFill: CapturePreFill? = nil) {
        captureBeganAt = Date()
        clientId = UUID().uuidString
        transcriptText = preFill?.transcript ?? ""
        notesText = preFill?.notes ?? ""
        screenshotData = preFill?.screenshotData
        focusProjectPicker = preFill?.focusProjectPicker ?? false
        lastServiceText = ""
        // Fix #1b: re-check both permissions fresh from the OS on every
        // open rather than trusting whatever `isMicDenied`/
        // `isSpeechRecognitionDenied` last held -- a grant recovered via
        // System Settings (e.g. toggling mic access off/on to force a
        // fresh TCC grant tied to the current build's signature) must be
        // picked up without an app relaunch.
        isMicDenied = !micPermissionChecker()
        isSpeechRecognitionDenied = !speechPermissionChecker()

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
        isMicDenied = !micPermissionChecker()
        isSpeechRecognitionDenied = !speechPermissionChecker()
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
        isMicDenied = !micPermissionChecker()
        isSpeechRecognitionDenied = !speechPermissionChecker()

        let recovered = (wasMicDenied && !isMicDenied) || (wasSpeechDenied && !isSpeechRecognitionDenied)
        if recovered, transcriptionService == nil {
            startTranscriptionIfPermitted()
        }
    }

    /// "Clear" button (plan U8 fix #4a): empties transcript, notes, and
    /// screenshot, and mints a fresh `clientId` so a subsequent submit is
    /// recorded as a distinct capture. The panel stays open and
    /// transcription keeps running -- `lastServiceText` resets so dictation
    /// after a clear starts fresh instead of trying to diff against the
    /// discarded text.
    public func clear() {
        transcriptText = ""
        notesText = ""
        screenshotData = nil
        lastServiceText = ""
        clientId = UUID().uuidString
    }

    /// Called by `CapturePanelController` when the pre-panel screenshot
    /// (fired before `beginCapture`, per §4.2) resolves. Never invoked
    /// again for the same open (no re-screenshot on duplicate trigger).
    public func attachScreenshot(_ data: Data?) {
        guard let data else { return }
        screenshotData = data
    }

    public func removeScreenshot() {
        screenshotData = nil
    }

    // MARK: - Transcription

    private func startTranscriptionIfPermitted() {
        // Gate on BOTH mic and speech-recognition authorization (fix #5):
        // starting a recognition task without real speech authorization
        // would otherwise error immediately and restart in a tight loop
        // (LegacySpeechTranscriber immediately begins a fresh segment on
        // every task error). Degrading silently to type-only mode here
        // matches the mic-denied behavior and keeps this gate consistent
        // with what onboarding's permission row displays.
        guard !isMicDenied, !isSpeechRecognitionDenied else { return }
        let service = transcriptionServiceFactory()
        transcriptionService = service
        isListening = true
        transcriptionTask = Task { [weak self] in
            let stream = await service.start()
            for await update in stream {
                guard let self else { return }
                await MainActor.run {
                    self.applyTranscriptUpdate(update)
                }
            }
            // Stream ended on its own (service-side stop/error) rather than
            // via `stopTranscription()` -- still clear the indicator so the
            // flap doesn't churn against a dead service.
            await MainActor.run {
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
        defer { lastServiceText = newServiceText }

        if transcriptText.isEmpty || (transcriptText == lastServiceText && newServiceText.hasPrefix(lastServiceText)) {
            // Common case: no user edits since the last update, and the
            // service's own text is a clean extension of what it last
            // reported -- adopt it wholesale.
            transcriptText = newServiceText
            return
        }

        // Either the user has diverged from the dictated text (a manual
        // edit mid-dictation), or the service's text didn't extend cleanly
        // (e.g. a segment restart producing something that doesn't share
        // the prior prefix). Either way, never rebuild the field from
        // scratch: append only the newly-dictated material onto whatever is
        // already on screen, so dictation extends the user's edits instead
        // of overwriting them.
        appendDictated(newServiceText)
    }

    /// Appends the portion of `newServiceText` that's new since
    /// `lastServiceText` onto `transcriptText`, rather than replacing the
    /// field outright.
    private func appendDictated(_ newServiceText: String) {
        let addition: String
        if newServiceText.hasPrefix(lastServiceText) {
            addition = String(newServiceText.dropFirst(lastServiceText.count))
        } else {
            addition = newServiceText
        }
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddition.isEmpty else { return }

        if transcriptText.isEmpty || transcriptText.hasSuffix(" ") {
            transcriptText += trimmedAddition
        } else {
            transcriptText += " " + trimmedAddition
        }
    }

    /// Stops the transcription service (e.g. panel closing). Safe to call
    /// multiple times.
    public func stopTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        let service = transcriptionService
        transcriptionService = nil
        isListening = false
        if let service {
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

/// Seam over `AVCaptureDevice.authorizationStatus(for: .audio)` so tests can
/// simulate a denied-mic host without touching real TCC state (plan U8:
/// "mic denied -> type-only mode flag set, panel still opens"). This checks
/// status only -- it never itself prompts for permission (that's an
/// onboarding-only concern, mirroring `ScreenshotService`'s preflight-only
/// contract).
public enum MicPermission {
    public static func isAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - Speech recognition permission seam

/// Seam over `SFSpeechRecognizer.authorizationStatus()` (fix #5) -- the
/// same real status `PermissionStep.swift`'s onboarding row displays, so
/// transcription's gating and the onboarding display can never disagree.
/// Status-only, like `MicPermission`: never itself prompts (onboarding owns
/// requesting).
public enum SpeechRecognitionPermission {
    public static func isAuthorized() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
