// Prompt template rendering — TECH-SPEC §8.
//
// Literal `{{var}}` substitution (no logic), plus exactly one supported
// conditional block: `{{#if screenshot_url}}...{{/if}}`. This is intentionally
// NOT a template engine — a ~10-line regex implementation is the spec.
//
// Output must be byte-identical to WhistleCore's Swift `TemplatePreview`
// (client-side settings preview) for the same inputs — both are exercised
// against the shared fixture at
// packages/backend/convex/__tests__/fixtures/template-rendering.json.

export interface TemplateVars {
  transcript: string;
  notes: string;
  screenshot_url: string;
  captured_at_iso: string;
  project_name: string;
  workspace_name: string;
  // Not part of the documented six-variable contract (TECH-SPEC §8 /
  // PROMPT-TEMPLATE.md), but templates may reference `{{model}}` freely —
  // any var absent from this map simply renders as "" (see the fixture's
  // "missing var" case). Allow arbitrary extra keys defensively.
  [key: string]: string | undefined;
}

const IF_SCREENSHOT_BLOCK_RE =
  /\{\{#if screenshot_url\}\}([\s\S]*?)\{\{\/if\}\}/g;

const VAR_RE = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g;

/**
 * Renders a Whistle prompt template. Two passes:
 * 1. Resolve every `{{#if screenshot_url}}...{{/if}}` block: keep the inner
 *    content (with its own `{{var}}`s substituted in the second pass) when
 *    `screenshot_url` is a non-empty string, otherwise drop the whole block.
 * 2. Literal `{{var}}` substitution across the remaining text. A variable not
 *    present in `vars` (or explicitly undefined) substitutes as "". Any other
 *    `{{...}}`-shaped text (e.g. `{{mustache}}` inside user transcript/notes)
 *    is untouched — the regex only matches bare-identifier variable names,
 *    and even then only real substitution happens per pass; unknown-looking
 *    user text that happens to look like a var is only a risk for the six
 *    known variables plus whatever the template author intentionally wrote,
 *    which is accepted per §8 (no escaping mechanism specified).
 */
export function renderTemplate(template: string, vars: TemplateVars): string {
  const withConditionalsResolved = template.replace(
    IF_SCREENSHOT_BLOCK_RE,
    (_match, inner: string) => {
      return vars.screenshot_url && vars.screenshot_url.length > 0
        ? inner
        : "";
    },
  );

  return withConditionalsResolved.replace(VAR_RE, (match, name: string) => {
    const value = vars[name];
    return value !== undefined ? value : "";
  });
}
