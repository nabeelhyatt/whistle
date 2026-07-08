import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { renderTemplate, type TemplateVars } from "../promptRenderer";

interface FixtureCase {
  description: string;
  input: { template: string; vars: TemplateVars };
  expected: string;
}

const fixturePath = fileURLToPath(
  new URL("./fixtures/template-rendering.json", import.meta.url),
);
const fixtures: FixtureCase[] = JSON.parse(readFileSync(fixturePath, "utf8"));

describe("renderTemplate — shared fixture (packages/backend/convex/__tests__/fixtures/template-rendering.json)", () => {
  for (const fixture of fixtures) {
    test(fixture.description, () => {
      const actual = renderTemplate(fixture.input.template, fixture.input.vars);
      expect(actual).toBe(fixture.expected);
    });
  }
});

describe("renderTemplate — additional direct cases", () => {
  test("all six documented variables substitute correctly together", () => {
    const template =
      "{{transcript}}|{{notes}}|{{screenshot_url}}|{{captured_at_iso}}|{{project_name}}|{{workspace_name}}";
    const out = renderTemplate(template, {
      transcript: "t",
      notes: "n",
      screenshot_url: "https://example.com/s.jpg",
      captured_at_iso: "2026-07-04T00:00:00.000Z",
      project_name: "Whistle",
      workspace_name: "idea: t #abcdef",
    });
    expect(out).toBe(
      "t|n|https://example.com/s.jpg|2026-07-04T00:00:00.000Z|Whistle|idea: t #abcdef",
    );
  });

  test("literal {{ in user text passes through untouched even outside the fixture's exact case", () => {
    const out = renderTemplate("Notes: {{notes}}", {
      transcript: "",
      notes: "curly braces like {{this}} should survive",
      screenshot_url: "",
      captured_at_iso: "",
      project_name: "",
      workspace_name: "",
    });
    expect(out).toBe("Notes: curly braces like {{this}} should survive");
  });

  test("empty screenshot_url removes the #if block even when it spans multiple lines", () => {
    const template =
      "before\n{{#if screenshot_url}}\nline one\nline two\n{{/if}}\nafter";
    const out = renderTemplate(template, {
      transcript: "",
      notes: "",
      screenshot_url: "",
      captured_at_iso: "",
      project_name: "",
      workspace_name: "",
    });
    expect(out).toBe("before\n\nafter");
  });
});
