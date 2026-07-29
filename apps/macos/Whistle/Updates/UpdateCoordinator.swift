// UpdateCoordinator.swift
// Owns Sparkle (SPUStandardUpdaterController) and adds the two behaviors the
// framework does not give us for free:
//
//   1. A ONE-TIME FIRST-LAUNCH CHECK. Sparkle deliberately never checks on
//      first launch -- it waits out SUScheduledCheckInterval (a day). The
//      whistle download button on nabeelhyatt.com is a hand-edited,
//      version-specific link (docs/RELEASING.md), so a brand-new user can
//      easily install a stale DMG and then run it for a day+ before Sparkle
//      says a word. `FirstLaunchUpdateGate` closes that window: a silent
//      feed probe at first launch, escalated to the real update prompt only
//      if there is something newer, with the onboarding wizard held back
//      until the check settles.
//
//   2. UPDATE UI THAT IS ACTUALLY VISIBLE, AND INSTALLS THAT ACTUALLY HAPPEN.
//      Whistle is an accessory/LSUIElement app (Info.plist LSUIElement,
//      WhistleApp's setActivationPolicy(.accessory)) launched at login and
//      left running for weeks. Sparkle's own docs note that for background
//      apps it shows the update alert *behind* other applications, and with
//      automatic downloads (SUAutomaticallyUpdate) it installs *on quit* --
//      a quit that may never come. So we activate the app before update UI
//      and install immediately once the app is idle.
//
// "Idle" matters because installing relaunches the app: an open capture panel
// holds text/transcript the user has not submitted yet, and that would be
// lost. Queued drafts are already on disk (SQLite) and survive a relaunch, so
// the open panel is the only thing that needs protecting.

import AppKit
import OSLog
import Sparkle

private let updateLog = Logger(subsystem: "build.conductor.whistle.app", category: "updates")

// MARK: - Persisted first-launch state

/// The two `UserDefaults` keys behind the one-time first-launch check, in one
/// injectable place so the gate can be unit-tested against a scratch domain.
///
/// The important invariant: `retire()` is called only on a CONCLUSIVE outcome
/// (the feed answered). An offline or slow first launch is precisely when the
/// check matters most, so a failure must leave the check armed for the next
/// launch rather than silently burning it. `attempts` is the backstop that
/// keeps a probe which reliably hangs or crashes from retrying forever.
final class FirstLaunchUpdateCheckStore {
    static let completedKey = "WhistleFirstLaunchUpdateCheckCompleted"
    static let attemptsKey = "WhistleFirstLaunchUpdateCheckAttempts"
    static let maxAttempts = 3

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var attempts: Int { defaults.integer(forKey: Self.attemptsKey) }

    /// True once the check has either succeeded or exhausted its attempts —
    /// in both cases it must never run (or delay a launch) again.
    var isRetired: Bool {
        defaults.bool(forKey: Self.completedKey) || attempts >= Self.maxAttempts
    }

    func noteAttempt() {
        defaults.set(attempts + 1, forKey: Self.attemptsKey)
    }

    func retire() {
        defaults.set(true, forKey: Self.completedKey)
    }
}

// MARK: - First-launch gate

/// The first-launch check as a plain state machine with injected effects, so
/// every branch is testable without Sparkle or a real feed. `UpdateCoordinator`
/// supplies the real `probe` / `showInteractiveUpdateUI` closures and forwards
/// Sparkle's delegate callbacks into `note…`.
@MainActor
final class FirstLaunchUpdateGate {
    /// What the silent probe learned. Only `.updateFound` escalates to UI, and
    /// only `.updateFound`/`.upToDate` retire the check.
    private enum ProbeOutcome {
        case updateFound
        case upToDate
        case failed
    }

    private enum State {
        /// Not started yet.
        case idle
        /// Silent `checkForUpdateInformation()` in flight.
        case probing
        /// Probe found something; the interactive update session is on screen.
        case awaitingUserDecision
        /// Probe ran past its deadline; onboarding was released and escalation
        /// abandoned for this launch (see `noteCycleFinished`).
        case timedOut
        /// Onboarding may proceed. Terminal.
        case settled
    }

