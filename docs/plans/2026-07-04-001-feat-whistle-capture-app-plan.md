---
title: "feat: Whistle capture-to-PRD macOS app (v1)"
type: feat
status: active
date: 2026-07-04
origin: docs/PRD.md
---

# feat: Whistle capture-to-PRD macOS app (v1)

## Summary

Build Whistle v1 as three coordinated pieces: a Swift/SwiftUI menu bar app (instant capture: hot mic with on-device transcription, screenshot, notes, offline-first local queue), a Convex backend (auth, history sync, screenshot file storage, per-user prompt template, and the entire Conductor submission pipeline as idempotent scheduled actions), and a thin marketing/appcast role for the existing Next.js app. Execution starts with two Phase-0 de-risking proofs (real Conductor API e2e; Auth0+convex-swift sandboxed-macOS login spike) before building on either dependency.

---

## Problem Frame

Captured ideas die because writing them up well is expensive at the moment they occur. Whistle makes capture a sub-15-second act and outsources the write-up: a Conductor cloud agent researches the target repo and drafts a PRD with clarifying questions before the user next opens Conductor. Full product context: [docs/PRD.md](../PRD.md).

---

## Requirements

Carried from origin (PRD feature IDs are the trace anchors):

- R1. Sub-300 ms capture panel with hot mic, live on-device transcript, screenshot-at-trigger, typed notes, project picker (PRD F1).
- R2. Server-side, sleep-proof, idempotent submission pipeline: Convex → Conductor workspace + planning prompt (PRD F2).
- R3. Synced, offline-readable history with accurate status chips and deep links (PRD F3).
- R4. Notifications on verified-ready and on failure, routed by error class (PRD F4).
- R5. Productized onboarding (permissions, API key, test capture) and settings (PRD F5).
- R6. Signed, notarized, auto-updating distribution (PRD F6).

**Origin acceptance anchors:** PRD "Error & edge states" table (every row must demonstrably behave as written — U12), PRD success metrics (capture <15 s median; >99% of captures reach a terminal surfaced state).

---

## Scope Boundaries

Per PRD non-goals: no iOS app (but WhistleCore stays AppKit-free), no in-app agent chat, no capture editing post-submit, no team features, no audio retention, no cloud STT, no web dashboard.

### Deferred to Follow-Up Work

- Clarifying-questions rich extraction beyond dumb heuristics — v1.1.
- Multi-display screenshot choice, per-capture agent/model override — v1.1.
- Signed/expiring screenshot URLs or authenticated proxy — revisit if Conductor adds image upload.

---

## Context & Research

- **Repo state:** fresh `create-next-app` scaffold (`package.json`, `src/`, `pnpm-workspace.yaml` present); no existing patterns to follow — greenfield. Note `AGENTS.md` warning: this Next.js version has breaking changes; consult `node_modules/next/dist/docs/` before touching `apps/web`.
- **Conductor API:** fully mapped from the live OpenAPI spec in [docs/CONDUCTOR-API.md](../CONDUCTOR-API.md), including the six known unknowns U4 must verify. All endpoints experimental-stability.
- **Architecture & design decisions:** [docs/TECH-SPEC.md](../TECH-SPEC.md) is the authoritative design companion — §4.1b (transcription session continuation), §4.4 (status mapping), §5 (schema), §6 (pipeline state machine + idempotency rules), §8 (template rendering). Units below cite it rather than restating it.
- **Default prompt payload:** [docs/PROMPT-TEMPLATE.md](../PROMPT-TEMPLATE.md); runtime source of truth `packages/backend/convex/defaultTemplate.ts`.
- **External dependencies:** convex-swift + convex-swift-auth0 (official, Apple-platform), KeyboardShortcuts, GRDB, Sparkle 2.

---

## Key Technical Decisions

