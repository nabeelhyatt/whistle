---
title: "feat: Whistle capture-to-PRD macOS app (v1)"
type: feat
status: active
date: 2026-07-04
origin: docs/PRD.md
---

# feat: Whistle capture-to-PRD macOS app (v1)

## Summary

Build Whistle v1 as three coordinated pieces: a Swift/SwiftUI menu bar app (instant capture: hot mic with on-device transcription, screenshot, notes, offline-first local queue), a Convex backend (auth, history sync, screenshot file storage, per-user prompt template, and the entire Conductor submission pipeline as idempotent scheduled actions), and a thin marketing/appcast role for the existing Next.js app. Execution starts with a Phase-0 de-risking proof (real Conductor API e2e) before building on it; auth is mock-first for the entire one-shot build (real Auth0 login is a post-run verification step — see Context & Research and TECH-SPEC §2a/§9).

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
- **Architecture & design decisions:** [docs/TECH-SPEC.md](../TECH-SPEC.md) is the authoritative design companion — §2a (execution environment & conventions: host/toolchain facts, secrets, Convex target, and the autonomous definition of done — read this before starting any unit), §3a (XcodeGen project generation), §4.1b (transcription session continuation), §4.4 (status mapping), §5 (schema), §6 (pipeline state machine + idempotency rules), §8 (template rendering). Units below cite it rather than restating it.
- **Default prompt payload:** [docs/PROMPT-TEMPLATE.md](../PROMPT-TEMPLATE.md); runtime source of truth `packages/backend/convex/defaultTemplate.ts`.
- **External dependencies:** convex-swift + convex-swift-auth0 (official, Apple-platform, both pre-1.0 — pin exact SPM versions at implementation time and read the resolved package source before writing `ConvexService`), KeyboardShortcuts, GRDB, Sparkle 2, XcodeGen (project generation, TECH-SPEC §3a).

---

## Key Technical Decisions

All recorded with rationale in TECH-SPEC §2 (stack), §2a (execution environment), §6 (pipeline design rules), §9 (security tradeoffs). Headlines: native Swift over Electron/Tauri (permissions + iOS path); on-device speech only; server-side pipeline so captures survive lid-close; Conductor key server-side; screenshot as unauthenticated-but-unguessable Convex URL; **both capture-panel focus modes built in v1** — non-activating key-capable NSPanel (Spotlight pattern) as default so capture never yanks the user out of their frontmost app, plus an activating-panel-with-restore fallback behind a debug flag, since which one feels right is a human judgment call (TECH-SPEC §4.1); **mock-first auth** — the one-shot build targets a `MockAuthProvider` behind the same seam as real Auth0, so the build's automated definition of done never depends on a live tenant (TECH-SPEC §2a/§9); Xcode project generated via XcodeGen from a checked-in `project.yml`, never hand-authored (TECH-SPEC §3a).

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

> Execution order: U1 → (U4 ∥ U2) → (U3 ∥ U5) → U6 → U7 → U8 → U9 → U10 → U11 → U12. U4 no longer gates U2: auth is mock-first for the whole one-shot build (TECH-SPEC §2a/§9), so U2's schema/auth-wiring work and U4's Conductor e2e proof can run in parallel once U1 lands. U4 still validates the API behavior U3 encodes, so U3 must not be trusted/deployed until U4's unknowns are resolved (see U3's Dependencies).

### U1. Monorepo restructure

**Goal:** Repo shaped per Output Structure with the existing Next.js app intact.

**Requirements:** enables all.

**Dependencies:** none.

**Files:**
- Move root Next.js files → `apps/web/` (use `git mv`; includes `src/`, configs, `public/`)
- Modify: `pnpm-workspace.yaml` — **add** the `packages:` key (`apps/web`, `packages/backend`); it does not exist yet in the current scaffold (the file currently contains only `ignoredBuiltDependencies`), so this is an addition, not an edit of existing config. Also modify root `package.json`.
- Create: `packages/backend/package.json`, `packages/whistle-core/Package.swift` (empty targets), `apps/macos/.gitkeep`, `apps/macos/project.yml` (XcodeGen spec skeleton — filled in fully by U6, TECH-SPEC §3a)

