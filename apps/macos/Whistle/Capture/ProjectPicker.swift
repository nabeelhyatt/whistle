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
            ForEach(projects) { project in
                Button(project.name) {
                    selectedProjectId = project.id
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
