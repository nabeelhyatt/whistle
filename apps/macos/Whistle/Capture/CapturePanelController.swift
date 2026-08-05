// CapturePanelController.swift
// TECH-SPEC §4.1 `CapturePanelController` row + §4.2 latency budget, plan
// U8: both panel focus modes ship in v1, selected by a UserDefaults debug
// flag (default: non-activating).
//
//   (a) Default -- non-activating floating NSPanel: `.nonactivatingPanel`
//       style, `canBecomeKey` overridden to true, `level: .floating`. The
//       Spotlight pattern -- takes key status and accepts typing WITHOUT
//       activating the app or deactivating the user's frontmost app.
//   (b) Fallback -- activating panel: records
//       `NSWorkspace.shared.frontmostApplication` before showing and
//       re-activates it on dismiss, so the user is never left stranded in
//       a different app.
//
// Both modes host `CaptureView` via `NSHostingView`, with an explicit
// `makeFirstResponder` call on the hosting view after `orderFront` (the
// known-good pattern for SwiftUI text focus inside a key-capable panel).
//
// Sequence per §4.2: the screenshot REQUEST is submitted before the panel
// is shown, and the panel is presented only after a one-shot capture-start
// acknowledgement (or a short timeout fallback) — so the frame is requested
// while Whistle is not yet on screen, without blocking presentation on image
// bytes or JPEG encoding (the thumbnail fades in when it resolves). Submitting
// the request before showing the panel is the primary protection against
// Whistle capturing itself; the capturer's self-app content-filter exclusion
// is a best-effort backstop (it may no-op on the bare path -- see
// ScreenshotService's header).
// `TranscriptionService.start()` happens on open (prewarmed engine, per
// §4.2 point 3); panel visible + first responder immediately after the ack.
//
// @MainActor per TECH-SPEC §4.1's concurrency map.

import AppKit
import KeyboardShortcuts
import SwiftUI
import WhistleCore

extension KeyboardShortcuts.Name {
    /// Default hotkey per plan U8: Option-Shift-W.
    static let triggerCapture = Self("triggerCapture", initial: .init(.w, modifiers: [.option, .shift]))
}

/// The non-activating vs. activating panel choice (plan U8: "A UserDefaults
/// debug flag selects the active mode at launch"). Exposed as a small
/// enum + UserDefaults key so MANUAL-QA can flip it and so
/// `CapturePanelController` construction stays testable without touching
/// real `UserDefaults` (tests inject the mode directly).
public enum CapturePanelMode: String {
    case nonActivating
    case activating

    /// The debug flag MANUAL-QA uses to switch modes. Default (flag
    /// absent, or any unrecognized value): `.nonActivating`.
    public static let userDefaultsKey = "WhistleCapturePanelMode"

    public static func current(defaults: UserDefaults = .standard) -> CapturePanelMode {
        guard let raw = defaults.string(forKey: userDefaultsKey), let mode = CapturePanelMode(rawValue: raw) else {
            return .nonActivating
        }
        return mode
    }
}