**Approach:** pure relocation, no dependency upgrades; respect the AGENTS.md Next.js caveat by not editing app code.

**Test scenarios:** Test expectation: none — pure restructuring; verification below covers it.

**Verification:** `pnpm install && pnpm --filter web build` succeeds; `swift build` succeeds in `packages/whistle-core`.

---

### U2. Convex backend foundation

**Goal:** Deployable Convex project: schema, auth wiring, users/settings/templates/files functions.

**Requirements:** R2, R3, R5.

**Dependencies:** U1 only. Auth is mock-first for the whole one-shot (TECH-SPEC §2a/§9): `auth.config.ts` wires the real Auth0/OIDC provider from env/xcconfig placeholder config (no hardcoded tenant values), and all automated tests exercise it through `MockAuthProvider`'s identity shape — there is no spike outcome to wait on.

**Files:**
- Create: `packages/backend/convex/schema.ts` (exactly TECH-SPEC §5, including the `openedAt`/`archivedAt` fields on `captures`), `auth.config.ts`, `users.ts`, `settings.ts`, `templates.ts`, `defaultTemplate.ts` (body from PROMPT-TEMPLATE.md), `files.ts`
- Test: `packages/backend/convex/__tests__/{users,settings,templates}.test.ts` (convex-test)

**Approach:** every function derives the user from `ctx.auth` and enforces row ownership; `settings.get` returns `hasKey` + last-4 only. Target the existing Convex deployment non-interactively — team `nabeelo`, project `whistle`, deployment `grandiose-alpaca-243` (TECH-SPEC §2a) — via `.env.local`/`CONVEX_DEPLOYMENT` and `npx convex dev --once`; never run interactive `convex dev` project configuration.

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
- Create: `packages/backend/convex/conductorClient.ts` (single `conductorFetch` + typed endpoint wrappers + error classification per §6), `pipeline.ts` (`submit`, `awaitWorkspaceReady`, `watch`, `watchdog`, and the workspace-naming helper per §6), `captures.ts` (create/list/listRecent/get/retry/deleteScreenshot/**markOpened**/**archive**, TECH-SPEC §7), `projects.ts` (+ `conductor.validateKey`, `conductor.refreshProjects`), `promptRenderer.ts` (`{{var}}` + single `{{#if}}` regex)
- Test: `packages/backend/convex/__tests__/{pipeline,captures,promptRenderer}.test.ts` with a mocked Conductor server built from CONDUCTOR-API.md fixtures; pin `convex-test` and `vitest` to exact versions in `packages/backend/package.json`

**Approach:** implement §6 verbatim — the design rules (idempotent-by-construction, never-die-silently, watchdog backstop, error classification) are requirements, not suggestions. Workspace naming helper lives here. Test harness mechanics, pinned exactly (TECH-SPEC §11): vitest with the `edge-runtime` environment + `convex-test`; Conductor mocked via `vi.stubGlobal("fetch", ...)`; self-rescheduling actions (`watch`, `awaitWorkspaceReady`, `watchdog`) driven with `vi.useFakeTimers()` plus `t.finishInProgressScheduledFunctions()` / `t.finishAllScheduledFunctions()` — never real sleeps in tests.

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
- Happy: `captures.markOpened` patches `openedAt` on first call; calling it again is a no-op (idempotent — first open wins, `openedAt` unchanged).
- Happy: `captures.archive` patches `archivedAt`; `captures.listRecent`/`captures.list` exclude archived captures from the default view but `captures.get` still returns them.

**Verification:** full mocked-matrix green; every capture in every test ends in `ready`, `readyUnverified`, or `failed` — never stuck in flight.

---

### U4. Phase-0 proof (Conductor e2e)

**Goal:** Empirically settle the Conductor API's load-bearing unknowns before U3's pipeline is trusted or deployed. (The auth side of Phase-0 is no longer part of the one-shot critical path — see Key Technical Decisions and TECH-SPEC §2a/§9: the build is mock-first, and real Auth0 login verification is a `docs/MANUAL-QA.md` item, not a U4 spike.)

**Requirements:** de-risks R2 (API behavior).

**Dependencies:** U1 only — can start immediately, in parallel with U2.

