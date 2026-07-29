// SettingsWindow.swift
// The real Settings surface (PRD F5.2, TECH-SPEC §4.1 SettingsWindow row,
// plan U10) — replaces U9's `showSettingsPlaceholder()` no-op. Reached from
// the capture panel's header gear icon (U8), the status item's right-click
// menu (U6), and the failed/auth notification route (U9), which lands
// directly on the API-key section.
//
// Carries: hotkey recorder (KeyboardShortcuts UI), default project picker,
// agent picker (claude/codex/cursor) + optional model string
// (settings.update), screenshot on/off default, the template editor
// (TemplateEditor.swift), account/sign-out, and API key management (masked
// display via settings.get hasKey/last-4; replace flow =
// conductor.validateKey then settings.setConductorKey).

import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import WhistleCore

// MARK: - Sections (routing targets)

/// Which section the window should reveal on open. The failed/auth
/// notification route (TECH-SPEC §4.4) lands on `.apiKey` specifically.
public enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case apiKey = "API Key"
    case template = "Template"
    case account = "Account"

    public var id: String { rawValue }
}

// MARK: - View model

@MainActor
public final class SettingsViewModel: ObservableObject {
    // General
    @Published public var agent: String = "claude"
    @Published public var model: String = ""
    @Published public var screenshotsEnabled: Bool = true
    @Published public var defaultProjectId: String?
    @Published public private(set) var projects: [Project] = []

    // API key
    @Published public private(set) var hasKey = false
    @Published public private(set) var keyLastFour: String?
    @Published public var newKeyInput: String = ""
    @Published public private(set) var isReplacingKey = false
    @Published public private(set) var keyStatusMessage: String?
    @Published public private(set) var keyReplaceSucceeded: Bool?
    /// Set after a successful Save & Validate when the new key lists a
    /// different set of Conductor projects than the previous key — a heads-up
    /// that it may belong to a different Conductor account (canonical-accounts).
    @Published public private(set) var keyProjectsChanged = false
    @Published public private(set) var keyProjectsAvailable = false

    @Published public private(set) var loadError: String?
    @Published public private(set) var authState: AuthState
    @Published public private(set) var signInErrorMessage: String?

    // Account identity display (canonical-accounts plan §4): backend-truth
    // via `users:me`, never decoded from the JWT client-side. `nil` until
    // `load()` succeeds (or if `usersMe()` fails / this is a dev sign-in,
    // where there's no real backend identity to show).
    @Published public private(set) var signedInEmail: String?
    @Published public private(set) var signedInAuthSubject: String?

    /// The known agent values (PRD F5.2). `model` stays a free-form string
    /// (PRD open question: exact accepted values are undocumented).
    public static let agents = ["claude", "codex", "cursor"]

    public let templateEditor: TemplateEditorViewModel

    private let convex: any ConvexServiceProtocol
    private let auth: AuthController
    private var projectsTask: Task<Void, Never>?
    private var authCancellables: Set<AnyCancellable> = []

    public init(convex: any ConvexServiceProtocol, auth: AuthController) {
        self.convex = convex
        self.auth = auth
        self.templateEditor = TemplateEditorViewModel(convex: convex)
        self.authState = auth.state
        self.signInErrorMessage = auth.lastSignInErrorMessage
        auth.$state.receive(on: DispatchQueue.main).sink { [weak self] in self?.authState = $0 }.store(in: &authCancellables)
        auth.$lastSignInErrorMessage.receive(on: DispatchQueue.main).sink { [weak self] in self?.signInErrorMessage = $0 }.store(in: &authCancellables)
    }

    deinit {
        projectsTask?.cancel()
    }

    public func load() async {
        do {
            let snapshot = try await convex.settingsGet()
            agent = snapshot.agent
            model = snapshot.model ?? ""
            screenshotsEnabled = snapshot.screenshotsEnabled
            defaultProjectId = snapshot.defaultProjectId
            hasKey = snapshot.hasKey
            keyProjectsAvailable = snapshot.hasKey
            keyLastFour = snapshot.lastFour
            loadError = nil
        } catch {
            loadError = "Couldn't load settings. Check your connection."
        }
        await loadSignedInIdentity()
        subscribeToProjects()
    }

