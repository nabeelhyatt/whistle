// Runtime source of truth for the default planning prompt Whistle sends as
// the first message to a Conductor workspace agent. Keep this in sync with
// docs/PROMPT-TEMPLATE.md (that file documents this one; this one is what
// actually ships). See TECH-SPEC §8 for the rendering contract:
// `{{var}}` literal substitution plus a single `{{#if screenshot_url}}...{{/if}}`
// conditional block.

export const defaultTemplate = `# Idea capture → plan request

A user captured a fleeting product idea at {{captured_at_iso}}, aimed at the project "{{project_name}}". Research this codebase and turn the idea into a reviewable plan document — **without implementing anything** — ending with clarifying questions for the user.

**Voice transcript** (machine-transcribed; product and code names may be mis-heard — reconcile every term against the actual codebase):

> {{transcript}}

**Typed notes:**

> {{notes}}

{{#if screenshot_url}}
**Screenshot** from the moment of capture. Download and view it before researching: \`curl -sL -o /tmp/whistle-capture.jpg "{{screenshot_url}}"\`, then read it as an image. It shows whatever was on screen — weigh it as one input among several, not the definitive context.
{{/if}}

## What to do

1. **Interpret.** State in a sentence what you believe the user is asking for. If ambiguous, pick the most plausible reading given this codebase and record alternatives as assumptions.
2. **Research.** Find the relevant files, entry points, existing patterns, and prior art. Read any repo guidance that applies (AGENTS.md, CLAUDE.md, docs/solutions/, docs/plans/).
3. **Gate.** If the idea doesn't concern this repo, or is already implemented or already planned in docs/plans/, write a few-sentence note pointing at what you found — that note is the whole deliverable. If the input is too thin or ambiguous for one confident interpretation, write a short interpretation memo (best readings with evidence, what to clarify) instead of inventing scope.
4. **Write the plan.** Follow the repo's planning convention if one exists; otherwise create \`docs/plans/<YYYY-MM-DD>-<NNN>-<feat|fix|refactor>-<3-5-word-slug>-plan.md\` with YAML frontmatter \`title\`, \`type\`, \`status: active\`, \`date\` (the note and memo above use the same convention). Cover, sized to the idea: summary, assumptions (this ran without user confirmation — flag every material inference), approach and key technical decisions, implementation steps with the files they touch and how to verify them, explicit non-goals, and risks. Don't pad.
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
`;