**Files:**
- Create: `packages/backend/scripts/e2e-conductor.ts` (env-gated: reads `CONDUCTOR_API_KEY` and `CONDUCTOR_SCRATCH_PROJECT_ID` from `.env.local`, TECH-SPEC §2a)

**Approach:** the script reads its credentials from `.env.local`, where both are already provisioned and validated for this run (`CONDUCTOR_API_KEY`; `CONDUCTOR_SCRATCH_PROJECT_ID=11dd0481-a2ba-4bcd-86c3-8cbe309a6f5f`, project "ttl"). Every workspace it creates is named `whistle-e2e-*` and archived via `POST /v0/workspaces/{id}/archive` (CONDUCTOR-API.md) once the script has recorded what it needs — this project is a shared scratch resource across Conductor workspaces, so cleanup is not optional. Sequence: create a `whistle-e2e-*` workspace → immediate send during `initializing` (unknown #1) → duplicate `messageId` send (unknown #6) → capture a real agent-message `content` fixture (unknown #4) → **outbound-fetch check (unknown #5), done in two passes to close the U4-before-U2 sequencing gap**: first pass uses any public URL (so it doesn't have to wait on U2/Convex), archiving that workspace when done; a second pass re-runs after U2 has deployed and produces a real Convex file URL, using a fresh `whistle-e2e-*` workspace, so the final recorded answer reflects the actual production URL shape. Record all six answers in CONDUCTOR-API.md and adjust `pipeline.submit` if needed.
If `CONDUCTOR_API_KEY` is absent when this unit runs (it should not be, per TECH-SPEC §2a, but the script must not assume): record unknowns #1–#6 as "unresolved — pipeline safe under either answer per TECH-SPEC §6 guards" in CONDUCTOR-API.md and continue with the rest of the build rather than stalling. The pipeline's idempotency guards (§6) are designed to be correct regardless of how the unknowns resolve, so this is a degraded-confidence continuation, not a blocker.

**Test scenarios:** Test expectation: none — these ARE the tests (manual, documented output).

**Verification:** CONDUCTOR-API.md "Known unknowns" updated with six answers (or explicitly marked unresolved-but-safe per above); the outbound-fetch check has both a pre-U2 and a post-U2 result recorded.

---

### U5. WhistleCore package

**Goal:** Cross-platform Swift core: models, offline store, sync, Convex client, template preview.

**Requirements:** R1 (queue), R3 (cache), R5 (preview).

**Dependencies:** U2 (function contract). No AppKit imports anywhere in this package.

**Files:**
- Create: `packages/whistle-core/Sources/WhistleCore/{Models,CaptureStore,SyncEngine,ConvexService,TemplatePreview,StatusPresentation}.swift`
- Test: `packages/whistle-core/Tests/WhistleCoreTests/{CaptureStoreTests,SyncEngineTests,TemplatePreviewTests,StatusPresentationTests}.swift

**Approach:** GRDB tables: `pending_captures`, `history_cache`, `projects_snapshot`, `app_state` (last-used project). `StatusPresentation` implements the TECH-SPEC §4.4 mapping table as a pure function `(localState, serverRecord?) → (chip, affordance)`. SyncEngine: NWPathMonitor-driven drain; screenshot upload → `generateUploadUrl` POST → storageId → `captures.create`. `ConvexService` defines its own auth-provider protocol (implemented by `MockAuthProvider` here and by `Auth0AuthProvider` in U6) so every convex-swift/convex-swift-auth0 call is isolated behind this one file — both packages are pre-1.0 (beta 0.x); pin exact SPM versions when adding the dependency and read the resolved package source before writing the wrapper, so any API drift is absorbed in one place rather than scattered through call sites.

**Test scenarios:**
- Happy: draft→queued→syncing→synced round-trips through a real temp SQLite db.
- Happy: every row of the §4.4 mapping table asserted (parameterized test).
- Edge: offline at drain → stays queued, no crash; connectivity restored → drains in order.
- Error: `captures.create` throws → `syncFailed`; local retry re-drains; same `clientId` reused (idempotent server-side).
- Error: screenshot upload fails but mutation would succeed → whole capture stays queued (upload-then-create is atomic from the queue's view).
- Edge: projects snapshot survives relaunch; picker data available with network off.
- Renderer preview: matches backend renderer output for the same inputs (shared fixture file).

**Verification:** `swift test` green on macOS (plain CLT `swift test` is sufficient for this package — no Xcode project needed, TECH-SPEC §2a). The iOS-compile check (enforcing the no-AppKit rule) is a separate build using `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` set explicitly and an iOS SDK destination (the iOS SDK ships with Xcode 26.3, TECH-SPEC §2a) — plain `swift build` under Command Line Tools cannot target iOS. Run this locally in the one-shot build, or defer it to the `ci.yml` GitHub runner (U11) if a local iOS SDK build proves awkward to script.

---

### U6. macOS app shell + mock-first auth

**Goal:** Running MenuBarExtra app, XcodeGen-generated project, with account state built and tested against `MockAuthProvider`.

**Requirements:** R5, R6 (launch-at-login).

**Dependencies:** U5 only — no auth-spike gate (TECH-SPEC §2a/§9).

**Files:**
- Create: `apps/macos/project.yml` (full XcodeGen spec, TECH-SPEC §3a: `Whistle` app target — macOS 14 deployment target, entitlements per TECH-SPEC §4.3, Info.plist usage strings, SPM deps `WhistleCore` (local path), `KeyboardShortcuts`, `Sparkle`, `convex-swift`, the Auth0 auth package, all pinned per U5's pinning note; `SWIFT_VERSION = 5`, TECH-SPEC §4.1 concurrency note; `WhistleTests` target)
- Create: `apps/macos/Whistle/{WhistleApp,StatusItemController,AuthController}.swift`, `apps/macos/Whistle/Auth/{Auth0AuthProvider,MockAuthProvider}.swift`
- Test: `apps/macos/WhistleTests/AuthControllerTests.swift` (state transitions against `MockAuthProvider`)

**Approach:** run `xcodegen generate` from `apps/macos/` to produce `Whistle.xcodeproj` from `project.yml` — never hand-author the `.pbxproj`. All builds/tests for this target use `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` set explicitly (TECH-SPEC §2a), never plain `swift build`. Custom `NSStatusItem` (not `MenuBarExtra`): left-click starts capture (wired fully in U8; placeholder action here), right-click `NSMenu` with History, Settings, account, Check for Updates, Quit. `SMAppService` for launch-at-login. `AuthController` is built against the `ConvexService` auth-provider protocol (U5); Auth0 config (domain/client ID) is read from env/xcconfig placeholders — never hardcoded — and `Auth0AuthProvider` is wired but not exercised by any automated test in this unit. All automated tests, and the one-shot smoke run, use `MockAuthProvider`.

**Test scenarios:**
- Happy: signed-out → mock sign-in flow → `users.ensure` called once → signed-in menu state.
- Edge: token refresh failure (simulated via the mock) → signed-out state with re-auth prompt, no crash.

**Verification:** app compiles and signs via `xcodegen generate` + `xcodebuild`; `xcodebuild test` green against `MockAuthProvider`; smoke check — process starts, status item registers, mock-signed-in state reached (TECH-SPEC §2a Definition of done). Real Auth0 tenant provisioning and a real login round-trip are `docs/MANUAL-QA.md` items (TECH-SPEC §9), not part of this unit's automated acceptance.

---

### U7. Screenshot + transcription services

**Goal:** The two capture inputs, production-grade, per TECH-SPEC §4.1/§4.1b.

**Requirements:** R1.

**Dependencies:** U6.

**Files:**
- Create: `apps/macos/Whistle/Services/{ScreenshotService,TranscriptionService,SpeechAnalyzerTranscriber,LegacySpeechTranscriber,AudioEngineTap}.swift`
- Test: `apps/macos/WhistleTests/{TranscriptStitchingTests,ScreenshotEncodeTests}.swift`

**Approach:** exactly §4.1b: committed + live segments, task cycling on `isFinal`/error with the audio tap never stopping; per-OS model availability paths. `TranscriptionService` is implemented as an actor (TECH-SPEC §4.1 concurrency note) so audio-tap callbacks and start/stop calls serialize safely. Screenshot: display-under-cursor, downscale 2000 px, JPEG q0.8, `nil` on TCC denial. `LegacySpeechTranscriber` (`SFSpeechRecognizer`) is the tested shipping path; `SpeechAnalyzerTranscriber` (macOS 26+) compiles behind `#available` against the macOS 26 SDK present in Xcode 26.3 and is exercised only against a fake recognizer here — it is tagged runtime-unverified in `docs/MANUAL-QA.md` (U12), since this host (15.7.3) cannot run it.

**Test scenarios:**
- Happy: stream of volatile updates then `isFinal` → committed text extends, live resets (fake recognizer).
- Edge: task error mid-utterance → new task starts, committed text preserved, no dropped join-space or duplicated words.
- Edge: three consecutive finalizations → correctly ordered concatenation.
- Edge: `stop()` mid-live-segment → live hypothesis included in final text.
- Happy: encode 5K display image → ≤2000 px long edge, <1 MB.
- Error: TCC denied → returns nil, no throw.
- Happy (SpeechAnalyzer path): same segment-stitching scenarios above re-run against a fake `SpeechAnalyzer` recognizer, compiled behind `#available` — proves the code compiles and the contract holds; does not prove real macOS 26 runtime behavior.

**Verification:** `xcodebuild test` green for both transcriber implementations against their fakes. Real 6-minute continuous dictation on physical macOS 14 and macOS 26 hardware is a `docs/MANUAL-QA.md` item (TECH-SPEC §2a) — this host cannot run either. The `docs/MANUAL-QA.md` entry for `SpeechAnalyzerTranscriber` is explicitly labeled runtime-unverified — requires a macOS 26 machine.

---

### U8. Capture panel UX

**Goal:** The sub-300 ms capture surface, wired end-to-end into the local queue, with both panel focus modes built.

**Requirements:** R1; PRD error-table rows for mic/speech/screen degradation.

**Dependencies:** U7.

**Files:**
- Create: `apps/macos/Whistle/Capture/{CapturePanelController,CaptureView,CaptureViewModel,ProjectPicker}.swift`, hotkey registration (KeyboardShortcuts, default ⌥⇧W)
- Test: `apps/macos/WhistleTests/CaptureViewModelTests.swift`

**Approach:** **build both panel modes** (TECH-SPEC §4.1) — do not pick one during implementation. Default: non-activating `NSPanel` + `canBecomeKey` override, anchored beneath the status item, hosting `CaptureView` via `NSHostingView` with an explicit `makeFirstResponder` call on the hosting view after `orderFront` (the known-good pattern for SwiftUI focus inside a key-capable panel). Fallback: an activating panel that records and restores `NSWorkspace.shared.frontmostApplication` around show/dismiss. A `UserDefaults` debug flag selects the active mode at launch; both must compile and pass the same `CaptureViewModel` tests. Triggered identically by hotkey and status-item left-click in either mode. Panel header carries History + Settings icon buttons (the panel is the app's home surface — there is no left-click dropdown menu). Screenshot fired before panel show; submit → `CaptureStore` → close (no network on this path, ever). Also wires the entry point for "Duplicate as new capture" (TECH-SPEC §4.1 `CaptureViewModel`/`HistoryWindow` rows, used by U9): accepting an optional pre-fill and a request to focus the project picker.

**Test scenarios:**
- Happy: submit with transcript+notes+screenshot+project → correct `CaptureDraft` queued, panel closed. Run against both panel modes.
- Edge: submit disabled when transcript, notes, and screenshot all empty; enabled for screenshot-only (auto-note injected: "screenshot-only capture" — client-side, recorded in `notes`).
- Edge: screenshot removed → draft has nil screenshot.
- Edge: hotkey while panel open → focuses existing panel, no second screenshot.
- Edge: Esc with content → confirm; Esc empty → close.
- Error: mic denied → type-only mode flag set, panel still opens.
- Happy: last-used project preselected; selection updates `app_state`.
- Happy: opening with a pre-fill (duplicate-as-new-capture path) populates transcript/notes/screenshot and focuses the project picker, with a freshly minted `clientId`.

**Verification (one-shot acceptance):** `xcodebuild test` green for `CaptureViewModelTests` under both panel-mode flag settings; app builds and launches with each mode selectable via the debug flag. Instrumented trigger→panel-interactive timing (<300 ms target) and "typing lands in the panel while the previous app stays active" are `docs/MANUAL-QA.md` items (TECH-SPEC §2a) — real timing and real frontmost-app behavior need a physical machine and a human observer. Which panel mode feels right in practice is also a `docs/MANUAL-QA.md` line item (flip the flag, compare, record the choice).

---

### U9. History, status, ready lifecycle, notifications

**Goal:** Live history in the History window with §4.4 chips, the ready-state lifecycle (opened/archived, ready-indicator), "Duplicate as new capture," plus routed notifications (notifications are the in-flight status channel — there is no persistent status menu).

**Requirements:** R3, R4.

**Dependencies:** U8, U3.

**Files:**
- Create: `apps/macos/Whistle/{History/HistoryWindow,History/HistoryRow,NotificationService}.swift`
- Test: `apps/macos/WhistleTests/NotificationRoutingTests.swift`

**Approach:** subscribe `captures.listRecent`; merge with local pending rows via `StatusPresentation` (single source for chips). Notifications fire on observed transitions only (track last-seen status per clientId to avoid re-fires on relaunch). Opening a capture's deep link — from a History row or a notification — calls `captures.markOpened` (TECH-SPEC §7); `HistoryRow` visually de-emphasizes rows with `openedAt` set and offers an archive/dismiss affordance that calls `captures.archive` (archived rows leave the default `listRecent`/`list` view, per a filter, not a delete). `StatusItemController` (U6) renders a ready-indicator dot/badge whenever ≥1 capture is `ready` and unopened; this unit is responsible for computing that count from the same subscription and updating the icon. Each row also offers "Duplicate as new capture," which opens the U8 capture panel pre-filled with this row's transcript/notes/screenshot and the project picker focused, minting a new `clientId` — the recovery path for "submitted to the wrong project" or "content came out garbled" (no new capture machinery; this reuses U8's pre-fill entry point).

**Test scenarios:**
- Happy: transition →`ready` fires notification with question count; click opens deepLink and calls `captures.markOpened`.
- Happy: →`failed`/`auth` notification routes to Settings; →`failed` other offers Retry (calls `captures.retry`).
- Edge: →`readyUnverified` uses "status unknown" copy, not success copy.
- Edge: app relaunch with existing `ready` rows → no duplicate notifications.
- Integration: local `syncFailed` row shows local-retry affordance; server `failed` shows server-retry.
- Happy: opening a History row's deep link patches `openedAt`; the row visually de-emphasizes; the ready-indicator count decrements; opening it again does not re-patch or re-decrement.
- Happy: archiving a row calls `captures.archive`; row disappears from the default History view.
- Happy: "Duplicate as new capture" on a row opens the capture panel pre-filled with that row's content, project picker focused, and a `clientId` distinct from the original.
- Edge: ready-indicator shows nothing when zero unopened-ready captures exist; shows a count/dot as soon as one transitions to `ready`.

**Verification:** `xcodebuild test` green (`NotificationRoutingTests` plus the ready-lifecycle scenarios above). A live end-to-end walk — a submitted capture visibly progressing Queued→Creating→Agent working→Ready in the History window, with the Ready notification firing once against the real dev backend — is a `docs/MANUAL-QA.md` item (TECH-SPEC §2a): it requires a live Conductor run and a human watching the UI update in real time.

---

### U10. Onboarding + settings

**Goal:** PRD F5 complete: reordered wizard (sign-in → combined permission screen → API key → project → test capture → screenshot upsell), key validation, template editor with lint.

**Requirements:** R5.

**Dependencies:** U9.

**Files:**
- Create: `apps/macos/Whistle/{Onboarding/OnboardingWindow,Onboarding/PermissionStep,Settings/SettingsWindow,Settings/TemplateEditor}.swift`
- Test: `apps/macos/WhistleTests/OnboardingGatingTests.swift`

**Approach:** step gating and order per PRD F5.1 (reordered): (1) sign in; (2) **one combined** mic+speech permission screen with per-permission status rows (not two separate explainer screens) — screen-recording is deliberately not in this gated step; (3) API key + inline validation via `conductor.validateKey`, step doesn't advance until valid; (4) default project — auto-selected with no user-facing step when the account has exactly one project, otherwise a picker; (5) guided test capture; (6) screen-recording offered as a post-first-capture upsell ("Add screenshots to future captures"), not a blocking wizard step, since capture already degrades gracefully without it (PRD error/edge table). The hotkey gets a one-line "Your hotkey is ⌥⇧W — change" affordance on the test-capture screen rather than its own step. Per-OS speech-model step nested inside step 2 (§4.1b). Wizard progress (current step, per-permission grant state) persists across app relaunch — required because the screen-recording grant (now post-onboarding) can itself force a relaunch, and any relaunch during the earlier gated steps must not lose progress either. SettingsWindow also carries the agent picker (claude/codex/cursor) and optional model string, saved via `settings.update` (PRD F5.2). Template editor: plain text + variable legend + live preview via WhistleCore's `TemplatePreview` (kept output-identical to the backend `promptRenderer.ts` via the shared fixture file) + reset + a **lint check** that warns inline when the template's "How to end" contract block is missing (question extraction in `pipeline.watch`, TECH-SPEC §6, silently breaks without it).

**Test scenarios:**
- Happy: all-granted path reaches test capture in the new order; completion flag persists.
- Edge: each permission denied on the combined screen → wizard proceeds with degraded-mode messaging (never hard-blocks except sign-in and API key).
- Error: invalid key → inline error, step doesn't advance.
- Happy: account with exactly one project → project step is skipped/auto-selected, no picker shown.
- Happy: account with multiple projects → picker step shown as before.
- Happy: template edit → save → `templates.update` called; reset → default restored.
- Happy: template edit that removes the "How to end" block → lint warning shown inline; saving is still allowed (warn, don't block) but the warning persists until the block is restored.
- Edge: wizard killed/relaunched mid-flow (after step 2, before step 5) → resumes at the correct step with earlier grants intact.
- Happy: screenshot upsell is shown after the first successful test capture, not before; declining it does not block completion.

**Verification:** `xcodebuild test` green (`OnboardingGatingTests`). A live fresh-macOS-user-account walk — wizard → real capture → Ready, under 5 minutes (PRD activation metric) — is a `docs/MANUAL-QA.md` item (TECH-SPEC §2a): it requires a real account, real permission grants, and a human timing the run.

---

### U11. Distribution

**Goal:** Signed DMG built locally (notarized when credentials allow), Sparkle wired with locally-generated keys, all three CI workflows authored, `SECRETS.md` documenting what's still needed for a full CI release.

**Requirements:** R6.

**Dependencies:** U10.

**Files:**
- Create: `.github/workflows/{ci.yml,release.yml,backend-deploy.yml}`, `apps/macos/scripts/package-dmg.sh`, Sparkle integration in app target, appcast route in `apps/web` (note: read `node_modules/next/dist/docs/` before touching `apps/web`, per `AGENTS.md` — this applies here same as everywhere else in the Next.js app), `SECRETS.md` (repo root)

**Approach:** per TECH-SPEC §10. Sign the DMG locally with the pre-authorized "Developer ID Application: Nabeel HYATT (73JZ8HJ79F)" identity (TECH-SPEC §2a). Attempt full local notarize + staple using `NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`/`NOTARY_KEY_PATH` from `.env.local` (present for this run). Every credentialed step in `package-dmg.sh` and in `release.yml` — notarization, CI codesigning, Sparkle signing, Sentry init — must check for its required env var/secret first and skip cleanly with a logged reason when absent, rather than fail; this makes the same script/workflow correct now (most credentials present locally) and after cloning to CI (no Actions secrets exist yet). Generate the Sparkle EdDSA keypair locally (`generate_keys`); embed the public key in `Info.plist`; do not commit the private key. Author `SECRETS.md` listing exactly what must be added as GitHub Actions secrets before `release.yml` can run a full signed/notarized/published release: the Developer ID cert as a base64 `.p12` + password, the notary API key (ASC key id/issuer/`.p8`), the Sparkle EdDSA private key, and `SENTRY_DSN`. Sentry SDK init must no-op cleanly when `SENTRY_DSN` is absent or empty — verify this explicitly, since the one-shot build has no DSN.

**Test scenarios:** Test expectation: none — infra; verification is the test.

**Verification:** local signed DMG produced; notarize+staple succeeds (credentials present) or is skipped with a logged reason if they were absent; `ci.yml`/`release.yml`/`backend-deploy.yml` are syntactically valid and `ci.yml` runs green on a PR (SwiftLint + `xcodebuild test`); `SECRETS.md` accurately lists every credential `release.yml` still needs. Clean-machine Gatekeeper install and a real Sparkle vN→vN+1 update are `docs/MANUAL-QA.md` items (TECH-SPEC §2a) — both require a second machine or a clean environment and cannot be verified from this host in the one-shot run.

---

### U12. Automated fixes + author `docs/MANUAL-QA.md`

**Goal:** Fix everything the automated suites catch, then author the complete `docs/MANUAL-QA.md` checklist from the PRD "Error & edge states" table and every deferred verification named in units U1–U11.

**Requirements:** all.

**Dependencies:** U11.

**Files:** across app; fixes only, no new features. Create: `docs/MANUAL-QA.md`.

**Approach:** first, run every automated suite (`swift test` for `whistle-core`; `xcodebuild test` for the app target; the vitest/convex-test matrix for the backend) and fix anything failing — this is the only place in this unit new code should change. Then walk the PRD "Error & edge states" table row by row **on this host OS (macOS 15.7.3)** — not the two-OS (14/26) walk assumed by earlier drafts, since only one OS is available here — verifying each row is either automated-test-covered (cite the test) or, where it requires a human/hardware/TCC/live-network condition this host or an unattended run can't produce, adding it as a `docs/MANUAL-QA.md` item with clear reproduction steps. Compile `docs/MANUAL-QA.md` from every deferred item named across this plan: U6 real Auth0 login; U7 real dictation on macOS 14 and macOS 26 (with `SpeechAnalyzerTranscriber` explicitly tagged runtime-unverified — requires a macOS 26 machine); U8 300 ms timing, frontmost-app-preserved check, and the panel-mode flag comparison; U9 live end-to-end Queued→Ready walk; U10 fresh-account 5-minute activation; U11 Gatekeeper clean-machine install and Sparkle vN→vN+1 update; plus the PRD table rows themselves that need a human. Do not summarize or abbreviate these — compile them verbatim as actionable checklist items (TECH-SPEC §2a Definition of done).

**Test scenarios:** the PRD table plus the per-unit deferred-verification list above are the checklist — walk them on the host OS, recording which are automated-covered vs. manual, and write the manual ones into `docs/MANUAL-QA.md` with concrete repro steps.

**Verification:** all automated suites green; `docs/MANUAL-QA.md` exists, is non-empty, and every item deferred by TECH-SPEC §2a and by U6–U11 above appears in it verbatim.

---

## System-Wide Impact

- **Interaction graph:** capture path (hotkey→panel→queue) is fully decoupled from network; only SyncEngine and the pipeline touch I/O. Status flows one way: pipeline → captures table → subscription → UI/notifications.
- **Error propagation:** Conductor errors normalize in `conductorFetch` → `errorCode` on the record → §4.4 mapping → UI/notification. No layer invents its own error strings.
- **State lifecycle risks:** the §6 design rules (idempotency guards, never-die-silently, watchdog) exist precisely because scheduled actions die invisibly; tests in U3 enforce them.
- **API surface parity:** `captures.create` contract is the iOS seam — changes to it require checking both the U5 SyncEngine and future clients.

---

## Risks & Dependencies

Carried in TECH-SPEC §14 (authoritative table). Execution-order note: U4's Conductor e2e proof is the only unit that can invalidate a design decision (the pipeline's handling of the six API unknowns) — schedule it early (in parallel with U2) and treat its write-up as a gate for U3, not for U2 or U6.

---

## Sources & References

- **Origin:** [docs/PRD.md](../PRD.md)
- Design companion: [docs/TECH-SPEC.md](../TECH-SPEC.md)
- API reference: [docs/CONDUCTOR-API.md](../CONDUCTOR-API.md) (live OpenAPI, fetched 2026-07-04)
- Prompt payload: [docs/PROMPT-TEMPLATE.md](../PROMPT-TEMPLATE.md)
- External: convex-swift, convex-swift-auth0, Convex file storage docs, KeyboardShortcuts, GRDB, Sparkle 2, XcodeGen
