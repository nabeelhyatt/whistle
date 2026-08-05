// TemplateEditor.swift
// Prompt-template editor (PRD F5.2/F5.3, TECH-SPEC §8, plan U10): plain
// text + variable legend + live preview via WhistleCore's `TemplatePreview`
// (kept output-identical to the backend promptRenderer.ts via the shared
// fixture file) + reset-to-default (`templates.reset`) + the LINT: an
// inline warning when the template's "How to end" contract block is
// missing — clarifying-question extraction (`pipeline.watch`, TECH-SPEC §6)
// silently breaks without it. The lint warns, it never blocks saving
// (plan U10: "saving is still allowed ... the warning persists until the
// block is restored").

import SwiftUI
import WhistleCore

// MARK: - Lint

/// Heuristic per PRD F5.2 / plan U10: the pipeline's question extraction
/// parses the agent's final message for the `"Clarifying questions:"`
/// marker that the default template's "How to end" contract block instructs
/// the agent to emit. A template that dropped that marker still renders and
/// submits fine — but questions come back empty, silently. Warn inline.
public enum TemplateLint {
    /// The load-bearing marker string from the default template's
    /// "How to end" section (packages/backend/convex/defaultTemplate.ts).
    public static let contractMarker = "Clarifying questions:"

    /// Returns an inline warning when the contract block is missing, `nil`
    /// when the template is fine.
    public static func warning(for body: String) -> String? {
        guard !body.contains(contractMarker) else { return nil }
        return "This template no longer asks the agent to end with a \"Clarifying questions:\" section — Whistle won't be able to extract clarifying questions from the agent's reply."
    }
}

// MARK: - View model

@MainActor
public final class TemplateEditorViewModel: ObservableObject {
    @Published public var body: String = ""
    @Published public private(set) var isCustomized = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var statusMessage: String?

    /// Inline lint warning (nil when the contract block is present). Pure
    /// function of `body`, so it warns live as the user types and clears
    /// the moment the block is restored.
    public var lintWarning: String? { TemplateLint.warning(for: body) }

    /// The documented `{{variables}}` legend (TECH-SPEC §8 contract, shared
    /// with the backend renderer).
    public static let variableLegend: [(token: String, description: String)] = [
        ("{{transcript}}", "The voice transcript"),
        ("{{notes}}", "Typed notes"),
        ("{{screenshot_url}}", "Screenshot URL (empty when none; wrap in {{#if screenshot_url}}…{{/if}})"),
        ("{{captured_at_iso}}", "Capture timestamp (ISO 8601)"),
        ("{{project_name}}", "The Conductor project name"),
        ("{{workspace_name}}", "The generated workspace name"),
    ]

    private let convex: any ConvexServiceProtocol

    public init(convex: any ConvexServiceProtocol) {
        self.convex = convex
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await convex.templatesGet()
            body = snapshot.body
            isCustomized = snapshot.isCustomized
        } catch {
            statusMessage = "Couldn't load the template. Check your connection and reopen Settings."
        }
    }

    /// Saves via `templates.update`. Lint warnings never block saving.
    public func save() async {
        do {
            try await convex.templatesUpdate(body: body)
            isCustomized = true
            statusMessage = "Saved."
        } catch {
            statusMessage = "Couldn't save the template. Please try again."
        }
    }

    /// Resets via `templates.reset`, then reloads so the editor shows the
    /// restored default body.
    public func reset() async {
        do {
            try await convex.templatesReset()
            await load()
            statusMessage = "Restored the default template."
        } catch {
            statusMessage = "Couldn't reset the template. Please try again."
        }
    }

    /// Live preview rendered with sample values through the SAME renderer
    /// contract the backend uses (WhistleCore `TemplatePreview`, §8).
    public func preview() -> String {
        TemplatePreview.render(
            template: body,
            vars: TemplateVariables(
                transcript: "we should add fuzzy search to the history window",
                notes: "saw a user scroll for ages looking for an old capture",
                screenshotUrl: "https://example.convex.cloud/storage/sample-screenshot",
                capturedAtIso: "2026-07-08T09:30:00Z",
                projectName: "whistle",
                workspaceName: "Fuzzy search in history #a1b2c3"
            )
        )
    }
}

// MARK: - Editor view

struct TemplateEditorView: View {
    @ObservedObject var viewModel: TemplateEditorViewModel
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt template")
                .font(.headline)
            Text("This is the planning prompt Whistle sends to the Conductor agent with every capture. It follows your account, so future clients use it too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = viewModel.lintWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.12)))
                    .accessibilityIdentifier("templateLintWarning")
            }

            TextEditor(text: $viewModel.body)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))

            DisclosureGroup("Variables") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(TemplateEditorViewModel.variableLegend, id: \.token) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.token)
                                .font(.system(.callout, design: .monospaced))
                            Text(entry.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }

            DisclosureGroup("Live preview (sample capture)", isExpanded: $showPreview) {
                ScrollView {
                    Text(viewModel.preview())
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4)))
            }

            HStack {
                Button("Reset to default") {
                    Task { await viewModel.reset() }
                }
                Spacer()
                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Save template") {
                    Task { await viewModel.save() }
                }
            }
        }
        .task { await viewModel.load() }
    }
}
