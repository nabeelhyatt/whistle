# Whistle — default prompt template

This is the planning prompt Whistle sends as the first message to the Conductor workspace agent. It is a **self-contained, headless adaptation of the compound-engineering `ce-plan` module** (v3.8.0) — the methodology, plan template, naming convention, and quality bar are carried over faithfully; the interactive machinery (blocking questions, sub-agent dispatch, post-generation menus) is replaced with headless conventions (labeled assumptions + end-of-run clarifying questions), since the workspace agent runs with no user present. It works on any repo with no plugin, skill, or tool dependencies. Source of truth at runtime: `packages/backend/convex/defaultTemplate.ts` (this file is documentation; keep them in sync).

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

## Design notes (mapping to ce-plan)

| ce-plan element | How the template carries it |
|---|---|
| Core principles (decisions-not-code, research-before-structuring, right-size the artifact, separate planning-time from execution-time unknowns) | Stated verbatim as "Planning principles" the agent must follow. |
| Plan file convention `docs/plans/YYYY-MM-DD-NNN-<type>-<slug>-plan.md` + frontmatter (`title`, `type`, `status`, `date`) | Instructed directly; repo-local conventions win if they differ. |
| Plan quality bar & core template sections | The "Write the plan document" section mirrors ce-plan's template: Summary, Problem Frame, Assumptions, Requirements (R-IDs), Scope Boundaries, Context & Research, Key Technical Decisions, Open Questions (resolved vs deferred), Implementation Units (U-IDs with goal/files/approach/test scenarios/verification), System-Wide Impact, Risks. |
| Test scenario categories (happy path, edge, error, integration) | Required per feature-bearing unit. |
| Headless mode (`## Assumptions` = un-validated agent bets; no blocking questions) | Required section + hard rule; ce-plan's own headless convention. |
| Phase 0 bootstrap / depth assessment | Compressed into "Interpret" + "right-size the plan" guidance. |
| NEVER CODE rule | Carried as a hard rule. |

Additional Whistle-specific elements: the voice-transcript mis-hearing caveat (on-device STT garbles jargon; reconcile against real code names) and the screenshot-fetch instruction (Conductor messages are text-only, so the image arrives as a URL to curl).

## Default template

```markdown
# Idea capture → plan request

You are starting a planning session. A user captured a fleeting product idea with a quick-capture tool at {{captured_at_iso}}, aimed at the project "{{project_name}}". Your job is to research this codebase and turn the idea into a durable, reviewable plan document — **without implementing anything** — ending with clarifying questions for the user to answer when they open this workspace.

## The captured idea

**Voice transcript** (machine-transcribed on-device; may contain mis-heard words, especially product and code names — reconcile every term against the actual codebase before trusting it):

> {{transcript}}

**Typed notes:**

> {{notes}}

{{#if screenshot_url}}
**Screenshot** taken at the moment of capture (the user's screen — likely the app area or context the idea refers to). Download and view it before researching:

    curl -sL -o /tmp/whistle-capture.jpg "{{screenshot_url}}"

Then read /tmp/whistle-capture.jpg as an image and treat its contents as primary context for interpreting the idea.
{{/if}}

## Planning principles (follow these)

1. **Decisions, not code.** Capture approach, boundaries, files, dependencies, risks, and test scenarios. Do not pre-write implementation code. Pseudo-code or a small diagram is welcome when it communicates design direction — frame it as directional guidance, not specification.
2. **Research before structuring.** Explore the codebase first; ground every claim in files you actually read. Use repo-relative paths everywhere — never absolute paths.
3. **Right-size the artifact.** A small, well-bounded idea gets a compact plan (2–4 implementation units); a cross-cutting one gets more structure (4–8 units). Do not pad.
4. **Separate planning-time from execution-time unknowns.** Resolve what is knowable from the repo now; explicitly defer what depends on running code, and say why.
5. **A plan is ready when an implementer can start confidently without the plan writing the code for them.**

## What to do

1. **Interpret.** State in one or two sentences what you believe the user is asking for. If the transcript is ambiguous, choose the most plausible reading given this codebase and record the alternatives as assumptions.
2. **Research the codebase.** Find the feature area the idea concerns: relevant files, entry points, data flow, existing patterns, tests, TODOs, and prior art. If the repo has institutional learnings (e.g. `docs/solutions/`) or agent guidance (`AGENTS.md`, `CLAUDE.md`), read what's relevant.
3. **Honor repo conventions.** If this repo already has a planning convention (e.g. a `docs/plans/` directory with dated plans, a plan template, or a compound-engineering setup), follow it exactly — matching its frontmatter and naming. Otherwise create:
   `docs/plans/<YYYY-MM-DD>-<NNN>-<feat|fix|refactor>-<3-5-word-slug>-plan.md`
   (NNN = next sequence number for today, zero-padded), with YAML frontmatter: `title`, `type`, `status: active`, `date`.
4. **Write the plan document** with these sections (omit any that genuinely add nothing; keep horizontal rules between sections):
   - **Summary** — what is being proposed, 1–3 lines, forward-looking.
   - **Problem Frame** — the user/business pain motivating it.
   - **Assumptions** — *required, headless mode.* Open with: "This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds." Then list every material inference: your interpretation of the transcript, scope choices, technical bets.
   - **Requirements** — numbered R-IDs (R1, R2…) stating success criteria.
   - **Scope Boundaries** — explicit non-goals; put tangential "while we're here" cleanups under a `### Deferred to Follow-Up Work` subsection, not in the active units.
   - **Context & Research** — the relevant code you found: files, patterns to follow, current behavior (with measurements when the idea concerns performance and reading code suffices — do not run load tests).
   - **Key Technical Decisions** — each with rationale.
   - **Implementation Units** — level-3 headings `### U1. Name` with stable U-IDs, dependency-ordered. Each unit: **Goal**, **Requirements** (cite R-IDs), **Dependencies** (cite U-IDs), **Files** (create/modify/test, repo-relative), **Approach** (key decisions, not code), **Patterns to follow** (existing files), **Test scenarios** (specific input → action → expected outcome; cover happy path, edge cases, error paths, and integration where each applies; for non-feature units write `Test expectation: none — <reason>`), **Verification** (outcomes, not shell scripts).
   - **System-Wide Impact** — affected entry points, error propagation, state/lifecycle risks — when the change is cross-cutting.
   - **Risks** — with mitigations.
   - **Open Questions** — split "Resolved during planning" (with resolutions) from "Deferred to implementation" (with why).
5. **Commit** the plan document to the working branch with a clear message. Change nothing else.

## Hard rules

- NEVER CODE. Do not implement the feature, refactor, or modify anything other than adding the plan document.
- Do not ask blocking questions mid-run; make labeled assumptions and keep going.
- Ground every claim about the codebase in files you actually read; never invent paths or behavior.
- All file references repo-relative.

## How to end

End your final message with:
1. A 2–3 sentence summary of what you found and what you're proposing.
2. The repo-relative path of the plan document you wrote.
3. **"Clarifying questions:"** followed by a numbered list of the 3–5 highest-leverage questions whose answers would most change the plan — specific, answerable in one line each, drawn from your Assumptions section. If you genuinely have none, say so explicitly.
```

## Workspace naming

Workspace names are generated **server-side in the pipeline** (TECH-SPEC §6), not by the app: `idea: <first ~6 meaningful words of notes-or-transcript> #<clientId prefix>`, falling back to `idea: screenshot capture <date>` for screenshot-only captures. The `#<clientId>` tag is load-bearing (orphan-workspace adoption on retry) — custom templates may change the prompt freely, but naming is not template-controlled.