All recorded with rationale in TECH-SPEC §2 (stack), §6 (pipeline design rules), §9 (security tradeoffs). Headlines: native Swift over Electron/Tauri (permissions + iOS path); on-device speech only; server-side pipeline so captures survive lid-close; Conductor key server-side; screenshot as unauthenticated-but-unguessable Convex URL; non-activating key-capable NSPanel (Spotlight pattern) so capture never yanks the user out of their frontmost app.

---

## Open Questions

### Resolved during planning
- Conductor message transport is text-only → screenshot travels as a fetchable URL.
- `POST /v0/workspaces` returns `sessionId` directly → no session-creation step needed.
- Workspace naming is server-side, `#clientId`-tagged for orphan adoption.

### Deferred to implementation (verify, then update CONDUCTOR-API.md)
- Unknowns #1–#6 in CONDUCTOR-API.md (message-during-init, rate limits, model strings, message content shape, agent outbound network, messageId dedupe) — all owned by U4; the pipeline is designed to be safe under either answer.
- SwiftUI focus behavior inside a non-activating panel — U8 carries the specified fallback.

---

## Output Structure

    whistle/
    ├── apps/
    │   ├── macos/Whistle/          # SwiftUI app target + WhistleTests/
    │   └── web/                    # relocated Next.js app
    ├── packages/
    │   ├── backend/convex/         # schema, functions, pipeline, defaultTemplate
    │   ├── backend/scripts/        # e2e-conductor.ts
    │   └── whistle-core/           # cross-platform Swift package
    └── docs/                       # PRD, TECH-SPEC, CONDUCTOR-API, PROMPT-TEMPLATE, plans/

---

## Implementation Units

> Execution order: U1 → U4 → U2 → (U3 ∥ U5) → U6 → U7 → U8 → U9 → U10 → U11 → U12. U4 runs early on purpose: it gates U2's auth configuration and validates the API behavior U3 encodes.

### U1. Monorepo restructure

**Goal:** Repo shaped per Output Structure with the existing Next.js app intact.

**Requirements:** enables all.

**Dependencies:** none.

**Files:**
- Move root Next.js files → `apps/web/` (use `git mv`; includes `src/`, configs, `public/`)
- Modify: `pnpm-workspace.yaml` (packages: `apps/web`, `packages/backend`), root `package.json`
- Create: `packages/backend/package.json`, `packages/whistle-core/Package.swift` (empty targets), `apps/macos/.gitkeep`

**Approach:** pure relocation, no dependency upgrades; respect the AGENTS.md Next.js caveat by not editing app code.

**Test scenarios:** Test expectation: none — pure restructuring; verification below covers it.

**Verification:** `pnpm install && pnpm --filter web build` succeeds; `swift build` succeeds in `packages/whistle-core`.

---

### U2. Convex backend foundation

**Goal:** Deployable Convex project: schema, auth wiring, users/settings/templates/files functions.

**Requirements:** R2, R3, R5.

**Dependencies:** U1; auth provider choice gated by U4's spike outcome (schema/function work may start in parallel).

**Files:**
- Create: `packages/backend/convex/schema.ts` (exactly TECH-SPEC §5), `auth.config.ts`, `users.ts`, `settings.ts`, `templates.ts`, `defaultTemplate.ts` (body from PROMPT-TEMPLATE.md), `files.ts`
- Test: `packages/backend/convex/__tests__/{users,settings,templates}.test.ts` (convex-test)

**Approach:** every function derives the user from `ctx.auth` and enforces row ownership; `settings.get` returns `hasKey` + last-4 only.

**Test scenarios:**
- Happy: first `users.ensure` inserts; second is a no-op returning the same id.
- Happy: `templates.get` seeds the default on first call; `templates.reset` restores it after customization.
- Error: `settings.get` never includes the raw key (assert masked shape even right after `setConductorKey`).
- Error: any function called with another user's row id → denial.
- Edge: `settings.update` with no settings row yet → creates with defaults (`agent: "claude"`, `screenshotsEnabled: true`).

**Verification:** `npx convex dev` deploys clean; test suite green.

---

### U3. Conductor client + pipeline

**Goal:** The idempotent, never-strands pipeline of TECH-SPEC §6, exactly as specified.

