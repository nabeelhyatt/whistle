// OnboardingWindow.swift
// First-run wizard, EXACTLY the reordered PRD F5.1 flow (TECH-SPEC §4.1
// OnboardingWindow row, plan U10):
//
//   (1) sign in                       — hard gate (AuthController)
//   (2) ONE combined mic+speech screen — never blocks (PermissionStep.swift)
//   (3) Conductor API key              — hard gate (inline conductor.validateKey)
//   (4) default project                — auto-selected, NO step shown, when the
//                                        account has exactly one project
//   (5) guided test capture            — hotkey affordance inline, not a step
//   (6) screen-recording upsell        — AFTER the first successful test
//                                        capture; non-blocking (§4.3 relaunch
//                                        handling)
//
// Wizard progress (current step + per-permission grant state) persists
// across app relaunch (PRD F5.1: the screen-recording grant can itself
// force a relaunch; any relaunch mid-wizard must not lose progress).
// @MainActor per TECH-SPEC §4.1's concurrency map.

import AppKit
import KeyboardShortcuts
import SwiftUI
import WhistleCore

// MARK: - Wizard steps

/// The reordered F5.1 steps. Raw values are the persistence format — do not
/// renumber/rename without a migration thought.
public enum OnboardingStep: String, Codable, Equatable, CaseIterable, Sendable {
    case signIn
    case permissions
    case apiKey
    case projectSelection
    case testCapture
    case screenRecordingUpsell
    case done
}

// MARK: - Persisted wizard state

/// Everything the wizard needs to resume exactly where it left off after a
/// relaunch: the current step plus per-permission grant state (PRD F5.1).
public struct OnboardingState: Codable, Equatable, Sendable {
    public var step: OnboardingStep
    public var micGranted: Bool
    public var speechGranted: Bool
    public var testCaptureCompleted: Bool
    public var completed: Bool

    public init(
        step: OnboardingStep = .signIn,
        micGranted: Bool = false,
        speechGranted: Bool = false,
        testCaptureCompleted: Bool = false,
        completed: Bool = false
    ) {
        self.step = step
        self.micGranted = micGranted
        self.speechGranted = speechGranted
        self.testCaptureCompleted = testCaptureCompleted
        self.completed = completed
    }
}

/// Persistence seam for wizard progress (plan U10: "UserDefaults/file —
/// spec requires it"). `UserDefaultsOnboardingStateStore` is the shipping
/// implementation; tests use `InMemoryOnboardingStateStore` (and can share
/// one instance across two view models to simulate a relaunch).
public protocol OnboardingStateStoring: AnyObject {
    func load() -> OnboardingState
    func save(_ state: OnboardingState)
}