/// A floating panel that can become key without the app activating --
/// the "Spotlight pattern" (plan U8 default mode).
private final class NonActivatingCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Injectable seam over the raw AppKit window side-effects the controller
/// performs (ordering the panel front/out, taking key, activating the app,
/// the global click-away monitor). Production uses the defaults, which call
/// AppKit directly. Tests inject `.noop` so the panel is never actually
/// shown or made key -- presentation ordering is then observed purely through
/// the controller's own `panelPresented` state, with no real window to pop up
/// on screen and no spurious `windowDidResignKey` racing the test.
public struct CaptureWindowOps {
    public var orderFrontRegardless: @MainActor (NSPanel) -> Void = { $0.orderFrontRegardless() }
    public var makeKey: @MainActor (NSPanel) -> Void = { $0.makeKey() }
    public var makeKeyAndOrderFront: @MainActor (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }
    public var orderOut: @MainActor (NSPanel) -> Void = { $0.orderOut(nil) }
    public var makeFirstResponder: @MainActor (NSPanel, NSView?) -> Void = { $0.makeFirstResponder($1) }
    public var activateApp: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    public var frontmostApp: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    public var activate: @MainActor (NSRunningApplication) -> Void = { $0.activate() }
    public var addGlobalClickMonitor: @MainActor (@escaping (NSEvent) -> Void) -> Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: $0)
    }
    public var removeMonitor: @MainActor (Any) -> Void = { NSEvent.removeMonitor($0) }

    public init() {}

    /// Every operation a no-op (monitor returns no token). Panels are created
    /// but never shown/keyed -- for deterministic tests with no real UI.
    public static var noop: CaptureWindowOps {
        var ops = CaptureWindowOps()
        ops.orderFrontRegardless = { _ in }
        ops.makeKey = { _ in }
        ops.makeKeyAndOrderFront = { _ in }
        ops.orderOut = { _ in }
        ops.makeFirstResponder = { _, _ in }
        ops.activateApp = {}
        ops.frontmostApp = { nil }
        ops.activate = { _ in }
        ops.addGlobalClickMonitor = { _ in nil }
        ops.removeMonitor = { _ in }
        return ops
    }
}

@MainActor
public final class CapturePanelController: NSObject, NSWindowDelegate {
    private let store: CaptureStore
    private let screenshotService: ScreenshotService
    private let mode: CapturePanelMode
    /// Raw AppKit window side-effects, injected so tests can run with no real
    /// window (see `CaptureWindowOps`).
    private let windowOps: CaptureWindowOps
    /// Threaded straight into every `CaptureViewModel` this controller
    /// creates (fix #2) -- wired by `WhistleApp` to `ProjectsSyncCoordinator.
    /// refreshIfStale()`.
    private let refreshProjectsIfStale: () -> Void
    /// Permission seams (reset-deadlock fix), threaded straight into every
    /// `CaptureViewModel` this controller creates -- default to the real
    /// system implementations (matching `CaptureViewModel`'s own defaults)
    /// so production is unaffected; tests override these with deterministic
    /// (never `.notDetermined`) fakes so an automated `xcodebuild test` run
    /// never fires a real TCC prompt via this controller's default-checker
    /// tests.
    private let micPermissionStatus: @MainActor () -> PermissionState
    private let requestMicPermission: @MainActor () async -> Bool
    private let speechPermissionStatus: @MainActor () -> PermissionState
    private let requestSpeechPermission: @MainActor () async -> Bool
    /// Threaded straight into every `CaptureViewModel` this controller
    /// creates, matching `CaptureViewModel`'s own default. Tests that
    /// hardcode `micPermissionStatus`/`speechPermissionStatus` as `.granted`
    /// (to exercise the transcription-starts path) must ALSO override this
    /// with a fake -- otherwise `beginRunningTranscription()` constructs a
    /// real `TranscriptionServiceFactory.make()` transcriber, which starts a
    /// real `AVAudioEngine` tap. On hardware-less CI runners that traps
    /// fatally deep inside AVFAudio (uncatchable), looping xcodebuild's
    /// crash recovery for hours -- see the CI-spend incident this seam
    /// exists to prevent.
    private let transcriptionServiceFactory: () -> any TranscriptionService
    private let authStateProvider: @MainActor () -> AuthState
    private let requestSignIn: @MainActor () -> Void