    private let store: FirstLaunchUpdateCheckStore
    private let isReadOnlyVolume: () -> Bool
    private let timeout: Duration
    private let isEnabled: Bool
    private let probe: () -> Void
    private let showInteractiveUpdateUI: () -> Void

    private var state: State = .idle
    /// Tracked separately from `state`: a timeout releases the wizard while the
    /// probe is still nominally running, so "released" is not the same as
    /// `.settled`. Without this, a second `waitUntilSettled()` after a timeout
    /// would hang forever.
    private var hasReleasedWaiters = false
    private var probeOutcome: ProbeOutcome?
    private var timeoutTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        store: FirstLaunchUpdateCheckStore,
        isReadOnlyVolume: @escaping () -> Bool = {
            (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        },
        timeout: Duration = .seconds(10),
        isEnabled: Bool = true,
        probe: @escaping () -> Void,
        showInteractiveUpdateUI: @escaping () -> Void
    ) {
        self.store = store
        self.isReadOnlyVolume = isReadOnlyVolume
        self.timeout = timeout
        self.isEnabled = isEnabled
        self.probe = probe
        self.showInteractiveUpdateUI = showInteractiveUpdateUI
    }

    /// Fires the silent probe, unless this launch isn't a candidate. Safe to
    /// call more than once; only the first call does anything. Every
    /// non-candidate path still settles, so `waitUntilSettled()` can never
    /// strand the onboarding wizard.
    func start() {
        guard state == .idle else { return }

        // DEBUG builds: an update that tried to replace a DerivedData build
        // would only make local runs noisy.
        guard isEnabled else {
            updateLog.debug("First-launch update check disabled for this build")
            settle()
            return
        }

        if store.isRetired {
            settle()
            return
        }
        // A first-time user very often launches straight off the mounted DMG.
        // Sparkle cannot install onto a read-only volume, and its error sheet
        // would be the new user's first impression of the app -- so stay quiet
        // and let the check happen on the first launch from /Applications.
        // Deliberately does NOT consume an attempt.
        if isReadOnlyVolume() {
            updateLog.info("First-launch update check skipped: running from a read-only volume")
            settle()
            return
        }

        store.noteAttempt()
        state = .probing
        updateLog.info("First-launch update check: probing feed (attempt \(self.store.attempts))")
        probe()

        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.noteTimeout()
        }
    }

    /// Resolves once onboarding is allowed to appear. Returns immediately for
    /// every launch after the check has retired.
    func waitUntilSettled() async {
        if hasReleasedWaiters { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // MARK: Sparkle callbacks

    func noteFoundUpdate() {
        guard state == .probing else { return }
        probeOutcome = .updateFound
        // Deliberately not retired here: the check has only done its job once
        // the prompt is actually on screen (`noteEscalationShown`).
    }

    func noteNoUpdate() {
        guard state == .probing else { return }
        probeOutcome = .upToDate
        store.retire()
    }

    /// A feed fetch/parse failure. Deliberately does NOT retire the check.
    ///
    /// `probeOutcome == nil` is load-bearing, not defensive: Sparkle reports an
    /// up-to-date check through BOTH `updaterDidNotFindUpdate` and a follow-up
    /// abort carrying its own "You're up to date!" error, so without this an
    /// already-current launch would be recorded as a failure and re-probed.
    func noteFailure() {
        guard state == .probing, probeOutcome == nil else { return }
        probeOutcome = .failed
    }

    /// The interactive update prompt is on screen. Only now has the first-launch
    /// check delivered its value, so only now is it retired.
    func noteEscalationShown() {
        guard state == .awaitingUserDecision else { return }
        store.retire()
    }

    /// The prompt could not be shown (see `UpdateCoordinator`'s readiness wait).
    /// Release the wizard and leave the check armed for the next launch — the
    /// user has been told nothing, so this must not count as done.
    func noteEscalationFailed() {
        guard state == .awaitingUserDecision else { return }
        settle()
    }

    /// Sparkle finished an update cycle. Both the silent probe and the
    /// interactive session report here, so `state` decides what it means. The
    /// escalation has to happen here rather than in `noteFoundUpdate()`: the
    /// probe's session is still in progress at that point, and `SPUUpdater`
    /// ignores a new check while one is running.
    func noteCycleFinished(error: Error?) {
        switch state {
        case .probing:
            timeoutTask?.cancel()
            timeoutTask = nil
            let outcome = probeOutcome ?? (error == nil ? .upToDate : .failed)
            switch outcome {
            case .updateFound:
                updateLog.info("First-launch update check: update available, prompting before onboarding")
                state = .awaitingUserDecision
                // The probe's own session is still in progress inside this
                // callback, and `SPUUpdater` hard-refuses a new check until it
                // ends ("-checkForUpdates called but .sessionInProgress ==
                // YES", logged and otherwise silent). The coordinator's
                // implementation waits for the updater to be ready; a plain
                // next-runloop-turn hop is NOT enough.
                showInteractiveUpdateUI()
            case .upToDate:
                updateLog.info("First-launch update check: already up to date")
                settle()
            case .failed:
                let message = error?.localizedDescription ?? "unknown error"
                updateLog.warning("First-launch update check failed, will retry next launch: \(message, privacy: .public)")
                settle()
            }

        case .awaitingUserDecision:
            // Installed (the app is about to relaunch), skipped, or errored --
            // either way the wizard may proceed now.
            settle()

        case .idle, .timedOut, .settled:
            break
        }
    }

    // MARK: Private

    private func noteTimeout() {
        guard state == .probing else { return }
        // Release the wizard, but abandon the escalation: popping a modal over
        // a wizard the user has already started reading is worse than deferring
        // to the next launch. The check stays un-retired, so it retries.
        updateLog.warning("First-launch update check timed out, will retry next launch")
        state = .timedOut
        resumeWaiters()
    }

    private func settle() {
        timeoutTask?.cancel()
        timeoutTask = nil
        state = .settled
        resumeWaiters()
    }

    private func resumeWaiters() {
        hasReleasedWaiters = true
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

// MARK: - Coordinator

/// Not `@MainActor`: Sparkle's delegate protocols are plain Objective-C
/// protocols with no isolation, so the conformances stay nonisolated and hop
/// via `MainActor.assumeIsolated` (Sparkle invokes them on the main thread).
final class UpdateCoordinator: NSObject {
    private let store: FirstLaunchUpdateCheckStore
    private var controller: SPUStandardUpdaterController?
    private var gate: FirstLaunchUpdateGate?

    /// True when a relaunch would not destroy anything the user cares about.
    /// Supplied by `AppDelegate` (reads `CapturePanelController`), which is
    /// constructed after the updater, hence a closure rather than a value.
    var isIdle: () -> Bool = { true }

    init(store: FirstLaunchUpdateCheckStore = FirstLaunchUpdateCheckStore()) {
        self.store = store
        super.init()
    }

    /// Builds and starts the updater with `self` as both delegates, then arms
    /// the first-launch check. Separate from `init` because
    /// `SPUStandardUpdaterController` takes its delegates at construction and
    /// they have to be `self`.
    @MainActor
    func start() {
        // `startingUpdater: true` is required before any check method runs;
        // Sparkle explicitly permits a check in the same runloop turn, which is
        // what the gate's probe does below.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller

        let isEnabled: Bool
        #if DEBUG
        // Off by default so local Xcode runs aren't offered an update that
        // would try to replace a DerivedData build; opt in with
        // `defaults write <bundle-id> WhistleForceFirstLaunchUpdateCheck -bool YES`
        // to exercise the real path against a test feed (same UserDefaults
        // debug-seam idea as `CapturePanelMode.current(defaults:)`).
        isEnabled = UserDefaults.standard.bool(forKey: "WhistleForceFirstLaunchUpdateCheck")
        #else
        isEnabled = true
        #endif

        let gate = FirstLaunchUpdateGate(
            store: store,
            isEnabled: isEnabled,
            probe: { controller.updater.checkForUpdateInformation() },
            showInteractiveUpdateUI: { [weak self] in self?.escalateToInteractiveUpdate() }
        )
        self.gate = gate
        gate.start()
    }

    /// The status item's "Check for Updates…" item, and the escalation path for
    /// the first-launch check. Activates first so the window is not buried
    /// behind other apps (accessory app, no Dock icon).
    @MainActor
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Turns the first-launch probe's "there is an update" into the real update
    /// prompt. The wait is the whole point: the probe's session is still winding
    /// down when Sparkle reports the cycle finished, and `checkForUpdates` on a
    /// busy updater does nothing but log — which would leave a new user on the
    /// stale build with no prompt at all.
    @MainActor
    private func escalateToInteractiveUpdate() {
        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller, let gate = self.gate else { return }

            var waited = Duration.zero
            let limit = Duration.seconds(5)
            while controller.updater.sessionInProgress, waited < limit {
                try? await Task.sleep(for: .milliseconds(50))
                waited += .milliseconds(50)
            }
            guard !controller.updater.sessionInProgress else {
                updateLog.warning("Update found but the updater stayed busy; will retry next launch")
                gate.noteEscalationFailed()
                return
            }

            self.checkForUpdates()
        }
    }

    /// Resolves as soon as onboarding may appear. Returns immediately if
    /// `start()` was never called, so a missing wire-up can't hang launch.
    @MainActor
    func waitUntilFirstLaunchCheckSettles() async {
        guard let gate else { return }
        await gate.waitUntilSettled()
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateCoordinator: SPUUpdaterDelegate {
    /// Suppresses Sparkle's "check for updates automatically?" prompt, which an
    /// accessory app cannot reliably put in front of the user anyway. Automatic
    /// checks are declared in Info.plist (SUEnableAutomaticChecks) instead.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { gate?.noteFoundUpdate() }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { gate?.noteNoUpdate() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated {
            // "No update found" is delivered here as an abort as well as via
            // `updaterDidNotFindUpdate`. It is a conclusive answer, not a
            // failure -- misreading it would re-probe an up-to-date install on
            // every launch until the attempt budget ran out.
            if Self.isNoUpdateError(error) {
                gate?.noteNoUpdate()
            } else {
                gate?.noteFailure()
            }
        }
    }

    private static func isNoUpdateError(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            // Same normalization as `didAbortWithError`: an up-to-date result
            // is not an error, whichever callback carries it.
            let realError = error.flatMap { Self.isNoUpdateError($0) ? nil : $0 }
            gate?.noteCycleFinished(error: realError)
        }
    }

    /// Installing relaunches the app. Sparkle's default is to wait for a quit,
    /// which for a login-item menu-bar app can mean waiting weeks -- so install
    /// now if nothing would be lost, and otherwise fall back to install-on-quit.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            guard isIdle() else {
                updateLog.info("Update ready; deferring install to quit (app busy)")
                return false
            }
            updateLog.info("Update ready and app idle; installing now")
            immediateInstallHandler()
            return true
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateCoordinator: SPUStandardUserDriverDelegate {
    /// Required for Sparkle to consult the two hooks below.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle keeps ownership of the alert (we have no in-app surface for
    /// update reminders); the value we add is bringing it forward, below.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    /// For a background app Sparkle shows the alert *behind* everything else,
    /// where it can go unnoticed indefinitely. Pull it forward — but never on
    /// top of an in-progress capture.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                gate?.noteEscalationShown()
            }
            guard handleShowingUpdate, !state.userInitiated, isIdle() else { return }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