**Requirements:** R2, R4 (error taxonomy feeds notifications).

**Dependencies:** U2. May be drafted in parallel with U4, but must not be trusted/deployed until U4's six unknowns are resolved and CONDUCTOR-API.md is updated — adjust `pipeline.submit` per the answers.

**Files:**
- Create: `packages/backend/convex/conductorClient.ts` (single `conductorFetch` + typed endpoint wrappers + error classification per §6), `pipeline.ts` (`submit`, `awaitWorkspaceReady`, `watch`, `watchdog`, and the workspace-naming helper per §6), `captures.ts` (create/list/listRecent/get/retry/deleteScreenshot), `projects.ts` (+ `conductor.validateKey`, `conductor.refreshProjects`), `promptRenderer.ts` (`{{var}}` + single `{{#if}}` regex)
- Test: `packages/backend/convex/__tests__/{pipeline,captures,promptRenderer}.test.ts` with a mocked Conductor server built from CONDUCTOR-API.md fixtures

**Approach:** implement §6 verbatim — the design rules (idempotent-by-construction, never-die-silently, watchdog backstop, error classification) are requirements, not suggestions. Workspace naming helper lives here.

**Test scenarios** (the §11 matrix, itemized):
- Happy: create → submit → workspace created → message `sent` → watch `working`→`idle` with agent reply → `ready` with questions extracted.
- Happy: message `queued` during init → still proceeds to `agentWorking`.
- Integration: send hits not-ready 4xx → `awaitWorkspaceReady` reschedules → `ready` → resumes submit → sends.
- Error: 5xx on create → backoff reschedule ×2 → success; `attempt` increments; **exactly one workspace created** (guard on `workspaceId`).
- Error: create succeeded but action died pre-patch → rerun adopts orphan via name tag; no second workspace.
- Error: send re-run with our `messageId` already in session messages → skipped; no duplicate prompt.
- Error: 401 anywhere → `failed`/`auth`, no retry scheduled.
- Edge: `pipeline.watch` status poll throws → the action reschedules itself anyway (capture not stranded).
- Edge: `idle` + no agent message after ours + workspace `initializing` → reschedules, does NOT mark ready.
- Edge: watch deadline (60 min) → `readyUnverified`, not `ready`.
- Edge: watchdog fires on capture stuck in `sending` → `failed`/`stalled`.
- Happy: `captures.retry` from `failed` after partial progress → completes without duplicating workspace or message.
- Edge: `captures.create` twice with same `clientId` → one row.
- Renderer: empty screenshot URL removes the `{{#if}}` block; all six variables substitute; `{{` in user text passes through untouched.
- Extraction: numbered questions parsed; agent message with no questions → `ready` with empty array (F4.1 copy degrades gracefully).

**Verification:** full mocked-matrix green; every capture in every test ends in `ready`, `readyUnverified`, or `failed` — never stuck in flight.

---

### U4. Phase-0 proofs (Conductor e2e + auth spike)

**Goal:** Empirically settle the two load-bearing dependencies before the app is built on them.

**Requirements:** de-risks R2 (API behavior) and everything (auth).

**Dependencies:** U1. Runs before U2 finalizes `auth.config.ts` and before U3 is trusted.

**Files:**
- Create: `packages/backend/scripts/e2e-conductor.ts` (env-gated: real key, scratch repo)
- Create: `apps/macos/AuthSpike/` (throwaway sandboxed Developer-ID mini-app: Auth0 login via ASWebAuthenticationSession → authenticated Convex query)

