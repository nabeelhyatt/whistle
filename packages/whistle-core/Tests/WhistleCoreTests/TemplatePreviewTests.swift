// TemplatePreviewTests.swift
// Runs TemplatePreview.render against every case in the shared fixture file
// (packages/backend/convex/__tests__/fixtures/template-rendering.json,
// symlinked into this test target's Fixtures/ dir) so the client-side
// preview stays byte-for-byte identical to the backend promptRenderer.ts
// for the same inputs (plan U5: "Renderer preview: matches backend renderer
// output for the same inputs (shared fixture file)").

import Foundation
import XCTest
@testable import WhistleCore

final class TemplatePreviewTests: XCTestCase {
    private struct FixtureCase: Decodable {
        struct Input: Decodable {
            let template: String
            let vars: Vars
        }
        struct Vars: Decodable {
            let transcript: String?
            let notes: String?
            let screenshot_url: String?
            let captured_at_iso: String?
            let project_name: String?
            let workspace_name: String?
        }
        let description: String
        let input: Input
        let expected: String
    }

    /// Loads the shared fixture file directly from its canonical source path
    /// (rather than via `Bundle.module`): SPM's resource-copy step does not
    /// dereference the `Fixtures/template-rendering.json` symlink relative
    /// to the bundle's own location, so `Bundle.module` lookups fail at test
    /// run time even though the symlink resolves fine on disk. Using
    /// `#filePath` to locate this source file, then walking up to the
    /// shared fixture, sidesteps that bundling quirk entirely while still
    /// reading the exact same file U3's backend tests consume.
    private func loadFixtures() throws -> [FixtureCase] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = thisFile
            .deletingLastPathComponent() // WhistleCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // whistle-core/
            .deletingLastPathComponent() // packages/
            .appendingPathComponent("backend/convex/__tests__/fixtures/template-rendering.json")
        let resolvedURL = fixtureURL.resolvingSymlinksInPath()
        let data = try Data(contentsOf: resolvedURL)
        return try JSONDecoder().decode([FixtureCase].self, from: data)
    }

    func testAllSharedFixtureCases() throws {
        let fixtures = try loadFixtures()
        XCTAssertFalse(fixtures.isEmpty, "fixture file should not be empty")

        for fixture in fixtures {
            let vars = TemplateVariables(
                transcript: fixture.input.vars.transcript ?? "",
                notes: fixture.input.vars.notes ?? "",
                screenshotUrl: fixture.input.vars.screenshot_url ?? "",
                capturedAtIso: fixture.input.vars.captured_at_iso ?? "",
                projectName: fixture.input.vars.project_name ?? "",
                workspaceName: fixture.input.vars.workspace_name ?? ""
            )
            let rendered = TemplatePreview.render(template: fixture.input.template, vars: vars)
            XCTAssertEqual(rendered, fixture.expected, "fixture case failed: \(fixture.description)")
        }
    }

    // MARK: - Direct unit tests covering the same contract, independent of
    // the fixture file (defense in depth if the fixture file is ever
    // trimmed down).

    func testAllSixVariablesSubstitute() {
        let vars = TemplateVariables(
            transcript: "T", notes: "N", screenshotUrl: "https://x/y",
            capturedAtIso: "2026-01-01T00:00:00.000Z", projectName: "P", workspaceName: "W"
        )
        let template = "{{transcript}}-{{notes}}-{{screenshot_url}}-{{captured_at_iso}}-{{project_name}}-{{workspace_name}}"
        XCTAssertEqual(
            TemplatePreview.render(template: template, vars: vars),
            "T-N-https://x/y-2026-01-01T00:00:00.000Z-P-W"
        )
    }

    func testEmptyScreenshotUrlRemovesIfBlock() {
        let vars = TemplateVariables(transcript: "", notes: "", screenshotUrl: "", capturedAtIso: "", projectName: "", workspaceName: "")
        let template = "before {{#if screenshot_url}}SHOULD NOT APPEAR{{/if}} after"
        XCTAssertEqual(TemplatePreview.render(template: template, vars: vars), "before  after")
    }

    func testNonEmptyScreenshotUrlKeepsIfBlockContent() {
        let vars = TemplateVariables(transcript: "", notes: "", screenshotUrl: "https://x", capturedAtIso: "", projectName: "", workspaceName: "")
        let template = "before {{#if screenshot_url}}URL is {{screenshot_url}}{{/if}} after"
        XCTAssertEqual(TemplatePreview.render(template: template, vars: vars), "before URL is https://x after")
    }

    func testLiteralDoubleBraceTextPassesThroughUntouched() {
        // `{{` that isn't shaped like a recognized `{{identifier}}` token
        // (e.g. contains a space, or never closes with `}}`) passes through
        // the substitution pass untouched — this is what lets user-authored
        // template text mention "mustache-style {{ }} syntax" literally.
        let vars = TemplateVariables(transcript: "T", notes: "", screenshotUrl: "", capturedAtIso: "", projectName: "", workspaceName: "")
        let template = "raw braces {{ not a var } {{transcript}}"
        XCTAssertEqual(TemplatePreview.render(template: template, vars: vars), "raw braces {{ not a var } T")
    }

    func testUserContentContainingMustacheSyntaxIsCopiedVerbatimAsAVariableValue() {
        // The fixture's "literal {{ in user text" case: because transcript/
        // notes are substituted AS VALUES (not re-scanned for {{}}), any
        // {{...}} inside the transcript/notes strings themselves survives
        // in the output exactly as typed.
        let vars = TemplateVariables(
            transcript: "the config uses {{mustache}} syntax literally",
            notes: "", screenshotUrl: "", capturedAtIso: "", projectName: "", workspaceName: ""
        )
        let template = "Transcript: {{transcript}}"
        XCTAssertEqual(
            TemplatePreview.render(template: template, vars: vars),
            "Transcript: the config uses {{mustache}} syntax literally"
        )
    }

    func testMissingVarSubstitutesEmptyString() {
        let vars = TemplateVariables(transcript: "", notes: "", screenshotUrl: "", capturedAtIso: "", projectName: "P", workspaceName: "")
        // "model" is not one of the six known template variables.
        let template = "{{project_name}}:{{model}}"
        XCTAssertEqual(TemplatePreview.render(template: template, vars: vars), "P:")
    }
}