    /// Loads `users:me` for the account tab's identity display. Best-effort:
    /// a failure (network hiccup, or a dev sign-in session with no real
    /// backend identity) just leaves both fields `nil` rather than
    /// surfacing another error banner — `loadError` above already covers
    /// the "can't reach the backend" case for the tab that actually needs
    /// to block on it (General/API key).
    private func loadSignedInIdentity() async {
        guard !isDevSignIn else { return }
        do {
            let me = try await convex.usersMe()
            signedInEmail = me.email
            signedInAuthSubject = me.authSubject
        } catch {
            signedInEmail = nil
            signedInAuthSubject = nil
        }
    }

    /// "Signed in as:" value — the email if the identity carries one,
    /// otherwise the raw `authSubject` (the GitHub-noreply-email case from
    /// plan §4).
    public var signedInDisplayName: String {
        signedInEmail ?? signedInAuthSubject ?? ""
    }

    /// "Via:" value — derived from the `authSubject`'s provider prefix
    /// (`auth0|...`, `github|...`, `google-oauth2|...`), never from
    /// decoding the JWT. Falls back to the raw prefix for anything else so
    /// a new/unexpected connection never renders blank.
    public var signedInConnectionLabel: String {
        guard let subject = signedInAuthSubject else { return "" }
        let prefix = subject.split(separator: "|", maxSplits: 1).first.map(String.init) ?? subject
        switch prefix {
        case "auth0": return "Email & password"
        case "github": return "GitHub"
        case "google-oauth2": return "Google"
        default: return prefix
        }
    }

    private func subscribeToProjects() {
        guard projectsTask == nil else { return }
        projectsTask = Task { [weak self, convex] in
            for await list in convex.projectsList() {
                guard let self, !Task.isCancelled else { return }
                await MainActor.run { self.projects = list }
            }
        }
    }

    // MARK: General saves (each field patches via settings.update)

    public func saveAgent(_ newAgent: String) async {
        agent = newAgent
        try? await convex.settingsUpdate(SettingsPatch(agent: newAgent))
    }

