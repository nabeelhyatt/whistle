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

/// What Esc should do, given current panel content (plan U8: "Esc with
/// content -> confirm; Esc empty -> close").
public enum EscAction: Equatable {
    case close
    case confirmThenClose
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
    @Published public var selectedProjectId: String?
    @Published public private(set) var projects: [Project] = []
    @Published public var focusProjectPicker: Bool = false

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
    private let defaultAgent: String
    private let defaultModel: String?

    private var transcriptionService: (any TranscriptionService)?
    private var transcriptionTask: Task<Void, Never>?
    private var projectsTask: Task<Void, Never>?

    /// Committed transcript text accumulated by the transcription service,
    /// kept separately from `transcriptText` so the user's manual edits
    /// (the transcript field is editable per PRD F1.3) aren't clobbered by
    /// a stray late update after the user has already started typing over
    /// it. New transcription updates simply extend `transcriptText` as long
    /// as the user hasn't diverged from what the service has produced.
    private var lastServiceText: String = ""

    public init(
        store: CaptureStore,
        screenshotService: ScreenshotService = ScreenshotService(),
        transcriptionServiceFactory: @escaping () -> any TranscriptionService = { TranscriptionServiceFactory.make() },
        micPermissionChecker: @escaping () -> Bool = { MicPermission.isAuthorized() },
        defaultAgent: String = "claude",
        defaultModel: String? = nil
    ) {
        self.store = store
        self.screenshotService = screenshotService
        self.transcriptionServiceFactory = transcriptionServiceFactory
        self.micPermissionChecker = micPermissionChecker
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
        isMicDenied = !micPermissionChecker()

        loadProjects()
        startTranscriptionIfPermitted()
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
        guard !isMicDenied else { return }
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

    private func applyTranscriptUpdate(_ update: TranscriptUpdate) {
        let newServiceText = update.displayText
        // Only auto-extend the field if the user hasn't diverged from the
        // transcription service's own running text -- otherwise a manual
        // edit mid-dictation would be silently overwritten.
        if transcriptText == lastServiceText || transcriptText.isEmpty {
            transcriptText = newServiceText
        }
        lastServiceText = newServiceText
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
        projects = (try? store.projectsSnapshot()) ?? []
        if let lastUsed = try? store.lastUsedProjectId(), projects.contains(where: { $0.id == lastUsed }) {
            selectedProjectId = lastUsed
        } else {
            selectedProjectId = projects.first?.id
        }

        projectsTask?.cancel()
        projectsTask = Task { [weak self] in
            guard let self else { return }
            for await updated in self.store.projectsUpdates() {
                await MainActor.run {
                    self.projects = updated
                    if self.selectedProjectId == nil {
                        self.selectedProjectId = updated.first?.id
                    }
                }
            }
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

    // MARK: - Esc handling

    /// Plan U8: "Esc with content -> confirm; Esc empty -> close."
    public func escAction() -> EscAction {
        hasContent ? .confirmThenClose : .close
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