public final class UserDefaultsOnboardingStateStore: OnboardingStateStoring {
    public static let key = "WhistleOnboardingState"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OnboardingState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(OnboardingState.self, from: data)
        else {
            return OnboardingState()
        }
        return state
    }

    public func save(_ state: OnboardingState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

public final class InMemoryOnboardingStateStore: OnboardingStateStoring {
    private var state: OnboardingState

    public init(initial: OnboardingState = OnboardingState()) {
        self.state = initial
    }

    public func load() -> OnboardingState { state }
    public func save(_ state: OnboardingState) { self.state = state }
}

// MARK: - View model

@MainActor
public final class OnboardingViewModel: ObservableObject {
    // MARK: Published wizard state

    @Published public private(set) var step: OnboardingStep
    @Published public private(set) var micState: PermissionState = .notDetermined
    @Published public private(set) var speechState: PermissionState = .notDetermined
    @Published public private(set) var speechModelAvailability: SpeechModelAvailability?

    // Step 3 (API key)
    @Published public var apiKeyInput: String = ""
    @Published public private(set) var isValidatingKey = false
    @Published public private(set) var apiKeyError: String?

    // Step 4 (project)
    @Published public private(set) var projects: [Project] = []
    @Published public var selectedProjectId: String?

    // Step 6 (screen-recording upsell)
    @Published public private(set) var screenRecordingGranted = false
    @Published public private(set) var needsRelaunchForScreenRecording = false

    // Sign-in
    @Published public private(set) var isSigningIn = false
    @Published public private(set) var signInError: String?

    /// True once the wizard has fully completed (persisted — the app shows
    /// the wizard on first run only).
    public var isCompleted: Bool { state.completed }

    /// True when the app is running without a configured Auth0 tenant and
    /// sign-in goes through the local dev fallback (`DevSignInAuthProvider`)
    /// — the sign-in step shows an explanatory message and a "Continue with
    /// local dev sign-in" button instead of the real Sign In button.
    public var usesDevSignIn: Bool { auth.isDevSignIn }

    /// Whether the test capture has been submitted at least once — gates
    /// the screenshot upsell (PRD F5.1 step 6: AFTER first successful test
    /// capture, not before).
    public var testCaptureCompleted: Bool { state.testCaptureCompleted }

    /// Wired by `OnboardingWindowController`/`AppDelegate` to
    /// `CapturePanelController.trigger()` — the guided test capture uses
    /// the REAL capture panel (plan U10).
    public var onTriggerTestCapture: () -> Void = {}

    /// Wired to open Settings (the "change" affordance next to the hotkey
    /// line on the test-capture screen).
    public var onOpenSettings: () -> Void = {}

    /// Fires when the wizard reaches `.done` so the window can close.
    public var onCompleted: () -> Void = {}

    // MARK: Dependencies

    private let auth: AuthController
    private let convex: any ConvexServiceProtocol
    private let permissions: OnboardingPermissions
    private let screenRecording: ScreenRecordingAccess
    private let stateStore: any OnboardingStateStoring

    private var state: OnboardingState {
        didSet { stateStore.save(state) }
    }

    public init(
        auth: AuthController,
        convex: any ConvexServiceProtocol,
        permissions: OnboardingPermissions,
        screenRecording: ScreenRecordingAccess,
        stateStore: any OnboardingStateStoring
    ) {
        self.auth = auth
        self.convex = convex
        self.permissions = permissions
        self.screenRecording = screenRecording
        self.stateStore = stateStore

        // Resume exactly where a prior run left off (PRD F5.1 persistence
        // requirement) — including per-permission grant state.
        let restored = stateStore.load()
        self.state = restored
        self.step = restored.completed ? .done : restored.step
        self.micState = restored.micGranted ? .granted : .notDetermined
        self.speechState = restored.speechGranted ? .granted : .notDetermined
        self.screenRecordingGranted = screenRecording.isGranted()
    }

    // MARK: Step 1 — sign in (hard gate)

    public func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        await auth.signIn()
        isSigningIn = false

        if auth.state == .signedIn {
            advance(to: .permissions)
        } else {
            // Prefer the controller's cause-specific message (backend auth
            // rejection vs network vs cancelled login) over the generic one.
            signInError = auth.lastSignInErrorMessage ?? "Sign-in didn't complete. Please try again."
        }
    }

    /// Called when the window appears with a cached session already signed
    /// in (e.g. relaunch mid-wizard): skips the sign-in gate without user
    /// action, but never skips any later gate.
    public func noteAlreadySignedIn() {
        guard step == .signIn, auth.state == .signedIn else { return }
        advance(to: .permissions)
    }

    // MARK: Step 2 — combined permissions (never blocks)

    public func refreshPermissionStatuses() {
        micState = permissions.micStatus()
        speechState = permissions.speechStatus()
        persistPermissionGrants()
    }

    public func requestMicAccess() async {
        let granted = await permissions.requestMic()
        micState = granted ? .granted : .denied
        persistPermissionGrants()
    }

    public func requestSpeechAccess() async {
        let granted = await permissions.requestSpeech()
        speechState = granted ? .granted : .denied
        persistPermissionGrants()
    }

    public func checkSpeechModelAvailability() async {
        speechModelAvailability = await permissions.speechModelAvailability()
    }

    /// Continue is ALWAYS allowed from the permission screen — denied
    /// permissions degrade (type-only capture) but never block (PRD F5.1 /
    /// plan U10: wizard never hard-blocks except sign-in and API key).
    public func continueFromPermissions() {
        persistPermissionGrants()
        advance(to: .apiKey)
    }

    private func persistPermissionGrants() {
        state.micGranted = micState == .granted
        state.speechGranted = speechState == .granted
    }

    // MARK: Step 3 — API key (hard gate, inline validation)

    public func submitApiKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiKeyError = "Paste your Conductor API key to continue."
            return
        }
        guard !isValidatingKey else { return }
        isValidatingKey = true
        apiKeyError = nil
        defer { isValidatingKey = false }

        do {
            // Validate the pasted key directly (conductor.validateKey also
            // refreshes projectsCache server-side, TECH-SPEC §7) and only
            // store it once it's known-good.
            let valid = try await convex.conductorValidateKey(key: key)
            guard valid else {
                apiKeyError = "That key wasn't accepted by Conductor. Check it at app.conductor.build/users/api-keys."
                return
            }
            try await convex.settingsSetConductorKey(key)
        } catch {
            apiKeyError = "Couldn't validate the key (network or server error). Please try again."
            return
        }

        await loadProjectsAndAdvance()
    }

    /// Step 4 per PRD F5.1: exactly one project → auto-select it with NO
    /// step shown; otherwise show the picker step.
    private func loadProjectsAndAdvance() async {
        let list = await firstProjectsYield()
        projects = list

        if list.count == 1, let only = list.first {
            selectedProjectId = only.id
            try? await convex.settingsUpdate(SettingsPatch(defaultProjectId: only.id))
            advance(to: .testCapture)
        } else {
            // Pre-select the first project so Continue is always available
            // (the picker is a choice, never a dead end).
            if selectedProjectId == nil { selectedProjectId = list.first?.id }
            advance(to: .projectSelection)
        }
    }

    /// Takes the first yield of the `projects.list` subscription, bounded
    /// so a dead subscription can't hang the wizard.
    private func firstProjectsYield(timeout: TimeInterval = 10) async -> [Project] {
        await withTaskGroup(of: [Project]?.self) { group in
            group.addTask { [convex] in
                for await list in convex.projectsList() {
                    return list
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    // MARK: Step 4 — project picker (only when >1 or 0 projects)

    public func confirmProjectSelection() async {
        if let selectedProjectId {
            try? await convex.settingsUpdate(SettingsPatch(defaultProjectId: selectedProjectId))
        }
        // Zero-project accounts may continue without a default (never
        // hard-block outside sign-in and API key); the capture panel's
        // picker will surface projects once they exist.
        advance(to: .testCapture)
    }

    // MARK: Step 5 — guided test capture

    /// The current hotkey, rendered on the test-capture screen ("Your
    /// hotkey is ⌥⇧W — change").
    public var hotkeyDescription: String {
        KeyboardShortcuts.getShortcut(for: .triggerCapture).map(String.init(describing:)) ?? "⌥⇧W"
    }

    public func startTestCapture() {
        onTriggerTestCapture()
    }

    /// Wired to the capture panel's submit callback: the first successful
    /// test capture unlocks the screenshot upsell (PRD F5.1 step 6 — after,
    /// not before).
    public func noteTestCaptureSubmitted() {
        guard !state.testCaptureCompleted else { return }
        state.testCaptureCompleted = true
        if step == .testCapture {
            advance(to: .screenRecordingUpsell)
        }
    }

    // MARK: Step 6 — screen-recording upsell (non-blocking)

    public func refreshScreenRecordingStatus() {
        screenRecordingGranted = screenRecording.isGranted()
    }

    /// "Add screenshots to future captures": one-shot
    /// `CGRequestScreenCaptureAccess()`. If the grant doesn't take effect
    /// immediately (macOS typically requires a relaunch, §4.3), surface the
    /// System Settings deep link + Relaunch affordance instead of blocking.
    public func enableScreenshots() {
        let grantedNow = screenRecording.request()
        screenRecordingGranted = grantedNow || screenRecording.isGranted()
        if screenRecordingGranted {
            complete()
        } else {
            needsRelaunchForScreenRecording = true
        }
    }

    public func openScreenRecordingSystemSettings() {
        screenRecording.openSystemSettings()
    }

    /// "Relaunch now" (§4.3). Wizard state (including
    /// `testCaptureCompleted`) is already persisted, so the relaunched app
    /// resumes at this step and can finish.
    public func relaunchForScreenRecording() {
        screenRecording.relaunchApp()
    }

    /// Declining the upsell never blocks completion (plan U10 scenario).
    public func declineScreenshots() {
        complete()
    }

    public func finishUpsell() {
        complete()
    }

    private func complete() {
        state.completed = true
        state.step = .done
        step = .done
        onCompleted()
    }

    // MARK: Advancement + persistence

    private func advance(to next: OnboardingStep) {
        step = next
        state.step = next
    }
}

// MARK: - Wizard view

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        Group {
            switch viewModel.step {
            case .signIn:
                signInStep
            case .permissions:
                PermissionStepView(viewModel: viewModel)
            case .apiKey:
                apiKeyStep
            case .projectSelection:
                projectStep
            case .testCapture:
                testCaptureStep
            case .screenRecordingUpsell:
                upsellStep
            case .done:
                doneStep
            }
        }
        .frame(width: 480, height: 420)
        .onAppear { viewModel.noteAlreadySignedIn() }
    }

    private var signInStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
            Text("Welcome to Whistle")
                .font(.title.bold())
            Text("A quick little app to signal Conductor to get to work on something")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if let error = viewModel.signInError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if viewModel.usesDevSignIn {
                // No Auth0 tenant configured in this build (placeholder
                // xcconfig values) — offer the local dev fallback instead
                // of a Sign In button that would fail with a network error.
                Text("Auth0 isn't configured in this build, so real sign-in is unavailable. You can continue with a local dev session instead.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                Button {
                    Task { await viewModel.signIn() }
                } label: {
                    if viewModel.isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Continue with local dev sign-in")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSigningIn)
            } else {
                Button {
                    Task { await viewModel.signIn() }
                } label: {
                    if viewModel.isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSigningIn)
            }
            Spacer()
        }
        .padding(24)
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Conductor")
                .font(.title2.bold())
            Text("Whistle sends each capture to a Conductor workspace. Paste your API key — it's stored server-side and never leaves the backend.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(
                "Get your key at app.conductor.build/users/api-keys",
                destination: URL(string: "https://app.conductor.build/users/api-keys")!
            )
            .font(.callout)

            SecureField("Conductor API key", text: $viewModel.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.submitApiKey() } }

            if let error = viewModel.apiKeyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    Task { await viewModel.submitApiKey() }
                } label: {
                    if viewModel.isValidatingKey {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Validate & Continue")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isValidatingKey)
            }
        }
        .padding(24)
    }

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Default project")
                .font(.title2.bold())
            Text("New captures go to this Conductor project unless you pick another in the capture panel.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.projects.isEmpty {
                Text("No projects found on this account yet — you can set a default later in Settings.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $viewModel.selectedProjectId) {
                    ForEach(viewModel.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Continue") {
                    Task { await viewModel.confirmProjectSelection() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private var testCaptureStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.circle")
                .font(.system(size: 40))
            Text("Try a capture")
                .font(.title2.bold())
            Text("Speak or type a quick idea, then press ⏎. That's the whole workflow.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Button("Start test capture") {
                viewModel.startTestCapture()
            }
            .keyboardShortcut(.defaultAction)

            // One-line hotkey affordance, not a dedicated step (PRD F5.1).
            HStack(spacing: 4) {
                Text("Your hotkey is \(viewModel.hotkeyDescription) —")
                    .foregroundStyle(.secondary)
                Button("change") { viewModel.onOpenSettings() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            Spacer()
        }
        .padding(24)
    }

    private var upsellStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40))
            Text("Add screenshots to future captures")
                .font(.title2.bold())
            Text("Whistle can grab what's on screen at the instant you capture, so the agent sees what you saw. Requires the Screen Recording permission — you can always skip this.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            if viewModel.screenRecordingGranted {
                Label("Screen recording enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Finish") { viewModel.finishUpsell() }
                    .keyboardShortcut(.defaultAction)
            } else if viewModel.needsRelaunchForScreenRecording {
                Text("macOS applies this permission on next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") {
                        viewModel.openScreenRecordingSystemSettings()
                    }
                    Button("Relaunch now") {
                        viewModel.relaunchForScreenRecording()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Skip for now") { viewModel.declineScreenshots() }
                    .buttonStyle(.link)
            } else {
                Button("Add screenshots") { viewModel.enableScreenshots() }
                    .keyboardShortcut(.defaultAction)
                Button("Skip for now") { viewModel.declineScreenshots() }
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(24)
        .onAppear { viewModel.refreshScreenRecordingStatus() }
    }

    private var doneStep: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.title2.bold())
            Text("Hit \(viewModel.hotkeyDescription) any time an idea strikes.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Window controller

@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    public let viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.onCompleted = { [weak self] in
            // Give the "You're all set" screen a beat, then close.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.close()
            }
        }
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: OnboardingView(viewModel: viewModel))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Welcome to Whistle"
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.orderOut(nil)
        window = nil
    }
}