    public func saveModel() async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await convex.settingsUpdate(SettingsPatch(model: trimmed.isEmpty ? .clear : .set(trimmed)))
    }

    public func saveScreenshotsEnabled(_ enabled: Bool) async {
        screenshotsEnabled = enabled
        try? await convex.settingsUpdate(SettingsPatch(screenshotsEnabled: enabled))
    }

    public func saveDefaultProject(_ projectId: String?) async {
        defaultProjectId = projectId
        try? await convex.settingsUpdate(SettingsPatch(defaultProjectId: projectId.map { .set($0) } ?? .clear))
    }

    // MARK: API key management (PRD F5.2: masked, replaceable)

    /// Masked display: the key itself is never returned to clients
    /// (TECH-SPEC §9) — only `hasKey` + last-4.
    public var maskedKeyDisplay: String {
        guard hasKey else { return "No key on file" }
        if let last = keyLastFour, !last.isEmpty {
            return "••••••••••••\(last)"
        }
        return "•••••••••••• (on file)"
    }

    /// Replace flow per plan U10: validate the pasted key first, then persist
    /// it only after Conductor accepts it.
    public func replaceKey() async {
        let key = newKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyStatusMessage = "Paste the new key first."
            keyReplaceSucceeded = nil
            return
        }
        guard !isReplacingKey else { return }
        isReplacingKey = true
        defer { isReplacingKey = false }

        let result: ConductorValidateResult
        do {
            result = try await convex.conductorValidateKeyDetailed(key: key)
        } catch {
            keyStatusMessage = "Couldn't save/validate the key (network or server error)."
            keyReplaceSucceeded = false
            keyProjectsChanged = false
            return
        }

        guard result.ok else {
            keyStatusMessage = "Conductor rejected this key. Double-check it at app.conductor.build/users/api-keys."
            keyReplaceSucceeded = false
            keyProjectsChanged = false
            return
        }

        do {
            try await convex.settingsSetConductorKey(key)
            keyStatusMessage = "Key saved and validated."
            keyReplaceSucceeded = true
            keyProjectsChanged = result.projectsChanged
            keyProjectsAvailable = true
            newKeyInput = ""
            // Refresh masked display (hasKey / last-4).
            if let snapshot = try? await convex.settingsGet() {
                hasKey = snapshot.hasKey
                keyLastFour = snapshot.lastFour
            }
        } catch {
            keyStatusMessage = "Couldn't save/validate the key (network or server error)."
            keyReplaceSucceeded = false
            keyProjectsChanged = false
            keyProjectsAvailable = false
        }
    }

    // MARK: Account

    /// True when the signed-in session is the local dev fallback (no real
    /// Auth0 tenant configured) — Account status shows "Dev sign-in".
    public var isDevSignIn: Bool { auth.isDevSignIn }

    public func signOut() async {
        await auth.signOut()
    }

    public func signIn() async {
        await auth.signIn()
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Binding var selectedSection: SettingsSection

    var body: some View {
        TabView(selection: $selectedSection) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsSection.general)
            apiKeyTab
                .tabItem { Label("API Key", systemImage: "key") }
                .tag(SettingsSection.apiKey)
            templateTab
                .tabItem { Label("Template", systemImage: "doc.text") }
                .tag(SettingsSection.template)
            accountTab
                .tabItem { Label("Account", systemImage: "person.circle") }
                .tag(SettingsSection.account)
        }
        .frame(width: 560, height: 520)
        .task { await viewModel.load() }
    }

    private var generalTab: some View {
        Form {
            Section {
                // KeyboardShortcuts' bundled recorder UI (TECH-SPEC §2's
                // rationale for the package) bound to the U8 hotkey name.
                KeyboardShortcuts.Recorder("Capture hotkey:", name: .triggerCapture)
            }

            Section {
                Picker("Default project:", selection: Binding(
                    get: { viewModel.defaultProjectId },
                    set: { newValue in Task { await viewModel.saveDefaultProject(newValue) } }
                )) {
                    Text("None").tag(String?.none)
                    ForEach(viewModel.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }

                Picker("Agent:", selection: Binding(
                    get: { viewModel.agent },
                    set: { newValue in Task { await viewModel.saveAgent(newValue) } }
                )) {
                    ForEach(SettingsViewModel.agents, id: \.self) { agent in
                        Text(agent.capitalized).tag(agent)
                    }
                }

                TextField("Model (optional):", text: $viewModel.model, prompt: Text("provider default"))
                    .onSubmit { Task { await viewModel.saveModel() } }

                Toggle("Attach a screenshot to captures by default", isOn: Binding(
                    get: { viewModel.screenshotsEnabled },
                    set: { newValue in Task { await viewModel.saveScreenshotsEnabled(newValue) } }
                ))
            }

            if let error = viewModel.loadError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            // The version lives here (rather than e.g. a menu-bar item)
            // because Settings -> General is the one place a user reporting
            // a bug is likely to look. A single `LabeledContent` row fits
            // the window's fixed 560x520 frame without pushing the other
            // sections around.
            Section {
                LabeledContent("Version:", value: Self.appVersionDisplay)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    /// E.g. "1.0.12" -- `CFBundleShortVersionString` (the
    /// `MARKETING_VERSION` AGENTS.md asks every behavior-changing PR to
    /// bump), read from the running app's own bundle rather than a
    /// hardcoded constant so the label can never drift from what was
    /// actually built. `CFBundleVersion` is appended in parens only when it
    /// differs (it normally tracks `MARKETING_VERSION` via
    /// `CURRENT_PROJECT_VERSION` in project.yml, so showing both would just
    /// repeat the number). Falls back to "unknown" if `Bundle.main`'s
    /// Info.plist is missing the key (a malformed build/test host, never a
    /// real app run).
    private static var appVersionDisplay: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != shortVersion {
            return "\(shortVersion) (\(build))"
        }
        return shortVersion
    }

    private var apiKeyTab: some View {
        Form {
            Section("Conductor API key") {
                LabeledContent("Current key:", value: viewModel.maskedKeyDisplay)

                SecureField("New key", text: $viewModel.newKeyInput, prompt: Text("Paste a new Conductor API key"))
                    .onSubmit { Task { await viewModel.replaceKey() } }

                HStack {
                    Link(
                        "app.conductor.build/users/api-keys",
                        destination: URL(string: "https://app.conductor.build/users/api-keys")!
                    )
                    .font(.callout)
                    Spacer()
                    Button {
                        Task { await viewModel.replaceKey() }
                    } label: {
                        if viewModel.isReplacingKey {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save & Validate")
                        }
                    }
                    .disabled(viewModel.isReplacingKey)
                }

                if let message = viewModel.keyStatusMessage {
                    Label(
                        message,
                        systemImage: viewModel.keyReplaceSucceeded == true
                            ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(viewModel.keyReplaceSucceeded == true ? Color.secondary : .orange)
                    .font(.callout)
                }

                if viewModel.keyProjectsChanged {
                    Label(
                        "This key can see a different set of Conductor projects than your previous key. If that's unexpected, it may belong to a different Conductor account than the one you use in the Conductor app.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            // Which Conductor account is this key on? There's no Conductor
            // whoami endpoint, so we show the projects the key can reach as an
            // identity proxy — a mismatch with what the user expects is the
            // tell that captures will land in the wrong account.
            if viewModel.hasKey && viewModel.keyProjectsAvailable && !viewModel.projects.isEmpty {
                Section("Projects this key can access") {
                    ForEach(viewModel.projects) { project in
                        Text(project.name)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var templateTab: some View {
        ScrollView {
            TemplateEditorView(viewModel: viewModel.templateEditor)
                .padding(16)
        }
    }

    private var accountTab: some View {
        Form {
            Section("Account") {
                switch viewModel.authState {
                case .signedIn:
                    LabeledContent("Status:", value: viewModel.isDevSignIn ? "Dev sign-in" : "Signed in")
                    if !viewModel.isDevSignIn {
                        LabeledContent("Signed in as:", value: viewModel.signedInDisplayName)
                        LabeledContent("Via:", value: viewModel.signedInConnectionLabel)
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await viewModel.signOut() }
                    }
                case .signingIn:
                    LabeledContent("Status:", value: "Signing in…")
                case .reauthRequired:
                    LabeledContent("Status:", value: "Session expired — sign in again")
                    if let signInErrorMessage = viewModel.signInErrorMessage {
                        Text(signInErrorMessage).foregroundStyle(.red).font(.callout)
                    }
                    Button("Sign In Again") { Task { await viewModel.signIn() } }
                case .signedOut:
                    LabeledContent("Status:", value: "Signed out")
                    if let signInErrorMessage = viewModel.signInErrorMessage {
                        Text(signInErrorMessage).foregroundStyle(.red).font(.callout)
                    }
                    Button("Sign In") { Task { await viewModel.signIn() } }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

// MARK: - Window controller

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var isWindowVisible: Bool { window?.isVisible == true }
    public let viewModel: SettingsViewModel

    /// Backing state for the selected tab, bridged into SwiftUI via an
    /// ObservableObject holder so `show(section:)` can re-route an
    /// already-open window (the notification's Settings→API-key route).
    private let sectionHolder = SectionHolder()

    @MainActor
    private final class SectionHolder: ObservableObject {
        @Published var section: SettingsSection = .general
    }

    private struct RoutedSettingsView: View {
        @ObservedObject var holder: SectionHolder
        @ObservedObject var viewModel: SettingsViewModel

        var body: some View {
            SettingsView(viewModel: viewModel, selectedSection: $holder.section)
        }
    }

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    public func show(section: SettingsSection = .general) {
        sectionHolder.section = section

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(
            rootView: RoutedSettingsView(holder: sectionHolder, viewModel: viewModel)
        )
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Whistle Settings"
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
