# Conductor API — integration reference

Verified against the live OpenAPI spec (`https://api.conductor.build/v0/openapi.json`, fetched 2026-07-04; title "Roundhouse public API" v0.0.1). All endpoints are marked `x-conductor-stability: experimental` — expect drift; keep every call inside `conductorClient.ts`.

## Auth

- Bearer token: `Authorization: Bearer <api-key>`.
- Users create keys at `https://app.conductor.build/users/api-keys`.
- Errors return a `StructuredError`: `{ code?, userMessage (required), debugMessage?, retryable?, source?, details?, underlying? }`. Honor `retryable` in the pipeline's backoff decision.

## Endpoints Whistle uses

| Method & path | Purpose | Notes |
|---|---|---|
| `GET /v0/projects?limit&offset` | List projects user can create workspaces in | → `{ data: [{ id, name, gitRemote }], offset, hasMore }`. Also used as the key-validation ping. |
| `POST /v0/workspaces` | Create workspace + first session | Body (exactly one of `projectId` \| `repositoryUrl`): `{ projectId, branch?, name?, agent?, model? }`. `agent ∈ claude\|codex\|cursor\|acp`. → `{ workspaceId, sessionId, deepLink }` (all required). `deepLink` opens the Conductor app. |
| `GET /v0/workspaces/{id}/status` | Poll workspace readiness | → `{ status: initializing\|ready\|sleeping\|archived\|deleted\|updating, lifecycleStep?, errorMessage?, updatedAt }`. |
| `POST /v0/sessions/{sessionId}/messages` | Send prompt to the agent | Body: `{ message (minLength 1), messageId? }`. `messageId` is client-supplied — **use the capture's clientId for idempotency**. → `{ messageId, state: queued\|sent }`. Messages sent before the workspace is ready ARE held (`queued`, 201 — verified live, U4 unknown #1), but a held message on a workspace whose init later fails is silently never delivered (U4; see unknown #4). |
| `GET /v0/sessions/{sessionId}/status` | Poll agent activity | → `{ status: idle\|working\|error, errorMessage?, ... }`. `idle` after our message ⇒ first pass done — **but only with an agent reply present**: observed live (U4), a session reads `idle` (not `error`) the entire time its workspace is initializing, and keeps reading `idle` after the workspace init fails and auto-deletes. `idle` alone proves nothing; TECH-SPEC §6's require-an-agent-reply guard is load-bearing. |
| `GET /v0/sessions/{sessionId}/messages` | Read conversation | → `{ data: [{ id, sessionId, sessionIndex, type, content, receivedAt }] }`. Live correlation and assistant-text fields are nested under `content`; see finding #4. `content` remains untyped in the spec, so parse defensively. |

Two more endpoints are used only for **orphan adoption** (recovering a workspace created by a pipeline run that died before recording ids — see TECH-SPEC §6 step 3a): `GET /v0/projects/{id}/workspaces` (find by the `#<clientId>` name tag) and `GET /v0/workspaces/{id}/sessions` (recover the session id).

## Endpoints available but unused by the shipping v1 app

`GET /v0/projects/{id}`, `GET /v0/workspaces/{id}`, `POST /v0/workspaces/{id}/rename`, `POST /v0/sessions` (extra sessions in an existing workspace; body requires `{ workspaceId, agent }`), `GET /v0/sessions/{id}`, `POST /v0/sessions/{id}/rename`, `GET /v0/messages/{id}`, `POST /v0/sessions/{id}/cancel`.

Potential later uses: `cancel` for aborting a runaway first pass; `rename` to sync workspace names if capture titles become editable.

**`POST /v0/workspaces/{id}/archive`** is not called by the shipping v1 app, but it **is used by the Conductor e2e script** (`packages/backend/scripts/e2e-conductor.ts`, U4): every workspace the script creates is named `whistle-e2e-*` and archived via this endpoint when the script finishes, so the shared scratch project doesn't accumulate throwaway workspaces run over run. Its next planned product use is Phase 1.1's "Archive workspace from History" action (PRD Phased delivery). Two live gotchas (U4): the endpoint 400s (`FST_ERR_CTP_EMPTY_JSON_BODY`) if you send `Content-Type: application/json` with an empty body — send `{}`; and archiving a workspace that already auto-transitioned to `deleted` (failed init, below) 404s — treat `deleted` as terminal-clean, not a cleanup failure. Archived/deleted workspaces are excluded from `GET /v0/projects/{id}/workspaces`.