    private var panel: NSPanel?
    private var viewModel: CaptureViewModel?
    private var hostingView: NSHostingView<CaptureView>?
    /// Whether the panel is currently presented, tracked deterministically as
    /// we order it in/out rather than read back from `NSPanel.isVisible`.
    /// AppKit's window-visibility state settles asynchronously and races
    /// window key transitions in a headless test host, so reading `isVisible`
    /// for control flow (the already-visible trigger branch) or for test
    /// observation is flaky now that presentation is deferred to the
    /// screenshot ack. This flag flips true in `showPanel` and false wherever
    /// the panel is ordered out (`dismissPreservingDraft`, `tearDownPanel`).
    private var panelPresented = false
    /// Global mouse-down monitor active while the panel is open: a click
    /// delivered to ANY OTHER app dismisses the panel (Spotlight pattern,
    /// requested in live review 2026-07-09). A global monitor only sees
    /// events routed to other applications, so panel clicks, the project
    /// picker's menu, and the Esc confirm alert can never self-dismiss.
    private var outsideClickMonitor: Any?

    /// Frontmost app recorded before showing the activating (fallback)
    /// panel, restored on dismiss -- never leave the user dumped in a
    /// different app.
    private var previousFrontmostApp: NSRunningApplication?

    /// The most recently started screenshot capture, if any. Cancelled
    /// before a new one starts so rapid Clear -> dismiss -> reopen cycling
    /// can't pile up unbounded concurrent captures for the same view
    /// model -- the generation token already discards a stale *result*,
    /// this bounds the *work in flight* to at most one tracked capture.
    private var screenshotTask: Task<Void, Never>?

    /// Monotonic token for the pending-presentation handshake. Bumped by
    /// every new handshake AND by `tearDownPanel()`, so any stale completion
    /// (a late ack, a late timeout, or a replaced panel) fails the guard in
    /// `completePendingPresentation` and no-ops.
    private var presentationGeneration = 0
    /// True between "screenshot request dispatched" and "panel shown". A
    /// plain re-trigger arriving in this window coalesces (see `trigger`)
    /// rather than spawning a duplicate panel or a second capture job.
    private var isPresentationPending = false
    /// Fallback timer so a hung/slow capturer (e.g. a cold, slow
    /// `SCShareableContent.current`) can never hold the panel hostage — it
    /// races the ack into the same idempotent completion.
    private var presentationTimeoutTask: Task<Void, Never>?
    /// How long to wait for the capture-start ack before presenting anyway.
    /// Sized to stay inside the §4.2 trigger->interactive budget. Internal so
    /// tests can lengthen it (to hold the handshake open) or shorten it (to
    /// exercise the fallback) — never a real TCC/UI dependency.
    var screenshotStartTimeout: TimeInterval = 0.25

    public var onHistoryRequested: () -> Void = {}
    public var onSettingsRequested: () -> Void = {}

    /// Supplies the menu bar status item button's on-screen window frame,
    /// so the panel can anchor directly beneath the actual icon rather than
    /// a hardcoded screen-corner guess. Wired by `WhistleApp` to
    /// `StatusItemController.buttonWindowFrame`; left `nil` in tests / any
    /// context without a real status item, in which case
    /// `positionBeneathStatusItem` falls back to a screen-corner default.
    public var statusItemButtonFrameProvider: () -> NSRect? = { nil }

    /// Fires after a capture is actually submitted (not on cancel/empty
    /// refusal), with its clientId. U10's onboarding wizard uses this to
    /// detect the first successful guided test capture (PRD F5.1 step 5→6).
    public var onCaptureSubmitted: (String) -> Void = { _ in }

