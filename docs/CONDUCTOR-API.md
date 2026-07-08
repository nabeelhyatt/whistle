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
| `POST /v0/sessions/{sessionId}/messages` | Send prompt to the agent | Body: `{ message (minLength 1), messageId? }`. `messageId` is client-supplied — **use the capture's clientId for idempotency**. → `{ messageId, state: queued\|sent }`. `queued` implies messages sent before the workspace is ready are held — verify empirically (U4). |
| `GET /v0/sessions/{sessionId}/status` | Poll agent activity | → `{ status: idle\|working\|error, errorMessage?, ... }`. `idle` after our message ⇒ first pass done. |
| `GET /v0/sessions/{sessionId}/messages` | Read conversation | → `{ data: [{ id, sessionId, sessionIndex, type, content, receivedAt }] }`. `content` is untyped (`{}` in spec) — parse defensively; take the last agent-typed entry for summary/questions extraction. |

Two more endpoints are used only for **orphan adoption** (recovering a workspace created by a pipeline run that died before recording ids — see TECH-SPEC §6 step 3a): `GET /v0/projects/{id}/workspaces` (find by the `#<clientId>` name tag) and `GET /v0/workspaces/{id}/sessions` (recover the session id).

## Endpoints available but unused by the shipping v1 app

`GET /v0/projects/{id}`, `GET /v0/workspaces/{id}`, `POST /v0/workspaces/{id}/rename`, `POST /v0/sessions` (extra sessions in an existing workspace; body requires `{ workspaceId, agent }`), `GET /v0/sessions/{id}`, `POST /v0/sessions/{id}/rename`, `GET /v0/messages/{id}`, `POST /v0/sessions/{id}/cancel`.

Potential later uses: `cancel` for aborting a runaway first pass; `rename` to sync workspace names if capture titles become editable.

**`POST /v0/workspaces/{id}/archive`** is not called by the shipping v1 app, but it **is used by the Conductor e2e script** (`packages/backend/scripts/e2e-conductor.ts`, U4): every workspace the script creates is named `whistle-e2e-*` and archived via this endpoint when the script finishes, so the shared scratch project doesn't accumulate throwaway workspaces run over run. Its next planned product use is Phase 1.1's "Archive workspace from History" action (PRD Phased delivery).

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

## Known unknowns (verify in U4, then update this doc)

U4's script reads `CONDUCTOR_API_KEY` and `CONDUCTOR_SCRATCH_PROJECT_ID` from `.env.local` at the repo root (TECH-SPEC §2a); every workspace it creates is named `whistle-e2e-*` and archived (above) when the script finishes. If `CONDUCTOR_API_KEY` is absent when U4 runs, all six unknowns below are recorded as "unresolved — pipeline safe under either answer per TECH-SPEC §6 guards," and the rest of the build continues rather than stalling — the pipeline's idempotency guards are designed to be correct regardless of how these resolve.

1. Whether `POST .../messages` succeeds (state `queued`) while workspace `status = initializing`.
2. Rate limits / concurrent-workspace quotas — nothing in the spec; backoff conservatively.
3. Accepted `model` strings (spec is free-form). v1 omits `model` unless the user sets one.
4. Shape of message `content` for agent messages (spec is untyped). Capture a real fixture in U4 and pin it in tests.
5. Whether the workspace agent has outbound network access to fetch the screenshot URL (expected yes — agents can curl). If not, screenshots become history-only and the prompt's screenshot block is dropped. **Verified in two passes** to avoid a U4-before-U2 sequencing gap (U2 hasn't deployed Convex yet when U4 first runs): pass one tests outbound fetch with any public URL; pass two re-tests with a real Convex file URL once U2 has deployed, confirming the actual production URL shape works.
6. Whether `POST .../messages` **deduplicates** on a repeated client-supplied `messageId` (the field existing proves storage, not dedupe). The pipeline does not rely on it either way: before any (re)send it lists session messages and skips if our `messageId` is already present (TECH-SPEC §6 step 4a). Verify by sending the same `messageId` twice in U4 and observing.
