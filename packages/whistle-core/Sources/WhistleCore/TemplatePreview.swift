// TemplatePreview.swift
// Client-side renderer per TECH-SPEC §8: literal {{var}} substitution plus a
// single {{#if screenshot_url}}...{{/if}} conditional, implemented as a small
// regex — not a template engine. Output must byte-for-byte match the backend
// renderer (packages/backend/convex/promptRenderer.ts) for the same inputs;
// both consume the shared fixture file at
// packages/backend/convex/__tests__/fixtures/template-rendering.json.

import Foundation

/// The six template variables (TECH-SPEC §8), shared contract between the
/// backend renderer and the settings-UI legend.
public struct TemplateVariables: Equatable, Sendable {
    public var transcript: String
    public var notes: String
    /// Empty string when there is no screenshot — this is what makes the
    /// `{{#if screenshot_url}}` block disappear.
    public var screenshotUrl: String
    public var capturedAtIso: String
    public var projectName: String
    public var workspaceName: String

    public init(
        transcript: String,
        notes: String,
        screenshotUrl: String,
        capturedAtIso: String,
        projectName: String,
        workspaceName: String
    ) {
        self.transcript = transcript
        self.notes = notes
        self.screenshotUrl = screenshotUrl
        self.capturedAtIso = capturedAtIso
        self.projectName = projectName
        self.workspaceName = workspaceName
    }

    /// Look up a variable by its `{{name}}` key. Unknown/missing variables
    /// resolve to empty string (TECH-SPEC §8 / plan U5 fixture case).
    func value(for name: String) -> String {
        switch name {
        case "transcript": return transcript
        case "notes": return notes
        case "screenshot_url": return screenshotUrl
        case "captured_at_iso": return capturedAtIso
        case "project_name": return projectName
        case "workspace_name": return workspaceName
        default: return ""
        }
    }
}

public enum TemplatePreview {
    /// Matches `{{#if screenshot_url}}...{{/if}}` blocks. Non-greedy body,
    /// dot matches newlines (`.dotMatchesLineSeparators`) since template
    /// bodies are multi-line markdown.
    private static let ifBlockRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "\\{\\{#if screenshot_url\\}\\}(.*?)\\{\\{/if\\}\\}",
            options: [.dotMatchesLineSeparators]
        )
    }()

    /// Matches a literal `{{var_name}}` token (word chars/underscore only,
    /// so `{{` appearing in user text without a matching `}}var}}` shape
    /// passes through untouched).
    private static let variableRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\{\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}\\}", options: [])
    }()

    /// Renders `template` against `vars`, matching the backend
    /// `promptRenderer.ts` behavior exactly:
    /// 1. Resolve every `{{#if screenshot_url}}...{{/if}}` block: keep the
    ///    inner content when `screenshotUrl` is non-empty, drop the whole
    ///    block (including delimiters) when it is empty.
    /// 2. Substitute every `{{var}}` token literally. Unknown/missing
    ///    variables become empty string. This pass does not touch `{{`
    ///    sequences that aren't a recognized `{{identifier}}` token, so
    ///    literal mustache-like text in user-authored transcript/notes
    ///    passes through untouched.
    public static func render(template: String, vars: TemplateVariables) -> String {
        let afterConditional = resolveConditionalBlocks(in: template, screenshotUrl: vars.screenshotUrl)
        return substituteVariables(in: afterConditional, vars: vars)
    }

    private static func resolveConditionalBlocks(in template: String, screenshotUrl: String) -> String {
        let fullRange = NSRange(template.startIndex..., in: template)
        let keepBlock = !screenshotUrl.isEmpty

        var result = ""
        var lastEnd = template.startIndex

        ifBlockRegex.enumerateMatches(in: template, options: [], range: fullRange) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: template) else { return }
            result += template[lastEnd..<matchRange.lowerBound]
            if keepBlock, let innerRange = Range(match.range(at: 1), in: template) {
                result += template[innerRange]
            }
            lastEnd = matchRange.upperBound
        }
        result += template[lastEnd...]
        return result
    }

    private static func substituteVariables(in template: String, vars: TemplateVariables) -> String {
        let fullRange = NSRange(template.startIndex..., in: template)
        var result = ""
        var lastEnd = template.startIndex

        variableRegex.enumerateMatches(in: template, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  let matchRange = Range(match.range, in: template),
                  let nameRange = Range(match.range(at: 1), in: template)
            else { return }
            result += template[lastEnd..<matchRange.lowerBound]
            result += vars.value(for: String(template[nameRange]))
            lastEnd = matchRange.upperBound
        }
        result += template[lastEnd...]
        return result
    }
}
