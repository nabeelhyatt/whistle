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
// (TemplateEditor.swift), account/sign-out, and API key management (multi-
// org plan: a list of labeled org keys via orgs.list, add via
// orgs.addKey/rename via orgs.rename/remove via orgs.remove -- there is no
// in-place "replace", just remove-then-add).

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

    // API key (multi-org plan: a list of labeled org keys, not one key)
    @Published public private(set) var orgKeys: [OrgKeyInfo] = []

    // Add-key form
    @Published public var newKeyLabel: String = ""
    @Published public var newKeyInput: String = ""
    @Published public private(set) var isAddingKey = false
    /// Unified last-action status for the API-key tab, shared by
    /// `addKey`/`removeKey`/`renameKey` -- exactly one of the three
    /// mutators' outcomes at a time, never a mix. Every mutator clears this
    /// (via `resetKeyStatus`) before it does anything else, so a failed
    /// remove/rename can never leave a stale success checkmark from an
    /// earlier add, and a stale "Key saved and validated." can never persist
    /// across a later action.
    @Published public private(set) var keyStatusMessage: String?
    /// `true`/`false` for the last mutator's outcome, `nil` only for the
    /// "no key pasted yet" validation message (which isn't a server
    /// outcome at all). See `keyStatusMessage`.
    @Published public private(set) var keyAddSucceeded: Bool?
    /// Set after a successful Save & Validate when the new key lists a
    /// different set of Conductor projects than any existing key — a heads-up
    /// that it may belong to a different Conductor account (canonical-accounts).
    /// Reset to `false` at the start of every mutator along with the rest of
    /// the unified status.
    @Published public private(set) var keyProjectsChanged = false

    // Per-row rename affordance -- `renamingOrgId` is the row currently
    // showing its inline `TextField` instead of its label `Text` (nil when
    // no row is being renamed; only one row can be mid-rename at a time).
    @Published public var renamingOrgId: String?
    @Published public var renameLabelInput: String = ""

    // Per-row remove confirmation -- the row awaiting a
    // `.confirmationDialog` "are you sure" (nil when none pending).
    @Published public var pendingRemoveOrgId: String?

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
            loadError = nil
        } catch {
            loadError = "Couldn't load settings. Check your connection."
        }
        await loadOrgKeys()
        await loadSignedInIdentity()
        subscribeToProjects()
    }

    /// Refreshes the API-key tab's row list from `orgs:list` -- called on
    /// initial `load()` and after any add/remove/rename mutation succeeds.
    /// A transient failure here must not wipe an already-loaded list (the
    /// user would see their org keys vanish over a network blip), so on
    /// throw `orgKeys` is left exactly as it was and only the status message
    /// reports the failure.
    private func loadOrgKeys() async {
        do {
            orgKeys = try await convex.orgsList()
        } catch {
            keyStatusMessage = "Couldn't load your organization keys. Check your connection and try again."
            keyAddSucceeded = false
        }
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

    // MARK: API key management (multi-org plan: labeled org keys, masked)

    /// The dashboard URL for the add-key form's "Get your key at…" link.
    /// Always prod: a not-yet-added key's environment is unknown until
    /// `orgAddKey` probes it, unlike an existing row (which shows its own
    /// `environment` via `OrgKeyRow`).
    public var addKeyDashboardURL: URL {
        ConductorDashboardLink.apiKeysURL(environment: .prod)
    }

    public var addKeyDashboardLabel: String {
        ConductorDashboardLink.apiKeysLabel(environment: .prod)
    }

    /// Add flow (multi-org plan): one atomic call probes the pasted key
    /// against both Conductor hosts and, only on acceptance, stores it as a
    /// NEW labeled org row and seeds that org's projects cache server-side
    /// -- mirrors the old single-key `replaceKey`'s post-success refresh,
    /// except there's no existing row to replace, so this only ever adds.
    /// The different-project-set warning is preserved, still driven by the
    /// action's own `projectsChanged` signal.
    public func addKey() async {
        resetKeyStatus()
        let label = newKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = newKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyStatusMessage = "Paste the new key first."
            keyAddSucceeded = nil
            return
        }
        guard !isAddingKey else { return }
        isAddingKey = true
        defer { isAddingKey = false }

        let result: OrgAddKeyResult
        do {
            result = try await convex.orgAddKey(label: label.isEmpty ? "Default" : label, key: key)
        } catch {
            keyStatusMessage = "Couldn't reach Conductor. Check your connection and try again."
            keyAddSucceeded = false
            return
        }

        guard result.ok else {
            keyStatusMessage = result.error ?? "Conductor didn't accept that key. Check that you copied the whole key."
            keyAddSucceeded = false
            return
        }

        keyStatusMessage = "Key saved and validated."
        keyAddSucceeded = true
        keyProjectsChanged = result.projectsChanged ?? false
        newKeyLabel = ""
        newKeyInput = ""
        await loadOrgKeys()
    }

    /// Removes an org key -- mirrors `orgs:remove`. The view is responsible
    /// for confirming with the user first (`pendingRemoveOrgId` drives that
    /// dialog); this just performs the mutation and refreshes the list.
    public func removeKey(orgId: String) async {
        resetKeyStatus()
        do {
            try await convex.orgRemove(orgId: orgId)
            keyStatusMessage = "Key removed."
            keyAddSucceeded = true
            await loadOrgKeys()
        } catch {
            keyStatusMessage = "Couldn't remove that key. Check your connection and try again."
            keyAddSucceeded = false
        }
    }

    /// Begins the inline rename affordance for one row.
    public func beginRename(_ info: OrgKeyInfo) {
        renamingOrgId = info.orgId
        renameLabelInput = info.label
    }

    public func cancelRename() {
        renamingOrgId = nil
        renameLabelInput = ""
    }

    /// Commits `renameLabelInput` as the new label for `renamingOrgId` (a
    /// blank input is treated as "cancel", not "clear the label" -- an org
    /// key always keeps a non-empty label). Thin wrapper over `renameKey`
    /// that also tears down the inline-edit UI state.
    public func commitRename() async {
        guard let orgId = renamingOrgId else { return }
        let trimmed = renameLabelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingOrgId = nil
        renameLabelInput = ""
        guard !trimmed.isEmpty else { return }
        await renameKey(orgId: orgId, label: trimmed)
    }

    /// Renames an org key's label -- mirrors `orgs:rename`.
    public func renameKey(orgId: String, label: String) async {
        resetKeyStatus()
        do {
            try await convex.orgRename(orgId: orgId, label: label)
            keyStatusMessage = "Key renamed."
            keyAddSucceeded = true
            await loadOrgKeys()
        } catch {
            keyStatusMessage = "Couldn't rename that key. Check your connection and try again."
            keyAddSucceeded = false
        }
    }

    /// Clears the unified last-action status (message + success flag + the
    /// different-projects heads-up) at the start of every mutator
    /// (add/remove/rename) so a stale success checkmark from a PREVIOUS
    /// action can never survive into a later one that fails, and vice versa
    /// -- exactly one of these three is ever "the last thing that
    /// happened."
    private func resetKeyStatus() {
        keyStatusMessage = nil
        keyAddSucceeded = nil
        keyProjectsChanged = false
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
            Section("Conductor organizations") {
                if viewModel.orgKeys.isEmpty {
                    Text("No organization keys on file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.orgKeys, id: \.orgId) { info in
                        OrgKeyRow(info: info, viewModel: viewModel)
                    }
                }
            }

            Section("Add organization key") {
                TextField("Label", text: $viewModel.newKeyLabel, prompt: Text("Personal"))

                SecureField("New key", text: $viewModel.newKeyInput, prompt: Text("Paste a Conductor API key"))
                    .onSubmit { Task { await viewModel.addKey() } }

                HStack {
                    Link(
                        viewModel.addKeyDashboardLabel,
                        destination: viewModel.addKeyDashboardURL
                    )
                    .font(.callout)
                    Spacer()
                    Button {
                        Task { await viewModel.addKey() }
                    } label: {
                        if viewModel.isAddingKey {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save & Validate")
                        }
                    }
                    .disabled(viewModel.isAddingKey)
                }

                if let message = viewModel.keyStatusMessage {
                    Label(
                        message,
                        systemImage: viewModel.keyAddSucceeded == true
                            ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(viewModel.keyAddSucceeded == true ? Color.secondary : .orange)
                    .font(.callout)
                }

                if viewModel.keyProjectsChanged {
                    Label(
                        "This key can see a different set of Conductor projects than your existing keys. If that's unexpected, it may belong to a different Conductor account than the one you use in the Conductor app.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            // Which Conductor account(s) can these keys reach? There's no
            // Conductor whoami endpoint, so we show the projects as an
            // identity proxy — a mismatch with what the user expects is the
            // tell that captures will land in the wrong account.
            if !viewModel.orgKeys.isEmpty && !viewModel.projects.isEmpty {
                Section("Projects these keys can access") {
                    ForEach(viewModel.projects) { project in
                        if let orgLabel = project.orgLabel {
                            LabeledContent(project.name, value: orgLabel)
                        } else {
                            Text(project.name)
                        }
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

/// One row in the API-key tab's org list (multi-org plan): label + masked
/// key + env suffix, an inline pencil-to-`TextField` rename toggle, and a
/// Remove button gated by a `.confirmationDialog` (removing a key can fail
/// any capture currently in flight for that org).
private struct OrgKeyRow: View {
    let info: OrgKeyInfo
    @ObservedObject var viewModel: SettingsViewModel

    private var isRenaming: Bool { viewModel.renamingOrgId == info.orgId }

    /// Same "•••• last-4 · Staging" shape the old single-key
    /// `maskedKeyDisplay` used, just per-row now.
    private var maskedKey: String {
        let base = "••••••••••••\(info.lastFour)"
        return info.environment == .staging ? "\(base) · Staging" : base
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Label", text: $viewModel.renameLabelInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await viewModel.commitRename() } }
                } else {
                    Text(info.displayName)
                        .fontWeight(.semibold)
                }
                Text(maskedKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRenaming {
                Button("Save") { Task { await viewModel.commitRename() } }
                Button("Cancel") { viewModel.cancelRename() }
            } else {
                Button {
                    viewModel.beginRename(info)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button("Remove", role: .destructive) {
                    viewModel.pendingRemoveOrgId = info.orgId
                }
                .buttonStyle(.borderless)
            }
        }
        .confirmationDialog(
            "Remove this organization key?",
            isPresented: Binding(
                get: { viewModel.pendingRemoveOrgId == info.orgId },
                set: { isPresented in
                    if !isPresented { viewModel.pendingRemoveOrgId = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await viewModel.removeKey(orgId: info.orgId) }
                viewModel.pendingRemoveOrgId = nil
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingRemoveOrgId = nil
            }
        } message: {
            Text("Any captures currently in flight for this organization will fail. This can't be undone.")
        }
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
