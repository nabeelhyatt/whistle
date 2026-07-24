// WhistleApp.swift
// App entry point. Uses an NSApplicationDelegateAdaptor rather than a
// SwiftUI Scene-based menu bar (MenuBarExtra) because StatusItemController
// needs a raw NSStatusItem to split left/right-click behavior (TECH-SPEC
// §4.1). The SwiftUI App protocol is kept as the entry point (`@main`) for
// straightforward XcodeGen/Xcode lifecycle integration, but it declares no
// visible Scene of its own — everything is driven by the app delegate.

import AppKit
import Combine
import Sparkle
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
    private var convexService: (any ConvexServiceProtocol)?
    /// App-wide `projects.list` subscription that persists every yield into
    /// `CaptureStore.projects_snapshot` (fix: the capture panel's
    /// `ProjectPicker` showed "No projects" while Settings' own separate
    /// subscription displayed them fine -- nothing was ever writing into
    /// the snapshot table the picker actually reads). Started once at
    /// launch, independent of any window being open.
    private var projectsSyncCoordinator: ProjectsSyncCoordinator?
    /// Drains the local queued/syncFailed capture queue against Convex
    /// (fix: this is the exact engine that was never constructed anywhere
    /// in the app target -- submissions wrote to local SQLite as `queued`
    /// and sat there forever since nothing ever called `captures.create`).
    private var syncEngine: SyncEngine?
    /// Counts consecutive drain passes that deferred on
    /// `ConvexServiceError.notAuthenticated` (see `syncEngine`'s
    /// `onAuthDeferred` hook). Auth deferral deliberately isn't
    /// `.syncFailed`, so without this counter a server-revoked session with
    /// locally-persisted `.signedIn` state would defer silently forever on
    /// every periodic tick, with no user-visible surface at all. Reset
    /// whenever `auth.$state` changes (see the `auth.$state` sink below).
    private var consecutiveAuthDeferredDrains = 0
    private var historyViewModel: HistoryViewModel?
    private var historyWindowController: HistoryWindowController?
    private var notificationService: NotificationService?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var cancellables: Set<AnyCancellable> = []

    /// Sparkle 2 auto-updater (U11, TECH-SPEC §10). The standard updater
    /// controller drives scheduled background checks (SUScheduledCheckInterval
    /// in Info.plist) and the user-initiated "Check for Updates…" menu item.
    /// Feed URL + EdDSA public key come from Info.plist (SUFeedURL /
    /// SUPublicEDKey, injected via Config/Sparkle.xcconfig). `startingUpdater:
    /// true` is safe even though the feed URL is a placeholder domain — a
    /// failed feed fetch is a silent no-op for scheduled checks and a normal
    /// error sheet for manual ones.
    private var updaterController: SPUStandardUpdaterController?

    /// Convex deployment URL — read from Info.plist (`CONVEX_URL`, injected
    /// via xcconfig, see project.yml), never hardcoded. Falls back to the
    /// known grandiose-alpaca-243 deployment as a hardcoded emergency
    /// default only if the plist entry is somehow absent, so the app never
    /// crashes at launch over a missing config value.
    private static let fallbackConvexUrl = "https://grandiose-alpaca-243.convex.cloud"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Env-gated crash reporting (TECH-SPEC §10): clean no-op until
        // SENTRY_DSN is provisioned — see CrashReporting.swift / SECRETS.md.
        CrashReporting.configure()

        let authProvider = Self.makeAuthProvider()
        // `var`, not `let`: `ConvexServiceProtocol.onConnectionRebuilt` is a
        // `{ get set }` requirement, and calling its setter through an `any
        // ConvexServiceProtocol` existential requires a mutable binding even
        // though the real conformer (`LiveConvexService`) is a class.
        var convexService = Self.makeConvexService(authProvider: authProvider)
        self.convexService = convexService
        // Self-heal a wedged Convex connection (KTD5): fires once,
        // asynchronously, right after `LiveConvexService.rebuildClient()`
        // swaps in a fresh client following a detected wedge (a short streak
        // of consecutive call timeouts with no proof-of-life). Removes the
        // "wait for the next periodic drain tick" tail from recovery
        // latency -- sync retries seconds after the swap, not up to 180s
        // later. `drainSyncIfSignedIn()` is itself a no-op while signed out,
        // same gate as every other trigger.
        convexService.onConnectionRebuilt = { [weak self] in
            await self?.drainSyncIfSignedIn()
        }

        let auth = AuthController(
            authProvider: authProvider,
            convexService: convexService,
            breadcrumbStore: KeychainAuthBreadcrumbStore(),
            performInteractiveLogin: Self.makeInteractiveLogin(authProvider: authProvider),
            isDevSignIn: authProvider is DevSignInAuthProvider
        )
        self.authController = auth

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController

        let statusItem = StatusItemController(authController: auth)
        statusItem.onSettingsRequested = { [weak self] in self?.showSettings() }
        // Real Sparkle updater (U11) — replaces the U6 placeholder that only
        // logged the request.
        statusItem.onCheckForUpdatesRequested = { [weak updaterController] in
            updaterController?.checkForUpdates(nil)
        }
        self.statusItemController = statusItem

        let store = Self.makeCaptureStore()
        self.captureStore = store

        // App-wide, not scoped to Settings being open (fix: see
        // `projectsSyncCoordinator`'s declaration comment above).
        let projectsSyncCoordinator = ProjectsSyncCoordinator(store: store, convex: convexService)
        self.projectsSyncCoordinator = projectsSyncCoordinator

        // Core fix: SyncEngine was implemented and tested (WhistleCore) but
        // never constructed anywhere in the app target, so submitted
        // captures never left the local queue. Drains are gated on signed-in
        // auth state below; otherwise launch can turn queued captures into
        // syncFailed before AuthController has resolved a cached session.
        let networkMonitor = NWPathMonitorNetworkMonitor()
        let syncEngine = SyncEngine(
            store: store,
            convex: convexService,
            networkMonitor: networkMonitor,
            onAuthDeferred: { [weak self] in
                await MainActor.run { self?.noteAuthDeferredDrain() }
            }
        )
        self.syncEngine = syncEngine
        // Recover any drafts a previous process left stranded in `.syncing`
        // (a hang or kill mid-sync), then drain -- `drainPass` only re-fetches
        // `.queued`/`.syncFailed`, so without this a strand would never sync,
        // not even after a relaunch. Runs before the triggers below so the
        // reverted drafts are visible to the very first drain. Recovery is
        // unconditional (local-only), but the drain goes through the same
        // signed-in gate as every other trigger, so a launch drain can never
        // upload under an identity the UI doesn't consider signed in (the
        // gate plus `signOut()`'s credential-clear/auth-detach are layered
        // defenses). If auth hasn't resolved yet, the `auth.$state` sink
        // below drains once it lands on `.signedIn`.
        Task { [weak self, weak syncEngine] in
            await syncEngine?.recoverStrandedSyncing()
            await self?.drainSyncIfSignedIn()
        }
        Task { [weak self, weak networkMonitor] in
            guard let networkMonitor else { return }
            for await online in networkMonitor.pathUpdates() where online {
                await self?.drainSyncIfSignedIn()
            }
        }
        // Safety net, not the primary sync path: the trigger-based drain
        // above (and the launch/submit/manual-retry drains elsewhere) can in
        // principle silently miss firing or fail to recover. This
        // independent periodic loop self-heals a stuck capture within a
        // bounded time without requiring a manual relaunch. Gated on
        // signed-in state, same as `drainSyncIfSignedIn()`: even though
        // `AuthController.signOut()` now clears credentials and detaches the
        // Convex websocket's auth, the gate keeps a post-sign-out tick from
        // even attempting an upload -- defense in depth alongside the
        // detach, and consistency with every other drain trigger.
        Task { [weak self] in
            await syncEngine.runPeriodicDrain(gate: { [weak self] in
                await MainActor.run { self?.isSignedIn == true }
            })
        }
        // Degraded-mode fast probe (KTD5): the 180s periodic interval above
        // is the real driver of wedge-recovery latency (a socket death
        // between drains otherwise sits silent until the next tick). While
        // `isConnectionDegraded` (>=1 unresolved consecutive Convex call
        // timeout) AND signed in AND at least one draft is queued/syncFailed,
        // drain every 20s instead -- collapsing detection-to-healed from
        // ~9 minutes to roughly ~90s. Idle (no wakeups beyond the 20s poll)
        // once the connection is healthy again.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                guard let convexService = self.convexService, convexService.isConnectionDegraded else { continue }
                guard self.isSignedIn else { continue }
                guard let store = self.captureStore,
                      let pendingDrafts = try? store.drafts(in: [.queued, .syncFailed]),
                      !pendingDrafts.isEmpty
                else { continue }
                await self.drainSyncIfSignedIn()
            }
        }

        let notificationService = NotificationService()
        self.notificationService = notificationService

        let historyViewModel = HistoryViewModel(
            store: store,
            convex: convexService,
            notificationService: notificationService,
            lastSeenStore: Self.makeLastSeenStatusStore()
        )
        self.historyViewModel = historyViewModel
        historyViewModel.start(serverUpdatesEnabled: false)

        // Manual retry for a capture stuck in local `syncFailed` state
        // (`.localRetry` affordance): re-drains SyncEngine rather than
        // calling `captures.retry` server-side (no server record exists
        // yet for a local-only row).
        historyViewModel.onLocalRetryRequested = { [weak self] in
            Task { await self?.drainSyncIfSignedIn() }
        }

        // Ready-indicator (TECH-SPEC §4.1 StatusItemController row): this
        // unit computes the >=1-ready-and-unopened count from the same
        // subscription HistoryViewModel drives, and pushes it onto the
        // status item.
        historyViewModel.$hasUnreadReadyCaptures
            .receive(on: DispatchQueue.main)
            .sink { [weak statusItem] hasUnread in
                statusItem?.hasUnreadReadyCaptures = hasUnread
            }
            .store(in: &cancellables)

        auth.$state
            .combineLatest(auth.$lastSignInErrorMessage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, errorMessage in
                self?.capturePanelController?.updateAuthenticationState(state, errorMessage: errorMessage)
                self?.historyViewModel?.setServerUpdatesEnabled(state == .signedIn)
                Task { [weak projectsSyncCoordinator] in
                    await projectsSyncCoordinator?.setServerUpdatesEnabled(state == .signedIn)
                }
                // Any state transition (sign-in, sign-out, a fresh
                // reauthRequired) means the deferral streak that led here,
                // if any, is no longer relevant -- reset so a brand new
                // session starts the threshold count from zero rather than
                // inheriting a stale near-threshold count from before.
                self?.consecutiveAuthDeferredDrains = 0
                guard state == .signedIn else { return }
                Task { await self?.drainSyncIfSignedIn() }
            }
            .store(in: &cancellables)

        let historyWindow = HistoryWindowController(viewModel: historyViewModel)
        self.historyWindowController = historyWindow

        let capturePanel = CapturePanelController(
            store: store,
            refreshProjectsIfStale: { [weak projectsSyncCoordinator] in
                Task { await projectsSyncCoordinator?.refreshIfStale() }
            },
            authStateProvider: { [weak auth] in auth?.state ?? .signedOut },
            requestSignIn: { [weak auth] in Task { await auth?.signIn() } }
        )
        capturePanel.updateAuthenticationState(auth.state, errorMessage: auth.lastSignInErrorMessage)
        capturePanel.onHistoryRequested = { [weak self] in self?.showHistory() }
        capturePanel.onSettingsRequested = { [weak self] in self?.showSettings() }
        // Immediate drain on submit -- don't wait for the next network-path-
        // change event, which may not fire again for hours on a stable
        // connection.
        capturePanel.onCaptureSubmitted = { [weak self] _ in
            Task { await self?.drainSyncIfSignedIn() }
        }
        // Fix #2: anchor the panel beneath the real status item icon rather
        // than a hardcoded screen-corner guess.
        capturePanel.statusItemButtonFrameProvider = { [weak statusItem] in statusItem?.buttonWindowFrame }
        capturePanel.registerHotkey()
        self.capturePanelController = capturePanel

        historyWindow.onDuplicate = { [weak self, weak capturePanel] row in
            guard let self else { return }
            let screenshotData = self.resolveScreenshotData(for: row)
            let preFill = historyViewModel.duplicatePreFill(for: row, screenshotData: screenshotData)
            capturePanel?.trigger(preFill: preFill)
        }

        // Notification click routing (TECH-SPEC §4.1 NotificationService row):
        // ready/readyUnverified -> open deep link (marks opened); failed/auth
        // -> Settings -> API key (the real window, U10); failed other
        // -> captures.retry.
        notificationService.onRoute = { [weak self] route in
            self?.handleNotificationRoute(route)
        }

        historyWindow.onOpenSettings = { [weak self] in
            self?.showSettings(section: .apiKey)
        }

        statusItem.onHistoryRequested = { [weak self] in self?.showHistory() }

        // Left-click starts capture immediately (PRD F1.1) -- replaces
        // U6's placeholder no-op.
        statusItem.onCaptureTriggered = { [weak capturePanel] in
            capturePanel?.trigger()
        }

        LaunchAtLogin.setEnabled(true)

        // Dev/QA affordance: open the capture panel immediately on launch,
        // for manual verification when the hotkey or status item isn't
        // reachable (menu-bar overflow managers, screenshot-driven QA).
        // Debug-only: a release binary must not start screenshot capture +
        // transcription from a launch argument (PR #5 review).
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-capture-panel") {
            capturePanel.trigger()
        }
        #endif

        Task {
            await auth.resolveInitialState()
            self.showOnboardingIfNeeded()
        }
    }

    // MARK: - Onboarding (U10: wizard on first run only; resumes mid-flow
    // after a relaunch, e.g. the screen-recording grant's relaunch)

    private func showOnboardingIfNeeded() {
        guard let auth = authController, let convexService, let capturePanelController else { return }

        let stateStore = UserDefaultsOnboardingStateStore()
        guard !stateStore.load().completed else { return }

        let viewModel = OnboardingViewModel(
            auth: auth,
            convex: convexService,
            permissions: .system(),
            screenRecording: .system(),
            stateStore: stateStore
        )
        viewModel.onTriggerTestCapture = { [weak capturePanelController] in
            capturePanelController?.trigger()
        }
        viewModel.onOpenSettings = { [weak self] in
            self?.showSettings()
        }

        // The guided test capture goes through the REAL capture panel; its
        // submit callback is what advances the wizard to the screenshot
        // upsell (PRD F5.1 step 5 -> 6). Compose with (never replace) the
        // existing onCaptureSubmitted closure -- replacing it would
        // silently wipe out the sync-drain trigger set at launch, meaning
        // the onboarding wizard's own guided test capture would never sync.
        let existingOnSubmit = capturePanelController.onCaptureSubmitted
        capturePanelController.onCaptureSubmitted = { [weak viewModel] clientId in
            existingOnSubmit(clientId)
            viewModel?.noteTestCaptureSubmitted()
        }

        let controller = OnboardingWindowController(viewModel: viewModel)
        self.onboardingWindowController = controller
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The app has no main window; closing an incidental window (e.g. a
        // future History/Settings window) must never quit the app — only
        // the status item menu's Quit does that.
        false
    }

    // MARK: - History

    private func showHistory() {
        historyWindowController?.show()
    }

    /// Single source of truth for the signed-in check every drain trigger
    /// (launch, network-path change, submit, manual retry, periodic tick)
    /// gates on.
    private var isSignedIn: Bool {
        authController?.state == .signedIn
    }

    private func drainSyncIfSignedIn() async {
        guard isSignedIn, let syncEngine else {
            NSLog("Whistle: drainSyncIfSignedIn skipped — authState=%@ syncEngine=%@",
                  String(describing: authController?.state), syncEngine == nil ? "nil" : "present")
            return
        }
        _ = await syncEngine.drainOnce()
    }

    /// `SyncEngine`'s `onAuthDeferred` hook lands here (see its
    /// construction above). A single deferred pass is expected and benign —
    /// e.g. a brief launch-time race before Convex auth attaches — so this
    /// only escalates after tolerating a few in a row, and only while the
    /// local state still claims `.signedIn` (a `.reauthRequired`/`.signedOut`
    /// state has already surfaced the problem; escalating again would be
    /// redundant). 3 is a small, arbitrary threshold: enough to absorb a
    /// launch-time hiccup, small enough that a genuinely revoked session
    /// still surfaces quickly (each periodic tick is `runPeriodicDrain`'s
    /// own interval apart).
    private static let authDeferredEscalationThreshold = 3

    private func noteAuthDeferredDrain() {
        consecutiveAuthDeferredDrains += 1
        guard consecutiveAuthDeferredDrains >= Self.authDeferredEscalationThreshold,
              authController?.state == .signedIn
        else { return }
        authController?.handleTokenRefreshFailure()
        consecutiveAuthDeferredDrains = 0
    }

    /// Resolves screenshot bytes for "Duplicate as new capture" (PRD F3.6):
    /// local-only rows read straight from `CaptureStore`'s temp file; server-
    /// synced rows have no local file, so this unit intentionally leaves
    /// screenshot duplication as a text/notes-only pre-fill for server rows
    /// (screenshot re-fetch over HTTP is not implemented in this unit -- the
    /// pre-fill still works correctly for transcript/notes/project, which is
    /// the documented recovery scenario, PRD F3.6).
    private func resolveScreenshotData(for row: HistoryRowViewModel) -> Data? {
        guard let store = captureStore, row.serverRecord == nil else { return nil }
        guard let draft = try? store.draft(clientId: row.clientId), let path = draft.screenshotPath else { return nil }
        return store.screenshotData(atPath: path)
    }

    // MARK: - Notification routing

    private func handleNotificationRoute(_ route: NotificationRoute) {
        guard let historyViewModel else { return }
        switch route {
        case .openDeepLink(let recordId):
            guard let row = historyViewModel.rows.first(where: { $0.serverRecord?.id == recordId }) else { return }
            historyViewModel.openDeepLink(for: row)
        case .openSettingsApiKey:
            // The failed/auth route lands directly on the API-key section
            // (TECH-SPEC §4.4 "open Settings -> API key").
            showSettings(section: .apiKey)
        case .retry(let recordId):
            guard let row = historyViewModel.rows.first(where: { $0.serverRecord?.id == recordId }) else { return }
            historyViewModel.retry(row)
        }
    }

    // MARK: - Settings (real window, U10 — replaces the U6–U9 placeholder)

    private func showSettings(section: SettingsSection = .general) {
        if settingsWindowController == nil {
            guard let auth = authController, let convexService else { return }
            let viewModel = SettingsViewModel(convex: convexService, auth: auth)
            settingsWindowController = SettingsWindowController(viewModel: viewModel)
        }
        settingsWindowController?.show(section: section)
    }

    // MARK: - Wiring

    private static func makeAuthProvider() -> any WhistleAuthProvider {
        // Real Auth0 wiring when the xcconfig-injected tenant config is
        // present and non-placeholder; otherwise the local dev sign-in
        // fallback, so a fresh checkout with placeholder Auth0.xcconfig
        // values still gets a working (clearly-labeled) sign-in path
        // instead of a doomed network call against a nonexistent host.
        if let config = Auth0Config.fromInfoPlist() {
            return Auth0AuthProvider(config: config)
        }
        NSLog("Whistle: Auth0 is not configured (placeholder AUTH0_DOMAIN/AUTH0_CLIENT_ID) — using local dev sign-in fallback")
        return DevSignInAuthProvider()
    }

    private static func makeInteractiveLogin(authProvider: any WhistleAuthProvider) -> @Sendable () async throws -> Void {
        {
            if let auth0Provider = authProvider as? Auth0AuthProvider {
                try await auth0Provider.login()
            } else if let devProvider = authProvider as? DevSignInAuthProvider {
                await devProvider.login()
            }
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

    /// On-disk "last-seen server status per clientId" (plan U9: dedup
    /// notifications across relaunch). Lives alongside the real
    /// `CaptureStore` database under Application Support; falls back to an
    /// in-memory store (relaunch dedup degrades, but the app never crashes)
    /// if that directory is somehow unavailable.
    private static func makeLastSeenStatusStore() -> LastSeenStatusStore {
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return InMemoryLastSeenStatusStore()
        }
        let whistleDir = appSupport.appendingPathComponent("Whistle", isDirectory: true)
        try? fileManager.createDirectory(at: whistleDir, withIntermediateDirectories: true)
        let fileURL = whistleDir.appendingPathComponent("last-seen-status.json")
        return FileLastSeenStatusStore(fileURL: fileURL)
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