**Workspace init failure (observed live, U4).** A workspace whose initialization fails (e.g. the project's stored git credentials are invalid) does not park in an error state: it **auto-transitions to `deleted`**, with the failure surfaced only as `errorMessage` on `GET /v0/workspaces/{id}/status` (e.g. `git fetch main exited with code 128: … Authentication failed`). Any `queued` message is silently never delivered, and the session's status keeps reading `idle` throughout. Observed `lifecycleStep` values while initializing: `preparing`, `building_snapshot`.

## Whistle call sequence

```
settings.setConductorKey ──► GET /v0/projects            (validate + cache)
capture submitted ─────────► POST /v0/workspaces          { projectId, name, agent }
                            └► POST /v0/sessions/{sessionId}/messages   { message, messageId }
                                 ├─ state queued|sent → OK
                                 └─ 4xx → poll GET /v0/workspaces/{id}/status
                                          until ready (20s interval, 15m cap) → resend
watch loop ────────────────► GET /v0/sessions/{sessionId}/status  (30s → 2m backoff, 60m cap)
        idle ──────────────► GET /v0/sessions/{sessionId}/messages → extract summary + questions
```

## Known unknowns — U4 answers (live runs, 2026-07-08)

U4's script (`packages/backend/scripts/e2e-conductor.ts`) ran twice against the live API using `CONDUCTOR_API_KEY` and `CONDUCTOR_SCRATCH_PROJECT_ID` from `.env.local` (TECH-SPEC §2a); each run created exactly one `whistle-e2e-*` workspace, and both ended terminal-clean (per-workspace status verified `deleted`; zero live `whistle-e2e-*` in the project listing). One caveat colors #4/#5: **in both runs the workspace failed initialization server-side** — the scratch project's ("ttl") stored GitHub credentials are invalid on Conductor's side (`git fetch main exited with code 128: … Authentication failed for 'https://github.com/Tabletop-Library/ttl.git/'`) — so no agent ever executed. The agent-dependent unknowns stay open until that project's git auth is reconnected; everything API-shaped got answered.

1. **Answered — yes.** `POST .../messages` while workspace `status = initializing` returns 201 `{ state: "queued" }`. Observed twice, at `lifecycleStep: "preparing"` and `"building_snapshot"`. But queuing is not delivery: a queued message on a workspace whose init fails is dropped silently (see #4 and the init-failure note above). The pipeline can send immediately after create; `pipeline.watch`'s agent-reply verification carries the rest.
2. **Not observed.** No rate-limit/quota-shaped headers (`*rate*`, `*limit*`, `*retry*`, `*quota*`) on any response — create, send, status polls, or listings — and no limit was hit at this run's volume (1 workspace, ~2 sends, ~15 polls/run). Still nothing in the spec; keep backing off conservatively.
3. **Not observed.** `model` strings untested — both runs omitted `model`, which is exactly v1's default behavior. Unchanged guidance: omit unless the user sets one; treat as free-form passthrough.
4. **Answered — live message shape captured 2026-07-17.** Top-level `id` is generated (`<sessionId>:<index>:0`) and top-level `messageId` is absent/null. The lowercased client UUID appears on the user event as `content.id`/`content.turnId`, and agent events link back through `content.userMessageId`/`content.turnId`. Agent streams include event-only records; actual assistant text is nested at `content.rawPayload.message.content[].text`. The sanitized regression fixture is `packages/backend/convex/__tests__/fixtures/conductor-messages-live.json`. The earlier empty-list finding still applies immediately after a queued send, so the 23505 duplicate-send handling in #6 remains load-bearing.
5. **Pass 1 inconclusive — blocked** by the same init failure: the outbound-`curl` probe message was queued but never delivered to an agent. Expected answer is still yes (Conductor agents can curl), but it is not yet proven. Pass 2 (post-U2, with a real Convex file URL and a fresh `whistle-e2e-*` workspace) is still planned and now also carries pass 1's burden and the #4 fixture capture — run it once the scratch project's GitHub credentials are fixed.
6. **Answered — no dedupe.** Re-POSTing the same `messageId` fails hard: HTTP 500 `{ code: "23505", userMessage: "duplicate key value violates unique constraint \"session_messages_queue_pkey\"" }` (raw Postgres unique-violation, no `retryable` field). Two implications, verified twice: the pipeline's pre-send message-list guard (TECH-SPEC §6 step 4a) is load-bearing, not belt-and-suspenders; and this 500 must **not** be classified as a retryable transient — a duplicate-send 500 means the first send already succeeded, so the correct move on any send-shaped 500 is to re-check the session's messages (step 4a) before ever resending, never blind-retry the POST.
