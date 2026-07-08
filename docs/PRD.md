---
title: Whistle — Capture-to-PRD menu bar app
type: feat
status: active
date: 2026-07-04
---

# Whistle — PRD

## Summary

Whistle is a macOS menu bar app that turns a fleeting product idea into a researched plan waiting in a Conductor workspace. One keystroke opens a capture panel with the mic already hot and a screenshot already taken; you speak and/or type for a few seconds, hit ⏎, and go back to your day. In the background, Whistle creates a Conductor cloud workspace against the relevant repo and hands the agent everything you captured plus an embedded planning prompt. The next time you open Conductor, there's a workspace with a draft plan, codebase research already done, and 3–5 clarifying questions waiting for you.

## Problem Frame

Good feature ideas arrive at the worst times — in meetings, walking between things, mid-task in another app. The cost of capturing them *well* (open the repo, write context, kick off research) is high enough that ideas either die in a notes app or arrive at engineering as one vague sentence. Meanwhile, cloud coding agents (Conductor) are perfectly capable of doing the first 80% of PRD work — investigating the codebase, understanding the feature area, drafting requirements — if only they were handed the idea at the moment it occurred, with the context (voice, screen) that existed at that moment.

Whistle collapses "I should write this up later" into "it's already being written up."

## Personas

- **P1 — Product-minded founder/PM (primary).** Runs multiple repos through Conductor. Has ideas constantly, mostly away from the keyboard context where they'd act on them. Wants zero-friction capture and a high-quality artifact later. Comfortable pasting an API key during setup.
- **P2 — Engineer/tech lead.** Notices "we should fix X" while working in a different area. Wants the observation to become a scoped, researched plan without context-switching now.

## Core user journey

1. **Trigger** — Global hotkey (default `⌥⇧W`) or a plain **left-click on the menu bar icon**. Both do the same thing: start capturing immediately. There is no intermediate dropdown menu — the click *is* the capture. (Right-click offers a small context menu: History, Settings, Check for Updates, Quit.)
2. **Capture** (target: panel visible + mic live in <300 ms) —
   - Screenshot of the active display is taken *at the instant of trigger* (before the panel appears, so the panel is never in the shot).
   - Mic turns on; live on-device transcription streams into the panel.
   - A small panel drops down anchored beneath the menu bar icon: live transcript (editable), a typed-notes field, the screenshot thumbnail (removable), a project picker (defaults to last-used), and a slim header with two small icons — History and Settings — for everything that isn't capturing.