    /// Test-only accessors (internal, not `public` -- reachable only via
    /// `@testable import`) so `CaptureViewModelTests` can drive submit/
    /// dismiss through the real controller and assert the panel actually
    /// closes, without needing AppKit UI automation. `isPanelOpen` reflects
    /// visibility, not mere existence -- a dismissed-with-draft panel
    /// (fix #4b) still exists (to preserve its draft) but is not "open".
    var isPanelOpen: Bool { panelPresented }
    /// A hidden panel that still exists to preserve its draft -- but NOT a
    /// brand-new panel still mid-handshake (created, not yet presented), which
    /// has `panel != nil` with `panelPresented == false` too.
    var hasPreservedDraft: Bool { panel != nil && !panelPresented && !isPresentationPending }
    /// Whether a capture session is live from the Sparkle update gate's
    /// perspective: panel presented, a draft preserved, OR a present-after-ack
    /// handshake still in flight. The pending case is load-bearing and new:
    /// presentation used to be synchronous, but now there's a brief window
    /// where `beginCapture` has already loaded a draft (e.g. a "Duplicate as
    /// new" prefill of a server row, which has no local screenshot and so
    /// takes the async path) while the panel isn't shown yet -- if the update
    /// gate treated that as idle, a Sparkle relaunch could discard the draft.
    var isCaptureSessionActive: Bool { panelPresented || hasPreservedDraft || isPresentationPending }
    var currentViewModel: CaptureViewModel? { viewModel }
    func submitCurrentForTesting() { handleSubmit() }
    func requestSignInForTesting() { handleSignIn() }
    func dismissPreservingDraftForTesting() { dismissPreservingDraft() }

    /// Debug-log hook for the trigger->panel-interactive timing called out
    /// in TECH-SPEC §4.2 (<300ms target). Automated tests don't assert on
    /// this -- it exists so a human can read the number during MANUAL-QA
    /// (plan U8 verification note: "do NOT claim them; DO add a debug
    /// timing log").
    public var onTimingMeasured: (TimeInterval) -> Void = { seconds in
        NSLog("Whistle: capture trigger->interactive took \(Int(seconds * 1000))ms")
    }

    public init(
        store: CaptureStore,
        screenshotService: ScreenshotService = ScreenshotService(),
        mode: CapturePanelMode = CapturePanelMode.current(),
        refreshProjectsIfStale: @escaping () -> Void = {},
        micPermissionStatus: @escaping @MainActor () -> PermissionState = { MicPermission.status() },
        requestMicPermission: @escaping @MainActor () async -> Bool = { await MicPermission.request() },
        speechPermissionStatus: @escaping @MainActor () -> PermissionState = { SpeechRecognitionPermission.status() },
        requestSpeechPermission: @escaping @MainActor () async -> Bool = { await SpeechRecognitionPermission.request() },
        transcriptionServiceFactory: @escaping () -> any TranscriptionService = { TranscriptionServiceFactory.make() },
        authStateProvider: @escaping @MainActor () -> AuthState = { .signedIn },
        requestSignIn: @escaping @MainActor () -> Void = {},
        windowOps: CaptureWindowOps = CaptureWindowOps()
    ) {
        self.store = store
        self.screenshotService = screenshotService
        self.mode = mode
        self.windowOps = windowOps
        self.refreshProjectsIfStale = refreshProjectsIfStale
        self.micPermissionStatus = micPermissionStatus
        self.requestMicPermission = requestMicPermission
        self.speechPermissionStatus = speechPermissionStatus
        self.requestSpeechPermission = requestSpeechPermission
        self.transcriptionServiceFactory = transcriptionServiceFactory
        self.authStateProvider = authStateProvider
        self.requestSignIn = requestSignIn
        super.init()
    }

    // MARK: - Hotkey registration

