// WhistleApp.swift
// App entry point. Uses an NSApplicationDelegateAdaptor rather than a
// SwiftUI Scene-based menu bar (MenuBarExtra) because StatusItemController
// needs a raw NSStatusItem to split left/right-click behavior (TECH-SPEC
// §4.1). The SwiftUI App protocol is kept as the entry point (`@main`) for
// straightforward XcodeGen/Xcode lifecycle integration, but it declares no
// visible Scene of its own — everything is driven by the app delegate.

import AppKit
import SwiftUI
import WhistleCore

@main
struct WhistleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible windows at launch — the status item is the app's home
        // surface (TECH-SPEC §4.1). Settings/History windows are opened
        // on demand by AppDelegate via the status item's menu.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var authController: AuthController?
    private var capturePanelController: CapturePanelController?
    private var captureStore: CaptureStore?

    /// Convex deployment URL — read from Info.plist (`CONVEX_URL`, injected
    /// via xcconfig, see project.yml), never hardcoded. Falls back to the
    /// known grandiose-alpaca-243 deployment as a hardcoded emergency
    /// default only if the plist entry is somehow absent, so the app never
    /// crashes at launch over a missing config value.
    private static let fallbackConvexUrl = "https://grandiose-alpaca-243.convex.cloud"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let authProvider = Self.makeAuthProvider()
        let convexService = Self.makeConvexService(authProvider: authProvider)

        let auth = AuthController(
            authProvider: authProvider,
            convexService: convexService,
            breadcrumbStore: KeychainAuthBreadcrumbStore(),
            performInteractiveLogin: Self.makeInteractiveLogin(authProvider: authProvider)
        )
        self.authController = auth

        let statusItem = StatusItemController(authController: auth)
        statusItem.onHistoryRequested = { [weak self] in self?.showHistoryPlaceholder() }
        statusItem.onSettingsRequested = { [weak self] in self?.showSettingsPlaceholder() }
        statusItem.onCheckForUpdatesRequested = { [weak self] in self?.checkForUpdatesPlaceholder() }
        self.statusItemController = statusItem

        let store = Self.makeCaptureStore()
        self.captureStore = store
        let capturePanel = CapturePanelController(store: store)
        capturePanel.onHistoryRequested = { [weak self] in self?.showHistoryPlaceholder() }
        capturePanel.onSettingsRequested = { [weak self] in self?.showSettingsPlaceholder() }
        capturePanel.registerHotkey()
        self.capturePanelController = capturePanel

        // Left-click starts capture immediately (PRD F1.1) -- replaces
        // U6's placeholder no-op.
        statusItem.onCaptureTriggered = { [weak capturePanel] in
            capturePanel?.trigger()
        }

        LaunchAtLogin.setEnabled(true)

        Task {
            await auth.resolveInitialState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The app has no main window; closing an incidental window (e.g. a
        // future History/Settings window) must never quit the app — only
        // the status item menu's Quit does that.
        false
    }

    // MARK: - Placeholders (fully wired in later units: U9 History, U6/U8
    // Settings, U11 Sparkle updater)

    private func showHistoryPlaceholder() {
        NSLog("Whistle: History window requested (wired in U9)")
    }

    private func showSettingsPlaceholder() {
        NSLog("Whistle: Settings window requested (wired in U6/U8 settings unit)")
    }

    private func checkForUpdatesPlaceholder() {
        NSLog("Whistle: Check for Updates requested (wired in U11 via Sparkle)")
    }

    // MARK: - Wiring

    private static func makeAuthProvider() -> any WhistleAuthProvider {
        // Real Auth0 wiring, per plan U6: config comes from Info.plist
        // placeholders (no real tenant exists yet). This provider is wired
        // but not exercised by any automated test in this unit.
        Auth0AuthProvider()
    }

    private static func makeInteractiveLogin(authProvider: any WhistleAuthProvider) -> @Sendable () async throws -> Void {
        {
            guard let auth0Provider = authProvider as? Auth0AuthProvider else { return }
            try await auth0Provider.login()
        }
    }

    /// Real on-disk `CaptureStore` under Application Support -- the local
    /// offline-first queue (TECH-SPEC §4.1). Falls back to an in-memory
    /// store only if directory creation somehow fails, so a launch never
    /// crashes over local storage setup.
    private static func makeCaptureStore() -> CaptureStore {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let whistleDir = appSupport.appendingPathComponent("Whistle", isDirectory: true)
        try? fileManager.createDirectory(at: whistleDir, withIntermediateDirectories: true)

        let dbPath = whistleDir.appendingPathComponent("whistle.sqlite").path
        let screenshotsDir = whistleDir.appendingPathComponent("screenshots", isDirectory: true)

        do {
            return try CaptureStore(path: dbPath, screenshotsDirectory: screenshotsDir)
        } catch {
            NSLog("Whistle: failed to open on-disk CaptureStore (\(error)); falling back to in-memory store")
            return (try? CaptureStore(path: nil, screenshotsDirectory: screenshotsDir))
                ?? Self.fatalCaptureStoreFallback()
        }
    }

    private static func fatalCaptureStoreFallback() -> CaptureStore {
        // In-memory DB creation failing too indicates a fundamentally
        // broken environment (e.g. GRDB itself unavailable) -- there's no
        // graceful degrade left, per TECH-SPEC §2a this is treated as a
        // hard failure rather than silently running with no store at all.
        fatalError("Whistle: unable to construct any CaptureStore, in-memory fallback included")
    }

    private static func makeConvexService(authProvider: any WhistleAuthProvider) -> any ConvexServiceProtocol {
        let url = Bundle.main.object(forInfoDictionaryKey: "CONVEX_URL") as? String
        let deploymentUrl = (url?.isEmpty == false && url?.hasPrefix("$(") == false) ? url! : fallbackConvexUrl
        #if canImport(ConvexMobile)
            return LiveConvexService(deploymentUrl: deploymentUrl, authProvider: authProvider)
        #else
            fatalError("ConvexMobile unavailable — WhistleCore was built without the convex-swift dependency")
        #endif
    }
}
