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
// Sequence per §4.2: screenshot fires BEFORE the panel is shown (async;
// thumbnail fades in when ready, never blocks panel display);
// `TranscriptionService.start()` happens on open (prewarmed engine, per
// §4.2 point 3); panel visible + first responder immediately.
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

@MainActor
public final class CapturePanelController: NSObject, NSWindowDelegate {
    private let store: CaptureStore
    private let screenshotService: ScreenshotService
    private let mode: CapturePanelMode

    private var panel: NSPanel?
    private var viewModel: CaptureViewModel?
    private var hostingView: NSHostingView<CaptureView>?
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

    public var onHistoryRequested: () -> Void = {}
    public var onSettingsRequested: () -> Void = {}

    /// Fires after a capture is actually submitted (not on cancel/empty
    /// refusal), with its clientId. U10's onboarding wizard uses this to
    /// detect the first successful guided test capture (PRD F5.1 step 5→6).
    public var onCaptureSubmitted: (String) -> Void = { _ in }

    /// Test-only accessors (internal, not `public` -- reachable only via
    /// `@testable import`) so `CaptureViewModelTests` can drive submit/
    /// dismiss through the real controller and assert the panel actually
    /// closes, without needing AppKit UI automation.
    var isPanelOpen: Bool { panel != nil }
    var currentViewModel: CaptureViewModel? { viewModel }
    func submitCurrentForTesting() { handleSubmit() }

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
        mode: CapturePanelMode = CapturePanelMode.current()
    ) {
        self.store = store
        self.screenshotService = screenshotService
        self.mode = mode
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
    /// (plan U8: "triggered identically"). Duplicate trigger while the
    /// panel is already open just focuses the existing panel -- no second
    /// screenshot (plan U8 edge scenario).
    public func trigger(preFill: CapturePreFill? = nil) {
        let start = Date()

        if let panel, panel.isVisible {
            focusExistingPanel(panel)
            return
        }

        // Screenshot fires BEFORE panel show (§4.2): async, never blocks
        // panel display -- the thumbnail fades in once it resolves.
        let screenshotTask = Task { await screenshotService.capture() }

        let (panel, viewModel) = makePanel()
        self.panel = panel
        self.viewModel = viewModel

        viewModel.beginCapture(preFill: preFill)
        showPanel(panel)

        onTimingMeasured(Date().timeIntervalSince(start))

        Task { [weak viewModel] in
            let data = await screenshotTask.value
            await MainActor.run {
                viewModel?.attachScreenshot(data)
            }
        }
    }

    private func focusExistingPanel(_ panel: NSPanel) {
        switch mode {
        case .nonActivating:
            panel.makeKeyAndOrderFront(nil)
        case .activating:
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        hostingView.map { panel.makeFirstResponder($0) }
    }

    // MARK: - Panel construction

    private func makePanel() -> (NSPanel, CaptureViewModel) {
        let viewModel = CaptureViewModel(store: store, screenshotService: screenshotService)

        let captureView = CaptureView(
            viewModel: viewModel,
            onSubmit: { [weak self] in self?.handleSubmit() },
            onEscape: { [weak self] in self?.handleEscape() },
            onHistory: { [weak self] in self?.onHistoryRequested() },
            onSettings: { [weak self] in self?.onSettingsRequested() }
        )

        let hosting = NSHostingView(rootView: captureView)
        // Height bumped from 360 -> 400 for the capture-panel-redesign
        // spec's status rail (docs/design/capture-panel-redesign-spec.md,
        // file change #5): the rail adds ~44pt below the input card that
        // the original layout didn't have. `positionBeneathStatusItem`
        // reads `panel.frame.size` at call time, so it picks up the new
        // height automatically -- no separate change needed there.
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
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
        positionBeneathStatusItem(panel)

        switch mode {
        case .nonActivating:
            panel.orderFrontRegardless()
            panel.makeKey()
        case .activating:
            previousFrontmostApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        // Explicit makeFirstResponder after orderFront -- the known-good
        // pattern for SwiftUI text focus inside a key-capable panel
        // (TECH-SPEC §4.1).
        if let hostingView {
            panel.makeFirstResponder(hostingView)
        }

        // Click-away dismissal. Unconditional (no discard confirm): the mic
        // transcribes ambient speech, so gating on "has content" would
        // leave the panel stuck open for anyone who talks near their Mac.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    /// Anchors the panel beneath the status item (plan U8). Falls back to
    /// centering on the screen with the mouse cursor if the status item's
    /// screen frame isn't available (e.g. in a test/headless context).
    private func positionBeneathStatusItem(_ panel: NSPanel, statusItemFrame: NSRect? = nil) {
        guard let screen = NSScreen.main else { return }
        let frame = statusItemFrame ?? NSRect(
            x: screen.frame.maxX - 40,
            y: screen.frame.maxY - 24,
            width: 24,
            height: 24
        )
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: min(max(frame.midX - panelSize.width / 2, screen.frame.minX + 8), screen.frame.maxX - panelSize.width - 8),
            y: frame.minY - panelSize.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Submit / dismiss

    private func handleSubmit() {
        let result = viewModel?.submit()
        closePanel()
        if case .submitted(let clientId)? = result {
            onCaptureSubmitted(clientId)
        }
    }

    private func handleEscape() {
        guard let viewModel else {
            closePanel()
            return
        }
        switch viewModel.escAction() {
        case .close:
            closePanel()
        case .confirmThenClose:
            confirmDiscard { [weak self] confirmed in
                if confirmed {
                    self?.closePanel()
                }
            }
        }
    }

    /// Presents a confirm-discard alert (plan U8: "Esc with content ->
    /// confirm"). Split out so tests can drive `CaptureViewModel.escAction()`
    /// directly without needing a real `NSAlert`.
    private func confirmDiscard(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Discard this capture?"
        alert.informativeText = "You have unsaved transcript, notes, or a screenshot."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn)
    }

    private func closePanel() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        viewModel?.stopTranscription()

        if mode == .activating, let previousFrontmostApp {
            previousFrontmostApp.activate()
        }
        previousFrontmostApp = nil

        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
        hostingView = nil
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Non-activating panels stay open even when they lose key status
        // (the user might click elsewhere transiently); nothing to do here
        // for either mode -- explicit submit/Esc/close drive dismissal.
    }
}