    public func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .triggerCapture) { [weak self] in
            self?.trigger()
        }
    }

    // MARK: - Trigger (hotkey or status-item left-click)

    /// Entry point shared by the hotkey and the status-item left-click
    /// (plan U8: "triggered identically"). Three cases:
    ///   1. Panel already visible -- duplicate trigger while open just
    ///      focuses the existing panel, no second screenshot (plan U8 edge
    ///      scenario).
    ///   2. Panel exists but hidden with a preserved draft (fix #4b/c: the
    ///      user dismissed it via Esc or clicking away) and this isn't an
    ///      explicit duplicate-as-new-capture request -- reopen the SAME
    ///      view model as-is: resume transcription, but never touch the
    ///      existing transcript/notes/screenshot, and never fire a new
    ///      screenshot capture.
    ///   3. Otherwise (first-ever trigger, no preserved draft, or an
    ///      explicit duplicate-as-new preFill) -- a brand-new capture from
    ///      scratch, discarding any stale hidden draft first.
    public func trigger(preFill: CapturePreFill? = nil) {
        let start = Date()

        if let panel, panelPresented {
            focusExistingPanel(panel)
            return
        }

        // A handshake is in flight (screenshot request dispatched, panel not
        // yet shown) and this is a plain re-trigger -- a hotkey mash or a
        // status-item double-click. Coalesce: the pending completion will
        // present the same panel momentarily; a second capture or show would
        // duplicate work. This MUST precede the preserved-draft branch, which
        // would otherwise treat the pending-but-hidden panel as a draft and
        // `showPanel` it immediately, defeating the ordering. An explicit
        // duplicate-as-new preFill instead falls through to the brand-new
        // branch, which REPLACES the pending panel via `tearDownPanel`.
        if isPresentationPending, preFill == nil {
            return
        }

        if preFill == nil, let panel, let viewModel {
            viewModel.updateSubmissionAuthState(authStateProvider())
            if viewModel.needsFreshScreenshotOnNextOpen {
                // Defer the show to the capture-start ack (see below).
                startScreenshotCaptureThenPresent(viewModel: viewModel, triggerStart: start)
                viewModel.resumeDraft()
            } else {
                viewModel.resumeDraft()
                showPanel(panel)
                onTimingMeasured(Date().timeIntervalSince(start))
            }
            return
        }

        // Brand-new capture: discard any stale hidden panel/draft first
        // (only relevant for an explicit duplicate-as-new preFill arriving
        // while a different draft is preserved). `tearDownPanel` bumps the
        // presentation generation, invalidating any handshake we just
        // replaced.
        tearDownPanel()

        let (panel, viewModel) = makePanel()
        self.panel = panel
        self.viewModel = viewModel

        viewModel.updateSubmissionAuthState(authStateProvider())
        // A duplicate can carry the source capture's screenshot. Preserve
        // those bytes rather than replacing them with a screenshot of the
        // current desktop -- and show synchronously (no capture, no wait).
        if preFill?.screenshotData == nil {
            // Submit the screenshot request, then present once it's in
            // flight (§4.2): the panel show is deferred to the ack so the
            // frame is requested before Whistle is on screen; image bytes
            // still arrive asynchronously and fade the thumbnail in.
            startScreenshotCaptureThenPresent(viewModel: viewModel, triggerStart: start)
            viewModel.beginCapture(preFill: preFill)
        } else {
            viewModel.beginCapture(preFill: preFill)
            showPanel(panel)
            onTimingMeasured(Date().timeIntervalSince(start))
        }
    }

    /// Submits a screenshot request before the panel is shown so it captures
    /// the app the user was working in, then defers presentation until the
    /// capture-start acknowledgement (or the timeout fallback) fires -- never
    /// blocking presentation on image delivery or JPEG encoding. The view
    /// model rejects a late image result if Clear began a newer capture while
    /// this request was in flight; the controller-level generation guards the
    /// deferred *presentation* across panel replacement.
    private func startScreenshotCaptureThenPresent(viewModel: CaptureViewModel, triggerStart: Date) {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        isPresentationPending = true

        let requestGeneration = viewModel.beginScreenshotRequest()
        let screenshotService = screenshotService
        screenshotTask?.cancel()
        presentationTimeoutTask?.cancel()

        // Deliberately NOT gated on Task.isCancelled: a replaced/cancelled
        // capture's ack must still be *delivered*; the generation guard on
        // the main actor is the single authority for whether it still applies.
        let onCaptureStarted: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.completePendingPresentation(generation: generation, triggerStart: triggerStart)
            }
        }

        screenshotTask = Task { [weak viewModel] in
            let data = await screenshotService.capture(onCaptureStarted: onCaptureStarted)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel?.attachScreenshot(data, requestGeneration: requestGeneration)
            }
        }

        let timeout = screenshotStartTimeout
        presentationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.completePendingPresentation(generation: generation, triggerStart: triggerStart)
        }
    }

    /// Idempotent, generation-guarded panel presentation. Reached from the
    /// capture-start ack, the timeout fallback, or both -- whichever lands
    /// first presents; the loser no-ops.
    private func completePendingPresentation(generation: Int, triggerStart: Date) {
        guard isPresentationPending, generation == presentationGeneration else { return }
        isPresentationPending = false
        presentationTimeoutTask?.cancel()
        presentationTimeoutTask = nil
        // Defensive: the panel is only shown here, so it should never already
        // be presented under a current generation -- but guard anyway.
        guard let panel, !panelPresented else { return }
        showPanel(panel)
        onTimingMeasured(Date().timeIntervalSince(triggerStart))
    }

    /// Invalidates any in-flight present-after-ack handshake: bumps the
    /// generation so a late ack/timeout fails the `completePendingPresentation`
    /// guard, clears the pending flag, and cancels the timeout fallback. Does
    /// not cancel `screenshotTask` -- a preserved-draft dismiss lets an
    /// in-flight image still attach to the surviving view model.
    private func invalidatePendingPresentation() {
        presentationGeneration &+= 1
        isPresentationPending = false
        presentationTimeoutTask?.cancel()
        presentationTimeoutTask = nil
    }

    private func focusExistingPanel(_ panel: NSPanel) {
        switch mode {
        case .nonActivating:
            windowOps.makeKeyAndOrderFront(panel)
        case .activating:
            windowOps.activateApp()
            windowOps.makeKeyAndOrderFront(panel)
        }
        hostingView.map { windowOps.makeFirstResponder(panel, $0) }
        // Fix #3: re-engage SwiftUI's FocusState even on a plain refocus
        // (this doesn't go through beginCapture/resumeDraft).
        viewModel?.requestTranscriptFocus()
    }

    // MARK: - Panel construction

    private func makePanel() -> (NSPanel, CaptureViewModel) {
        let viewModel = CaptureViewModel(
            store: store,
            screenshotService: screenshotService,
            transcriptionServiceFactory: transcriptionServiceFactory,
            micPermissionStatus: micPermissionStatus,
            requestMicPermission: requestMicPermission,
            speechPermissionStatus: speechPermissionStatus,
            requestSpeechPermission: requestSpeechPermission,
            refreshProjectsIfStale: refreshProjectsIfStale
        )

        let captureView = CaptureView(
            viewModel: viewModel,
            onSubmit: { [weak self] in self?.handleSubmit() },
            onEscape: { [weak self] in self?.handleEscape() },
            onHistory: { [weak self] in self?.onHistoryRequested() },
            onSettings: { [weak self] in self?.onSettingsRequested() },
            onSignIn: { [weak self] in self?.handleSignIn() }
        )

        let hosting = NSHostingView(rootView: captureView)
        // Height bumped from 360 -> 430 for the capture-panel-redesign
        // spec's status rail (docs/design/capture-panel-redesign-spec.md,
        // file change #5): the rail adds ~44pt below the input card that
        // the original layout didn't have. `positionBeneathStatusItem`
        // reads `panel.frame.size` at call time, so it picks up the new
        // height automatically -- no separate change needed there.
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 430)
        self.hostingView = hosting

        let styleMask: NSWindow.StyleMask
        switch mode {
        case .nonActivating:
            styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        case .activating:
            styleMask = [.titled, .fullSizeContentView]
        }

        let panel: NSPanel = mode == .nonActivating
            ? NonActivatingCapturePanel(
                contentRect: hosting.frame,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            : NSPanel(
                contentRect: hosting.frame,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Capture must work wherever the user is: without these the panel
        // opens on the desktop Space and is invisible while the user is in
        // any fullscreen app -- the hotkey appears to do nothing.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.delegate = self

        return (panel, viewModel)
    }

    private func showPanel(_ panel: NSPanel) {
        panelPresented = true
        positionBeneathStatusItem(panel)

        switch mode {
        case .nonActivating:
            windowOps.orderFrontRegardless(panel)
            windowOps.makeKey(panel)
        case .activating:
            previousFrontmostApp = windowOps.frontmostApp()
            windowOps.activateApp()
            windowOps.makeKeyAndOrderFront(panel)
        }

        // Explicit makeFirstResponder after orderFront -- the known-good
        // pattern for SwiftUI text focus inside a key-capable panel
        // (TECH-SPEC §4.1).
        if let hostingView {
            windowOps.makeFirstResponder(panel, hostingView)
        }

        // Click-away dismissal. Unconditional (no discard confirm): the mic
        // transcribes ambient speech, so gating on "has content" would
        // leave the panel stuck open for anyone who talks near their Mac.
        outsideClickMonitor = windowOps.addGlobalClickMonitor { [weak self] _ in
            // The user just clicked INTO another app -- don't let
            // closePanel()'s activating-mode restore steal focus back to
            // whatever was frontmost before the panel opened.
            self?.previousFrontmostApp = nil
            self?.dismissPreservingDraft()
        }
    }

    /// Anchors the panel beneath the status item (plan U8): reads the real
    /// `NSStatusItem` button's window frame via `statusItemButtonFrameProvider`
    /// and top-centers the panel directly under it, clamped to the screen's
    /// visible frame. Falls back to a top-right screen-corner guess if the
    /// status item's frame isn't available (e.g. in a test/headless
    /// context, or before the status item's window has been assigned a
    /// screen position).
    private func positionBeneathStatusItem(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let statusFrame = statusItemButtonFrameProvider() ?? NSRect(
            x: screen.visibleFrame.maxX - 40,
            y: screen.visibleFrame.maxY - 24,
            width: 24,
            height: 24
        )
        let origin = CapturePanelPositioning.origin(
            statusItemButtonFrame: statusFrame,
            panelSize: panel.frame.size,
            screenVisibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Submit / dismiss (plan U8 fix #4)

    private func handleSubmit() {
        let authState = authStateProvider()
        guard authState == .signedIn else {
            switch authState {
            case .signedOut, .reauthRequired:
                handleSignIn()
            case .signingIn:
                viewModel?.updateSubmissionAuthState(authState)
            case .signedIn:
                break
            }
            return
        }
        let result = viewModel?.submit()
        closePanel()
        if case .submitted(let clientId)? = result {
            NSLog("Whistle: capture submitted, clientId=%@", clientId)
            onCaptureSubmitted(clientId)
        }
    }

    private func handleSignIn() {
        viewModel?.updateSubmissionAuthState(.signingIn)
        requestSignIn()
    }

    public func updateAuthenticationState(_ state: AuthState, errorMessage: String? = nil) {
        viewModel?.updateSubmissionAuthState(state, errorMessage: errorMessage)
    }

    /// Esc dismisses the panel but preserves the draft (fix #4d note: "keep
    /// Esc = dismiss-preserving-draft too -- simpler than the old confirm
    /// dialog"). There's nothing to confirm/discard anymore: the draft
    /// survives until the user explicitly hits Clear or Submit.
    private func handleEscape() {
        dismissPreservingDraft()
    }

    /// Full teardown: stops transcription, restores the previously
    /// frontmost app (`.activating` mode), hides the panel, and releases
    /// panel/viewModel/hostingView so the next `trigger()` starts
    /// completely fresh. Used after an actual submit -- fix #4d, "Submit
    /// clears everything for the next capture."
    private func closePanel() {
        if let outsideClickMonitor {
            windowOps.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if mode == .activating, let previousFrontmostApp {
            windowOps.activate(previousFrontmostApp)
        }
        previousFrontmostApp = nil

        tearDownPanel()
    }

    /// Hides the panel and stops transcription, WITHOUT releasing
    /// panel/viewModel/hostingView -- the draft (transcript, notes,
    /// screenshot) must survive so a subsequent `trigger()` restores it
    /// exactly as left (fix #4b/c). Used by Esc and by losing key status
    /// (there is deliberately no close/X button -- these are the only two
    /// ways to leave without submitting).
    private func dismissPreservingDraft() {
        if let outsideClickMonitor {
            windowOps.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        viewModel?.stopTranscription()

        if mode == .activating, let previousFrontmostApp {
            windowOps.activate(previousFrontmostApp)
        }
        previousFrontmostApp = nil

        // Invalidate any in-flight presentation handshake so a late ack or
        // timeout can't re-present a panel the user just dismissed. Cannot
        // happen via the production dismiss entry points (they're only armed
        // after the panel is shown), but keeping the state-machine invariant
        // self-contained -- rather than resting on external unreachability --
        // is cheaper than reasoning about every future caller.
        invalidatePendingPresentation()

        panelPresented = false
        if let panel { windowOps.orderOut(panel) }
    }

    /// Stops transcription and releases panel/viewModel/hostingView
    /// outright, discarding any preserved draft. Safe to call when nothing
    /// exists yet (all no-ops via optional chaining).
    private func tearDownPanel() {
        // Invalidate any in-flight presentation handshake, then also cancel
        // the screenshot task -- this fully releases the viewModel, so bound
        // the wasted encode work too (the weak-viewModel + request-generation
        // guard already drops any late image regardless).
        invalidatePendingPresentation()
        screenshotTask?.cancel()
        viewModel?.stopTranscription()
        panelPresented = false
        if let panel { windowOps.orderOut(panel) }
        panel = nil
        viewModel = nil
        hostingView = nil
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Losing key status -- the user clicked away, or switched apps --
        // dismisses the panel while preserving the draft (plan U8 fix #4b:
        // "no X button", this + Esc are the only ways to leave without
        // submitting). Controller tests inject a no-op window-ops seam, so the
        // panel never actually becomes key and this never fires under test.
        dismissPreservingDraft()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        // Fix #1b: a permission grant recovered via System Settings (e.g.
        // toggling mic access off/on to force a fresh TCC grant tied to
        // the current build's signature) must be reflected the moment the
        // panel regains key status, without requiring an app relaunch --
        // mirrors `OnboardingWindowController.windowDidBecomeKey`'s same
        // fix for the onboarding permissions step.
        viewModel?.refreshPermissions()
    }
}

// MARK: - Panel positioning (plan U8 fix #2)

/// Pure top-center-under-anchor positioning math, extracted so it's
/// unit-testable without a real `NSScreen`/`NSPanel`/`NSStatusItem` (a
/// headless test host can't construct those meaningfully). Given the
/// status item button's actual on-screen frame, centers the panel
/// horizontally beneath it and clamps the result to the screen's visible
/// frame so the panel never runs off-screen on a narrow display or a
/// status item near a screen edge.
enum CapturePanelPositioning {
    static func origin(
        statusItemButtonFrame: NSRect,
        panelSize: NSSize,
        screenVisibleFrame: NSRect
    ) -> NSPoint {
        let unclampedX = statusItemButtonFrame.midX - panelSize.width / 2
        let minX = screenVisibleFrame.minX + 8
        let maxX = screenVisibleFrame.maxX - panelSize.width - 8
        let x: CGFloat
        if minX > maxX {
            // Panel wider than the screen's visible area -- center it
            // rather than producing an inverted clamp range.
            x = screenVisibleFrame.midX - panelSize.width / 2
        } else {
            x = min(max(unclampedX, minX), maxX)
        }
        let y = statusItemButtonFrame.minY - panelSize.height - 8
        return NSPoint(x: x, y: y)
    }
}
