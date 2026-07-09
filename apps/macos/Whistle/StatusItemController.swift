// StatusItemController.swift
// Custom NSStatusItem (deliberately NOT SwiftUI's MenuBarExtra, which can't
// cleanly split left/right-click behavior — TECH-SPEC §4.1). Left-click is a
// capture-trigger placeholder in this unit (fully wired to
// CapturePanelController in U8); right-click pops an NSMenu with History,
// Settings, account/sign-in state, Check for Updates, and Quit.
//
// Also owns launch-at-login registration via SMAppService (plan U6,
// TECH-SPEC requirement R6).
//
// @MainActor per TECH-SPEC §4.1's concurrency map: UI controllers carry a
// targeted @MainActor rather than the whole app building under strict
// Swift 6 concurrency checking.

import AppKit
import ServiceManagement
import WhistleCore

@MainActor
public final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let authController: AuthController
    private let readyBadge = NSView()

    /// Placeholder for the left-click capture action. Fully wired to
    /// `CapturePanelController` in U8; here it's a no-op-by-default hook so
    /// this unit's smoke test can verify the click path is reachable
    /// without a capture panel existing yet.
    public var onCaptureTriggered: () -> Void = {}
    public var onHistoryRequested: () -> Void = {}
    public var onSettingsRequested: () -> Void = {}
    public var onCheckForUpdatesRequested: () -> Void = {}

    /// True whenever >=1 capture is `ready` and unopened (TECH-SPEC §4.1
    /// ready-indicator). Wired up fully once HistoryWindow's subscription
    /// exists (U9); exposed here so that unit can set it without this
    /// controller depending on ConvexService directly.
    public var hasUnreadReadyCaptures: Bool = false {
        didSet { updateReadyBadge() }
    }

    /// The status item button's actual on-screen window frame -- consumed
    /// by `CapturePanelController` (plan U8 fix #2) to anchor the capture
    /// panel directly beneath the menu bar icon instead of guessing a
    /// screen corner. `nil` before the button has a window (e.g. very
    /// early in launch, or a headless/test context).
    public var buttonWindowFrame: NSRect? {
        statusItem.button?.window?.frame
    }

    public init(authController: AuthController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.authController = authController
        super.init()
        configureButton()
    }

    // MARK: - Button / icon

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // Defensive fallback: if the asset catalog lookup somehow fails
        // (missing/corrupt Assets.car), fall back to an SF Symbol so the
        // status item can never render as an invisible empty square.
        let icon = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Whistle")
        icon?.isTemplate = true
        // Pin the point size explicitly to the standard menu bar glyph size
        // rather than trusting the asset's intrinsic size — a wrong-DPI or
        // mis-sized source PNG would otherwise render tiny (or oversized
        // and clipped) in the status bar.
        icon?.size = NSSize(width: 18, height: 18)
        button.image = icon
        button.toolTip = "Whistle"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        configureReadyBadge(in: button)
    }

    /// Small fixed-color dot overlaid on the (template, auto light/dark
    /// adapting) menu bar icon to signal an unread ready capture -- a
    /// template image can't carry its own color, so the "ready" state is a
    /// separate always-yellow subview rather than a recolored icon.
    private func configureReadyBadge(in button: NSStatusBarButton) {
        let diameter: CGFloat = 6
        readyBadge.wantsLayer = true
        readyBadge.layer?.backgroundColor = NSColor(srgbRed: 0xF1 / 255, green: 0xB4 / 255, blue: 0x18 / 255, alpha: 1).cgColor
        readyBadge.layer?.cornerRadius = diameter / 2
        readyBadge.isHidden = true
        readyBadge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(readyBadge)
        NSLayoutConstraint.activate([
            readyBadge.widthAnchor.constraint(equalToConstant: diameter),
            readyBadge.heightAnchor.constraint(equalToConstant: diameter),
            readyBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            readyBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2)
        ])
    }

    private func updateReadyBadge() {
        readyBadge.isHidden = !hasUnreadReadyCaptures
    }

    // MARK: - Click routing

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Synthetic activations (VoiceOver/accessibility `AXPress`) carry no
        // NSEvent -- treat them as the primary action rather than dropping
        // them, so assistive tech can trigger capture.
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showMenu()
        default:
            onCaptureTriggered()
        }
    }

    // MARK: - Right-click menu

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(accountMenuItem())
        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "History", action: #selector(historyClicked), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Whistle", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // NSStatusItem shows `menu` automatically on the next click while
        // it's assigned; clear it after so left-click reverts to the
        // capture-trigger action instead of always opening the menu.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    private func accountMenuItem() -> NSMenuItem {
        let title: String
        switch authController.state {
        case .signedIn:
            title = authController.isDevSignIn ? "Dev sign-in" : "Signed in"
        case .signingIn:
            title = "Signing in…"
        case .reauthRequired:
            title = "Sign-in required…"
        case .signedOut:
            title = "Sign In…"
        }
        let item = NSMenuItem(title: title, action: #selector(accountClicked), keyEquivalent: "")
        item.target = self
        item.isEnabled = authController.state != .signingIn && authController.state != .signedIn
        return item
    }

    // MARK: - Actions

    @objc private func accountClicked() {
        Task { await authController.signIn() }
    }

    @objc private func historyClicked() {
        onHistoryRequested()
    }

    @objc private func settingsClicked() {
        onSettingsRequested()
    }

    @objc private func checkForUpdatesClicked() {
        onCheckForUpdatesRequested()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

// MARK: - Launch at login

/// Wraps `SMAppService.mainApp` registration (plan U6, requirement R6).
/// Isolated behind a tiny type so `StatusItemController`/settings UI can be
/// tested without depending on the real `SMAppService` singleton's
/// process-level state.
@MainActor
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Registration can fail (e.g. outside a signed .app bundle
            // during local `xcodebuild test` runs) — degrade silently per
            // TECH-SPEC §2a's "skip + log a reason" convention rather than
            // crash the app over a non-critical convenience feature.
            NSLog("Whistle: LaunchAtLogin.setEnabled(\(enabled)) failed: \(error)")
        }
    }
}