3. **Submit** — ⏎ (or ⌘⏎ from the notes field). Panel dismisses immediately. Total interaction target: under 15 seconds.
4. **Background pipeline** — capture syncs to the backend; the backend uploads context, creates the Conductor workspace, and sends the planning prompt. Laptop can sleep; the pipeline is server-side.
5. **Ready** — When the agent finishes its first pass, Whistle shows a macOS notification: *"Plan draft ready: 'concierge search latency' — 4 questions waiting."* Clicking it opens the workspace via Conductor deep link and marks the capture opened (see Success metrics).
6. **Review** — The History window (reached from the capture panel's history icon or the right-click menu) shows every capture with status and a one-click jump into the Conductor workspace.

## Requirements

### Capture (F1)
- F1.1 Global configurable hotkey and a plain left-click on the menu bar icon both **start capture immediately** (screenshot + hot mic + panel anchored beneath the icon). No dropdown menu on left-click; right-click opens a context menu (History, Settings, Check for Updates, Quit).
- F1.1b The capture panel header carries small History and Settings icons — the panel is the app's home surface.
- F1.2 Screenshot of the active display captured at trigger time; user can remove it before submit. (Multi-display: active display only in v1.)
- F1.3 Mic starts automatically; live transcript rendered as the user speaks; fully on-device (Apple Speech). Transcript is editable text after (and during pauses in) dictation.
- F1.4 Typed notes field, usable simultaneously with dictation.
- F1.5 Project picker populated from the user's Conductor projects (`GET /v0/projects`), cached locally, defaulting to last-used. Searchable if >8 projects.
- F1.6 Submit with ⏎; Escape cancels (with confirm if content exists). Panel never blocks: no spinners before dismiss.
- F1.7 Capture works offline: it queues locally and syncs when connectivity returns.

### Pipeline (F2)
- F2.1 On submit, the capture (transcript + notes + screenshot + project + timestamp) is persisted to Convex; the Conductor submission runs **server-side** (Convex actions), so it survives lid-close.
- F2.2 Screenshot is stored in Convex file storage; its URL is embedded in the prompt with instructions for the agent to download and view it.
- F2.3 Workspace is created via `POST /v0/workspaces` with the chosen project, `agent: "claude"`, and a name derived from the capture (first ~6 meaningful words).
- F2.4 The planning prompt (see `docs/PROMPT-TEMPLATE.md`) is sent to the workspace's initial session. The prompt instructs the agent to research the codebase, write a plan document, **not** implement code, and end with 3–5 clarifying questions.
- F2.5 Pipeline retries transient failures (exponential backoff, ≥5 attempts over ~30 min) and surfaces terminal failures in history with a "Retry" affordance.
- F2.6 After the message is sent, the backend polls session status; when the agent goes `idle`, it fetches the final agent message, extracts the clarifying questions, and stores them on the capture record.

### History (F3)
- F3.1 The History window leads with the most recent captures and shows a status chip per capture: *Waiting for network / Queued → Creating workspace → Agent working → Ready / Sent–status unknown / Failed*. (Exact mapping of local + server states to chips: Tech Spec §4.4.) Status changes in-flight are otherwise communicated by notifications (F4), not a persistent menu.
- F3.2 Each item deep-links into its Conductor workspace (`deepLink` from the API). Opening a deep link marks the capture *opened* (see Success metrics).
- F3.3 The history window shows, per capture: transcript, notes, screenshot preview, status, timestamps, the agent's clarifying questions, and workspace link. Searchable.
- F3.4 History syncs via Convex (source of truth) and is available offline from local cache.
- F3.5 Opened captures are visually de-emphasized in History; each row offers an archive/dismiss affordance that removes it from the default view (not a delete — archived captures remain reachable via a filter). The menu bar icon shows a ready-indicator (dot/badge) whenever ≥1 capture is *Ready* and unopened, clearing as soon as none remain.
- F3.6 **Duplicate as new capture**: any History row can be re-opened as a fresh capture — transcript, notes, and screenshot pre-filled into a new capture panel with the project picker focused — so a capture sent to the wrong project, or one whose content came out garbled, can be corrected without retyping. This creates an entirely new capture (new workspace); it does not edit or resubmit the original.

### Notifications (F4)
- F4.1 Local notification when a capture reaches *Ready* (agent idle, plan drafted), including the count of clarifying questions when available.
- F4.2 Local notification on terminal failure with the reason and a retry action.

### Onboarding & settings (F5)
- F5.1 First-run wizard, reordered for time-to-first-value: (1) sign in; (2) **one combined** permission screen for mic + speech recognition, with a live status row per permission (not a separate explainer screen each); (3) paste Conductor API key with a link to `app.conductor.build/users/api-keys` and inline validation via `GET /v0/projects`; (4) default project — chosen automatically, with no step shown, when the account has exactly one project; (5) guided test capture, with a one-line "Your hotkey is ⌥⇧W — change" affordance rather than a dedicated hotkey step; (6) **screen recording is offered after the first successful test capture**, as an upsell ("Add screenshots to future captures"), not a blocking wizard step — capture already degrades gracefully without it (see Error & edge states), and requiring a System Settings round-trip before any value lands would jeopardize the 5-minute activation target. Wizard progress persists across app relaunch (the screen-recording grant, like screen-recording changes generally, can require the app to relaunch).
- F5.2 Settings: hotkey, default project, agent (`claude`/`codex`/`cursor`), model override, screenshot on/off default, edit prompt template (with "reset to default" and a lint warning when the template's "How to end" section is missing, since clarifying-question extraction depends on it), account/sign-out, API key management (masked, replaceable).
- F5.3 Prompt template is user-editable text with documented `{{variables}}`; stored per-user in the backend so it follows the user to future clients (iOS).

### Product/distribution (F6)
- F6.1 Signed (Developer ID) and notarized; distributed as a DMG outside the App Store.
- F6.2 Auto-update via Sparkle 2.
- F6.3 Launch-at-login toggle (default on after onboarding).
- F6.4 Crash reporting (opt-in at onboarding).

## Scope Boundaries (non-goals for v1)

- No iOS app (architecture must anticipate it — see Tech Spec §12 — but nothing ships).
- No in-app chat with the agent; review/answer questions happens in Conductor itself.
- No editing or re-submitting a capture after submission (retry re-runs the same payload).
- No team/shared history; single-user accounts only.
- No audio-file retention — audio is transcribed on-device and discarded; only the transcript is stored.
- No cloud transcription, no whisper.cpp bundling (on-device Apple Speech only in v1).
- No full-video or multi-display capture.
- No web dashboard (the Next.js app remains marketing/landing only in v1).

## Key decisions

- **Native Swift/SwiftUI menu bar app** — required for solid mic/ScreenCaptureKit/TCC integration and the fastest capture latency; shares a Swift core with the future iOS app. (Electron/Tauri rejected: worse permission story, no iOS path.)
- **On-device Apple Speech transcription** — zero setup, private, offline-capable. `SpeechAnalyzer` on macOS 26+, `SFSpeechRecognizer` (on-device mode) on macOS 14–15. Cloud STT is a possible later upgrade behind the same interface.
- **Server-side submission pipeline (Convex actions + scheduler)** — "hit return and move on with your life" requires the pipeline to survive the laptop sleeping. Also gives iOS the same pipeline for free.
- **Screenshot via Convex file storage URL in the prompt** — the Conductor API is text-only; the agent downloads the image from an unguessable URL and views it. Accepted tradeoff: the URL is technically public (see Privacy).
- **Prompt template bundled + editable** — a self-contained, headless-adapted planning prompt (distilled from the compound-engineering `ce-plan` methodology) ships as the default so it works on any repo, with no plugin dependency. Users can customize it.
- **Convex as the backend** — auth, live-sync history, file storage, scheduled server actions in one system with an official Swift client.

## Error & edge states

| State | Behavior |
|---|---|
| Mic permission denied | Panel opens in type-only mode with inline "enable mic" link to System Settings. |
| Screen-recording permission missing | Capture proceeds without screenshot; thumbnail slot shows "enable in Settings" affordance. |
| Speech recognition unavailable (no on-device model) | Prompt to download the dictation model (macOS setting); type-only fallback meanwhile. |
| Offline at submit | Capture queued locally, status *Waiting for network*; auto-syncs. |
| Conductor API key invalid/revoked | Pipeline fails with *Auth error*; notification deep-links to Settings → API key. |
| Conductor workspace creation fails (repo/setup error) | Status *Failed* with `errorMessage` from the status endpoint; Retry available. |
| Agent never confirms completion (60 min) | Status *Sent — agent status unknown* with the workspace deep link; no false "Ready" notification. |
| Pipeline stalls in any in-flight state (90 min) | Watchdog marks it *Failed (stalled)*, notification fires, Retry available. |
| Empty capture (no speech, no text) | Submit disabled. Screenshot-only submits allowed (screenshot + auto-note "screenshot-only capture"). |
| Very long dictation (>5 min) | Soft cap with gentle UI hint; transcript preserved, capture still submits. |
| Duplicate hotkey press while panel open | Focuses existing panel; does not re-screenshot. |
| Submitted to wrong project / garbled content | Duplicate as new capture from History (F3.6): pre-fills a fresh capture panel with the project picker focused, so it can be corrected and resent without retyping. |

## Privacy & trust

- Audio never leaves the device; only text transcripts are stored.
- Screenshots may contain sensitive content: the thumbnail is always shown pre-submit with one-click removal; a settings default can disable screenshots entirely. Screenshot URLs are unguessable but unauthenticated (required for agent fetch) — stated plainly in onboarding. Screenshots are deletable from history (removes the Convex file).
- Conductor API key is stored server-side (needed for the server-side pipeline), never returned to clients unmasked.
- No analytics in v1 beyond opt-in crash reporting.

## Success metrics

- Time-to-dismiss: median trigger→submit under 15 s.
- Capture reliability: >99% of submitted captures reach *Ready* or a surfaced, retryable failure.
- Activation: a new user completes onboarding and a real capture in under 5 minutes.
- The metric that matters: % of captures whose Conductor workspace the user actually opens within 48 h (target >60%). Instrumented directly via `openedAt` (patched when the user opens a capture's deep link from Whistle, F3.2/F3.5) — this is now a measurable query against the captures table, not an inferred figure.

## Phased delivery

- **Phase 0** — Repo restructure to monorepo; a de-risking proof before real building: an end-to-end "hello workspace" script against the real Conductor API; then Convex project + auth (mock-first — see Tech Spec §2a/§9) + schema. Real Auth0 tenant provisioning and login verification happen after the build, not as a gating spike.
- **Phase 1 (v1.0)** — Everything in F1–F6.
- **Phase 1.1** — Clarifying-questions extraction polish, prompt template editor UX, multi-display option, per-capture agent/model override, archive workspace from History (Conductor archive endpoint), daily rollup notification for unopened ready captures.
- **Phase 2 (v2)** — iOS: share-extension + Action-button capture (photo/screenshot from share sheet instead of screen capture), same backend/pipeline/history untouched.

## Open questions (deferred to implementation)

- Whether Conductor queues messages sent while a workspace is still `initializing` (the message-create response has a `queued` state, suggesting yes). Implementation must verify; the spec includes a poll-then-send fallback.
- Conductor API rate limits and workspace quotas — undocumented; pipeline backoff is designed conservatively.
- Exact `model` string values accepted by the API (spec'd as free-form string; default omitted in v1).
