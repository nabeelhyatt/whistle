// ProjectPicker.swift
// Project picker for the capture panel (TECH-SPEC §4.1 `CaptureView` row,
// PRD F1.5): populated from `CaptureStore`'s projects snapshot (offline-
// friendly), defaults to last-used, searchable once there are more than 8
// projects.

import SwiftUI
import WhistleCore

struct ProjectPicker: View {
    let projects: [Project]
    @Binding var selectedProjectId: String?
    /// Set by `CaptureViewModel` on the "Duplicate as new capture" pre-fill
    /// path (plan U8) so the field can request first-responder focus.
    var isFocused: FocusState<Bool>.Binding?

    @State private var searchText: String = ""

    private var isSearchable: Bool { projects.count > 8 }

    private var filteredProjects: [Project] {
        guard isSearchable, !searchText.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
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
}
