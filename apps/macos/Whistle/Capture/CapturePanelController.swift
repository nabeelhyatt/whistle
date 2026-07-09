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
    /// Threaded straight into every `CaptureViewModel` this controller
    /// creates (fix #2) -- wired by `WhistleApp` to `ProjectsSyncCoordinator.
    /// refreshIfStale()`.
    private let refreshProjectsIfStale: () -> Void

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
    var isPanelOpen: Bool { panel?.isVisible ?? false }
    var hasPreservedDraft: Bool { panel != nil && !(panel?.isVisible ?? false) }
    var currentViewModel: CaptureViewModel? { viewModel }
    func submitCurrentForTesting() { handleSubmit() }
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
        refreshProjectsIfStale: @escaping () -> Void = {}
    ) {
        self.store = store
        self.screenshotService = screenshotService
        self.mode = mode
        self.refreshProjectsIfStale = refreshProjectsIfStale
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

        if let panel, panel.isVisible {
            focusExistingPanel(panel)
            return
        }

        if preFill == nil, let panel, let viewModel {
            viewModel.resumeDraft()
            showPanel(panel)
            onTimingMeasured(Date().timeIntervalSince(start))
            return
        }

        // Brand-new capture: discard any stale hidden panel/draft first
        // (only relevant for an explicit duplicate-as-new preFill arriving
        // while a different draft is preserved).
        tearDownPanel()

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
        // Fix #3: re-engage SwiftUI's FocusState even on a plain refocus
        // (this doesn't go through beginCapture/resumeDraft).
        viewModel?.requestTranscriptFocus()
    }

    // MARK: - Panel construction

    private func makePanel() -> (NSPanel, CaptureViewModel) {
        let viewModel = CaptureViewModel(
            store: store,
            screenshotService: screenshotService,
            refreshProjectsIfStale: refreshProjectsIfStale
        )

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
        let result = viewModel?.submit()
        closePanel()
        if case .submitted(let clientId)? = result {
            onCaptureSubmitted(clientId)
        }
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
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if mode == .activating, let previousFrontmostApp {
            previousFrontmostApp.activate()
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
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        viewModel?.stopTranscription()

        if mode == .activating, let previousFrontmostApp {
            previousFrontmostApp.activate()
        }
        previousFrontmostApp = nil

        panel?.orderOut(nil)
    }

    /// Stops transcription and releases panel/viewModel/hostingView
    /// outright, discarding any preserved draft. Safe to call when nothing
    /// exists yet (all no-ops via optional chaining).
    private func tearDownPanel() {
        viewModel?.stopTranscription()
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
        hostingView = nil
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Losing key status -- the user clicked away, or switched apps --
        // dismisses the panel while preserving the draft (plan U8 fix #4b:
        // "no X button", this + Esc are the only ways to leave without
        // submitting).
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