**Approach:** e2e script exercises: create workspace → immediate send during `initializing` (unknown #1) → duplicate `messageId` send (unknown #6) → agent curls a Convex file URL (unknown #5) → capture a real agent-message `content` fixture (unknown #4). Record answers in CONDUCTOR-API.md and adjust `pipeline.submit` if needed. Auth spike proves the OAuth callback round-trip inside App Sandbox with Developer-ID signing; if it fails, decide fallback (Convex Auth custom provider / alternate OIDC) **before** U2's auth config and U6.

**Test scenarios:** Test expectation: none — these ARE the tests (manual, documented output).

**Verification:** CONDUCTOR-API.md "Known unknowns" updated with six answers; a written go/no-go on Auth0 with the chosen fallback if no-go.

---

### U5. WhistleCore package

**Goal:** Cross-platform Swift core: models, offline store, sync, Convex client, template preview.

**Requirements:** R1 (queue), R3 (cache), R5 (preview).

**Dependencies:** U2 (function contract). No AppKit imports anywhere in this package.

**Files:**
- Create: `packages/whistle-core/Sources/WhistleCore/{Models,CaptureStore,SyncEngine,ConvexService,TemplatePreview,StatusPresentation}.swift`
- Test: `packages/whistle-core/Tests/WhistleCoreTests/{CaptureStoreTests,SyncEngineTests,TemplatePreviewTests,StatusPresentationTests}.swift

**Approach:** GRDB tables: `pending_captures`, `history_cache`, `projects_snapshot`, `app_state` (last-used project). `StatusPresentation` implements the TECH-SPEC §4.4 mapping table as a pure function `(localState, serverRecord?) → (chip, affordance)`. SyncEngine: NWPathMonitor-driven drain; screenshot upload → `generateUploadUrl` POST → storageId → `captures.create`.

**Test scenarios:**
- Happy: draft→queued→syncing→synced round-trips through a real temp SQLite db.
- Happy: every row of the §4.4 mapping table asserted (parameterized test).
- Edge: offline at drain → stays queued, no crash; connectivity restored → drains in order.
- Error: `captures.create` throws → `syncFailed`; local retry re-drains; same `clientId` reused (idempotent server-side).
- Error: screenshot upload fails but mutation would succeed → whole capture stays queued (upload-then-create is atomic from the queue's view).
- Edge: projects snapshot survives relaunch; picker data available with network off.
- Renderer preview: matches backend renderer output for the same inputs (shared fixture file).

**Verification:** `swift test` green on macOS; package also compiles for iOS (CI check) to enforce the no-AppKit rule.

---

### U6. macOS app shell + auth

**Goal:** Running MenuBarExtra app with real sign-in and account state.

**Requirements:** R5, R6 (launch-at-login).

**Dependencies:** U5; U4 auth verdict.

**Files:**
- Create: `apps/macos/Whistle/{WhistleApp,StatusItemController,AuthController}.swift`, entitlements per TECH-SPEC §4.3, Info.plist usage strings
- Test: `apps/macos/WhistleTests/AuthControllerTests.swift` (state transitions with a fake auth provider)

**Approach:** custom `NSStatusItem` (not `MenuBarExtra`): left-click starts capture (wired fully in U8; placeholder action here), right-click `NSMenu` with History, Settings, account, Check for Updates, Quit. `SMAppService` for launch-at-login.

**Test scenarios:**
- Happy: signed-out → sign-in flow → `users.ensure` called once → signed-in menu state.
- Edge: token refresh failure → signed-out state with re-auth prompt, no crash.

**Verification:** app runs signed-in against dev Convex; relaunch preserves the session (refresh token persisted in Keychain; no re-auth prompt).

---

### U7. Screenshot + transcription services

**Goal:** The two capture inputs, production-grade, per TECH-SPEC §4.1/§4.1b.

**Requirements:** R1.

**Dependencies:** U6.

**Files:**
- Create: `apps/macos/Whistle/Services/{ScreenshotService,TranscriptionService,SpeechAnalyzerTranscriber,LegacySpeechTranscriber,AudioEngineTap}.swift`
- Test: `apps/macos/WhistleTests/{TranscriptStitchingTests,ScreenshotEncodeTests}.swift`

**Approach:** exactly §4.1b: committed + live segments, task cycling on `isFinal`/error with the audio tap never stopping; per-OS model availability paths. Screenshot: display-under-cursor, downscale 2000 px, JPEG q0.8, `nil` on TCC denial.

**Test scenarios:**
- Happy: stream of volatile updates then `isFinal` → committed text extends, live resets (fake recognizer).
- Edge: task error mid-utterance → new task starts, committed text preserved, no dropped join-space or duplicated words.
- Edge: three consecutive finalizations → correctly ordered concatenation.
- Edge: `stop()` mid-live-segment → live hypothesis included in final text.
- Happy: encode 5K display image → ≤2000 px long edge, <1 MB.
- Error: TCC denied → returns nil, no throw.

**Verification:** manual: 6-minute continuous dictation on macOS 14 VM and macOS 26 produces coherent transcript across segment boundaries.

---

### U8. Capture panel UX

**Goal:** The sub-300 ms capture surface, wired end-to-end into the local queue.

**Requirements:** R1; PRD error-table rows for mic/speech/screen degradation.

**Dependencies:** U7.

**Files:**
- Create: `apps/macos/Whistle/Capture/{CapturePanelController,CaptureView,CaptureViewModel,ProjectPicker}.swift`, hotkey registration (KeyboardShortcuts, default ⌥⇧W)
- Test: `apps/macos/WhistleTests/CaptureViewModelTests.swift`

**Approach:** non-activating `NSPanel` + `canBecomeKey` override (TECH-SPEC §4.1), anchored beneath the status item; triggered identically by hotkey and status-item left-click. Panel header carries History + Settings icon buttons (the panel is the app's home surface — there is no left-click dropdown menu). Screenshot fired before panel show; submit → `CaptureStore` → close (no network on this path, ever). Fallback plan if SwiftUI focus fights the non-activating panel: activating panel + restore `frontmostApplication` on dismiss — decide by testing, record the outcome in the PR.

**Test scenarios:**
- Happy: submit with transcript+notes+screenshot+project → correct `CaptureDraft` queued, panel closed.
- Edge: submit disabled when transcript, notes, and screenshot all empty; enabled for screenshot-only (auto-note injected: "screenshot-only capture" — client-side, recorded in `notes`).
- Edge: screenshot removed → draft has nil screenshot.
- Edge: hotkey while panel open → focuses existing panel, no second screenshot.
- Edge: Esc with content → confirm; Esc empty → close.
- Error: mic denied → type-only mode flag set, panel still opens.
- Happy: last-used project preselected; selection updates `app_state`.

**Verification:** instrumented trigger→panel-interactive timing <300 ms on a base M-series machine; typing lands in the panel while the previous app stays active (menu bar shows the prior app's name).

---

### U9. History, status, notifications

**Goal:** Live history in the History window with §4.4 chips, plus routed notifications (notifications are the in-flight status channel — there is no persistent status menu).

**Requirements:** R3, R4.

**Dependencies:** U8, U3.

**Files:**
- Create: `apps/macos/Whistle/{History/HistoryWindow,History/HistoryRow,NotificationService}.swift`
- Test: `apps/macos/WhistleTests/NotificationRoutingTests.swift`

**Approach:** subscribe `captures.listRecent`; merge with local pending rows via `StatusPresentation` (single source for chips). Notifications fire on observed transitions only (track last-seen status per clientId to avoid re-fires on relaunch).

**Test scenarios:**
- Happy: transition →`ready` fires notification with question count; click opens deepLink.
- Happy: →`failed`/`auth` notification routes to Settings; →`failed` other offers Retry (calls `captures.retry`).
- Edge: →`readyUnverified` uses "status unknown" copy, not success copy.
- Edge: app relaunch with existing `ready` rows → no duplicate notifications.
- Integration: local `syncFailed` row shows local-retry affordance; server `failed` shows server-retry.

**Verification:** end-to-end against dev backend: submitted capture visibly walks Queued→Creating→Agent working→Ready in the History window, with the Ready notification firing once.

---

### U10. Onboarding + settings

**Goal:** PRD F5 complete: wizard, permissions handling, key validation, template editor.

**Requirements:** R5.

**Dependencies:** U9.

**Files:**
- Create: `apps/macos/Whistle/{Onboarding/OnboardingWindow,Onboarding/PermissionStep,Settings/SettingsWindow,Settings/TemplateEditor}.swift`
- Test: `apps/macos/WhistleTests/OnboardingGatingTests.swift`

**Approach:** step gating per PRD F5.1; per-OS speech-model step (§4.1b); screen-recording step with relaunch handling (§4.3); key step validates via `conductor.validateKey` before advancing; guided test capture last. SettingsWindow also carries the agent picker (claude/codex/cursor) and optional model string, saved via `settings.update` (PRD F5.2). Template editor: plain text + variable legend + live preview via WhistleCore's `TemplatePreview` (kept output-identical to the backend `promptRenderer.ts` via the shared fixture file) + reset.

**Test scenarios:**
- Happy: all-granted path reaches test capture; completion flag persists.
- Edge: each permission denied → wizard proceeds with degraded-mode messaging (never hard-blocks except sign-in and API key).
- Error: invalid key → inline error, step doesn't advance.
- Happy: template edit → save → `templates.update` called; reset → default restored.

**Verification:** fresh macOS user account: wizard → real capture → Ready, under 5 minutes (PRD activation metric).

---

### U11. Distribution

**Goal:** Signed, notarized, auto-updating DMG with CI.

**Requirements:** R6.

**Dependencies:** U10.

**Files:**
- Create: `.github/workflows/{ci.yml,release.yml,backend-deploy.yml}`, `apps/macos/scripts/package-dmg.sh`, Sparkle integration in app target, appcast route in `apps/web`

**Approach:** per TECH-SPEC §10. Certificates via GitHub secrets; appcast generated from release assets, EdDSA-signed.

**Test scenarios:** Test expectation: none — infra; verification is the test.

**Verification:** clean-machine install from DMG passes Gatekeeper; Sparkle updates vN→vN+1; CI green on PR.

---

### U12. Polish pass against PRD error/edge table

**Goal:** Every row of the PRD "Error & edge states" table demonstrably true.

**Requirements:** all.

**Dependencies:** U11.

**Files:** across app; fixes only, no new features.

**Test scenarios:** the PRD table is the checklist — walk it row by row on macOS 14 and macOS 26 (the two versions cover both transcription implementations, `LegacySpeechTranscriber` vs `SpeechAnalyzer`; TECH-SPEC §4.1b), recording evidence (screen recordings) per row.

**Verification:** signed-off checklist attached to the release PR.

---

## System-Wide Impact

- **Interaction graph:** capture path (hotkey→panel→queue) is fully decoupled from network; only SyncEngine and the pipeline touch I/O. Status flows one way: pipeline → captures table → subscription → UI/notifications.
- **Error propagation:** Conductor errors normalize in `conductorFetch` → `errorCode` on the record → §4.4 mapping → UI/notification. No layer invents its own error strings.
- **State lifecycle risks:** the §6 design rules (idempotency guards, never-die-silently, watchdog) exist precisely because scheduled actions die invisibly; tests in U3 enforce them.
- **API surface parity:** `captures.create` contract is the iOS seam — changes to it require checking both the U5 SyncEngine and future clients.

---

## Risks & Dependencies

Carried in TECH-SPEC §14 (authoritative table). Execution-order note: U4's two proofs are the only units that can invalidate design decisions — schedule them first and treat their write-ups as gates.

---

## Sources & References

- **Origin:** [docs/PRD.md](../PRD.md)
- Design companion: [docs/TECH-SPEC.md](../TECH-SPEC.md)
- API reference: [docs/CONDUCTOR-API.md](../CONDUCTOR-API.md) (live OpenAPI, fetched 2026-07-04)
- Prompt payload: [docs/PROMPT-TEMPLATE.md](../PROMPT-TEMPLATE.md)
- External: convex-swift, convex-swift-auth0, Convex file storage docs, KeyboardShortcuts, GRDB, Sparkle 2
