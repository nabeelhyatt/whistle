# Whistle — default prompt template

This is the planning prompt Whistle sends as the first message to the Conductor workspace agent. It's a compact, headless briefing: interpret the captured idea, research the codebase, and produce a right-sized plan (or a short note/memo when a full plan isn't warranted) ending with clarifying questions — since the workspace agent runs with no user present, there's no back-and-forth. It works on any repo with no plugin, skill, or tool dependencies. Source of truth at runtime: `packages/backend/convex/defaultTemplate.ts` (this file is documentation; keep them in sync).

Users can edit the template in Settings. Rendering is literal `{{var}}` substitution plus a single `{{#if screenshot_url}}...{{/if}}` conditional (see TECH-SPEC §8).

## Variables

| Variable | Value |
|---|---|
| `{{transcript}}` | Edited voice transcript (may be empty) |
| `{{notes}}` | Typed notes (may be empty) |
| `{{screenshot_url}}` | Convex file URL, or empty |
| `{{captured_at_iso}}` | Capture timestamp, ISO-8601 with timezone |
| `{{project_name}}` | Conductor project name |
| `{{workspace_name}}` | Server-generated workspace name (see TECH-SPEC §6 naming) |

## Design notes

- **Gate before planning.** Step 3 checks whether the idea concerns this repo at all, and whether it's already built or already planned in `docs/plans/`. If so, a short note pointing at what was found *is* the deliverable — not a fabricated plan.
- **Right-sized output, not a fixed template.** Step 4 asks for a plan "sized to the idea" instead of prescribing a section-by-section structure (no R-ID/U-ID machinery) — a thin or ambiguous capture gets an interpretation memo instead of an over-specified plan.
- **Headless conventions preserved.** No blocking questions mid-run; assumptions are labeled instead, and the run always ends with a numbered "Clarifying questions:" section the pipeline parses back into the app.
- **NEVER CODE** and repo-relative-paths-only remain hard rules.
- Whistle-specific additions: the voice-transcript mis-hearing caveat (on-device STT garbles jargon; reconcile against real code names) and the screenshot-fetch instruction (Conductor messages are text-only, so the image arrives as a URL to curl).

## Default template

```markdown
# Idea capture → plan request

A user captured a fleeting product idea at {{captured_at_iso}}, aimed at the project "{{project_name}}". Research this codebase and turn the idea into a reviewable plan document — **without implementing anything** — ending with clarifying questions for the user.

**Voice transcript** (machine-transcribed; product and code names may be mis-heard — reconcile every term against the actual codebase):

> {{transcript}}

**Typed notes:**

> {{notes}}

{{#if screenshot_url}}
**Screenshot** from the moment of capture. Download and view it before researching: `curl -sL -o /tmp/whistle-capture.jpg "{{screenshot_url}}"`, then read it as an image. It shows whatever was on screen — weigh it as one input among several, not the definitive context.
{{/if}}

## What to do

1. **Interpret.** State in a sentence what you believe the user is asking for. If ambiguous, pick the most plausible reading given this codebase and record alternatives as assumptions.
2. **Research.** Find the relevant files, entry points, existing patterns, and prior art. Read any repo guidance that applies (AGENTS.md, CLAUDE.md, docs/solutions/, docs/plans/).
3. **Gate.** If the idea doesn't concern this repo, or is already implemented or already planned in docs/plans/, write a few-sentence note pointing at what you found — that note is the whole deliverable. If the input is too thin or ambiguous for one confident interpretation, write a short interpretation memo (best readings with evidence, what to clarify) instead of inventing scope.
4. **Write the plan.** Follow the repo's planning convention if one exists; otherwise create `docs/plans/<YYYY-MM-DD>-<NNN>-<feat|fix|refactor>-<3-5-word-slug>-plan.md` with YAML frontmatter `title`, `type`, `status: active`, `date` (the note and memo above use the same convention). Cover, sized to the idea: summary, assumptions (this ran without user confirmation — flag every material inference), approach and key technical decisions, implementation steps with the files they touch and how to verify them, explicit non-goals, and risks. Don't pad.
5. **Commit** the document to the working branch. Change nothing else.

## Rules

- NEVER write implementation code — capture decisions, files, and test scenarios; the plan (or note/memo) is the only change you commit.
- Don't ask blocking questions mid-run; make labeled assumptions and keep going.
- Ground every claim in files you actually read; repo-relative paths only.

## How to end

End your final message with:
1. A 2–3 sentence summary of what you found and what you're proposing (or why no plan was needed).
2. The repo-relative path of the document you wrote.
3. **"Clarifying questions:"** followed by a numbered list of the 3–5 questions whose answers would most change the plan, each answerable in one line. This section is parsed by the tool that sent this message — include it in this exact form in every case, including notes and memos.
```

## Workspace naming

Workspace names are generated **server-side in the pipeline** (TECH-SPEC §6), not by the app: a Claude Haiku call produces a 3–5 word, noun-first title from the transcript/notes/project (`titleGenerator.ts`); the pipeline appends ` #<clientId prefix>` — e.g. `Capture panel redesign #a1b2c3`. If title generation is unavailable (no `ANTHROPIC_API_KEY`, a non-200 response, or a timeout) it falls back to `<first ~6 meaningful words of notes-or-transcript> #<clientId prefix>`, and further to `Screenshot capture <date> #<clientId prefix>` for screenshot-only captures. The `#<clientId>` tag is always present and load-bearing (orphan-workspace adoption on retry) — custom templates may change the prompt freely, but naming is not template-controlled.
