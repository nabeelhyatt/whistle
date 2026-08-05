// ProjectPicker.swift
// Project picker for the capture panel (TECH-SPEC §4.1 `CaptureView` row,
// PRD F1.5): populated from `CaptureStore`'s projects snapshot (offline-
// friendly), defaults to last-used, searchable once there are more than 8
// projects.

import SwiftUI
import WhistleCore

struct ProjectPicker: View {
    /// Presentation style -- `.standard` is the original searchable
    /// `Picker` (kept for any other host); `.rail` is the capture-panel-
    /// redesign spec's departure-board look (file change #4/ProjectPicker
    /// section): a borderless `Menu` labeled "TO: <NAME>". Both styles
    /// share the same `selectedProjectId` binding and `selectProject`
    /// persistence flow -- only the presentation forks, never the
    /// selection logic.
    enum Style {
        case standard
        case rail
    }

    let projects: [Project]
    @Binding var selectedProjectId: String?
    /// Set by `CaptureViewModel` on the "Duplicate as new capture" pre-fill
    /// path (plan U8) so the field can request first-responder focus.
    var isFocused: FocusState<Bool>.Binding?
    var style: Style = .standard

    @State private var searchText: String = ""

    private var isSearchable: Bool { projects.count > 8 }

    private var filteredProjects: [Project] {
        guard isSearchable, !searchText.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedProject: Project? {
        projects.first(where: { $0.id == selectedProjectId })
    }

    var body: some View {
        switch style {
        case .standard:
            standardBody
        case .rail:
            railBody
        }
    }

    @ViewBuilder
    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSearchable {
                TextField("Search projects…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Project", selection: $selectedProjectId) {
                if projects.isEmpty {
                    Text("No projects").tag(String?.none)
                }
                ForEach(filteredProjects) { project in
                    Text(project.name).tag(String?.some(project.id))
                }
            }
            .labelsHidden()
            .disabled(projects.isEmpty)
        }
    }

    /// Rail presentation: "TO: <PROJECT NAME>" in the destination style
    /// (monospaced bold ~10.5pt, tracking ~0.22em, amber instrumentation
    /// accent) -- a borderless `Menu` so it reads as a departure-board
    /// destination rather than a form control.
    private var railBody: some View {
        Menu {
            let groups = ProjectPicker.groupedByOrg(projects)
            if ProjectPicker.distinctOrgLabelCount(projects) > 1 {
                ForEach(groups) { group in
                    if let orgLabel = group.orgLabel {
                        Section(orgLabel) {
                            ForEach(group.projects) { project in
                                Button(project.name) {
                                    selectedProjectId = project.id
                                }
                            }
                        }
                    } else {
                        ForEach(group.projects) { project in
                            Button(project.name) {
                                selectedProjectId = project.id
                            }
                        }
                    }
                }
            } else {
                ForEach(projects) { project in
                    Button(project.name) {
                        selectedProjectId = project.id
                    }
                }
            }
        } label: {
            Text("TO: \((selectedProject?.name ?? "—").uppercased())")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .tracking(2.3)
                .foregroundColor(PanelTheme.accentAmber)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        // Vertical-only: the label must stay one line but accept horizontal
        // compression so a long project name truncates in place instead of
        // widening the status rail (PR #5 review).
        .fixedSize(horizontal: false, vertical: true)
        .disabled(projects.isEmpty)
        .modifier(OptionalFocused(isFocused: isFocused))
    }

    // MARK: - Org grouping (multi-org plan, rail style only)

    /// One `Section`'s worth of projects sharing an `orgLabel` -- `orgLabel`
    /// is `nil` for the leading group of legacy projects that predate
    /// multi-org (no header rendered for that group, see `railBody`).
    struct ProjectOrgGroup: Identifiable {
        let orgLabel: String?
        let projects: [Project]

        /// `orgLabel` is already unique across groups (see `groupedByOrg`),
        /// so it doubles as a stable `Identifiable` key; the leading
        /// unlabeled group uses a sentinel since two `nil`s can't collide
        /// anyway.
        var id: String { orgLabel ?? "__unlabeled__" }
    }

    /// Buckets `projects` by `orgLabel`, preserving the list's existing
    /// order (a group's position is set by its label's first appearance);
    /// projects with a `nil` `orgLabel` (legacy, pre-multi-org) are
    /// collected into an unlabeled leading group. Pure function so it's
    /// unit-testable without standing up any SwiftUI.
    static func groupedByOrg(_ projects: [Project]) -> [ProjectOrgGroup] {
        var order: [String?] = []
        var buckets: [String?: [Project]] = [:]
        for project in projects {
            if buckets[project.orgLabel] == nil {
                order.append(project.orgLabel)
            }
            buckets[project.orgLabel, default: []].append(project)
        }
        // Keep the unlabeled group leading regardless of where it first
        // appeared, per spec ("Projects with nil orgLabel ... go in an
        // unlabeled leading group").
        var orderedLabels = order
        if let nilIndex = orderedLabels.firstIndex(where: { $0 == nil }) {
            orderedLabels.remove(at: nilIndex)
            orderedLabels.insert(nil, at: 0)
        }
        return orderedLabels.map { label in
            ProjectOrgGroup(orgLabel: label, projects: buckets[label] ?? [])
        }
    }

    /// Count of distinct non-nil `orgLabel`s -- the gate for whether
    /// `railBody` sections the menu at all (spec: only when >1).
    static func distinctOrgLabelCount(_ projects: [Project]) -> Int {
        Set(projects.compactMap(\.orgLabel)).count
    }
}

/// Applies `.focused(_:)` only when a `FocusState` binding was actually
/// supplied -- `ProjectPicker`'s `isFocused` is optional (only set on the
/// duplicate-as-new-capture pre-fill path).
private struct OptionalFocused: ViewModifier {
    let isFocused: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let isFocused {
            content.focused(isFocused)
        } else {
            content
        }
    }
}
