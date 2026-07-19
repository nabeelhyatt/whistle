---
title: "Backend parsed an invented Conductor message shape — live replies were never recognized"
date: 2026-07-19
category: docs/solutions/integration-issues
module: "backend/pipeline (Conductor reply reconciliation)"
problem_type: integration_issue
component: service_object
symptoms:
  - "Captures reach agentWorking but never ready; every capture drifts to readyUnverified at the 60-minute watch deadline"
  - "Backend watch polls see the agent's reply in the session message list but findAgentReplyAfterOurs never matches it"
  - "All backend tests pass while production never recognizes a single live reply"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags:
  - conductor
  - message-parsing
  - correlation
  - live-fixture
  - mock-fidelity
  - pipeline
---

# Backend parsed an invented Conductor message shape — live replies were never recognized

## Problem

The Convex pipeline's reply-watcher (`packages/backend/convex/pipeline.ts`) was written against an *assumed* Conductor message shape — top-level `id == clientId` with assistant text directly in `content` — while the live Conductor list API returns a nested envelope: its own generated top-level `id`, the client's UUID lowercased under `content.id`/`content.turnId`/`content.userMessageId`, and assistant text under `content.rawPayload.message.content[].text`. Live replies never matched, so completed captures sat at `agentWorking` until the `readyUnverified` fallback. The repo's own docs had marked the real shape as "unresolved" — and code shipped anyway.

## Root Cause

Contract assumed instead of captured. The parser and 100% of its tests validated the invented shape; there was no live fixture, so the tests proved the parser against the assumption, not against Conductor. (This is the backend twin of the client-side decode lesson in [history-window-stuck-queued-convex-decode-mismatch](history-window-stuck-queued-convex-decode-mismatch.md) — both halves of the same "Queued forever" symptom, both caused by never testing against a real payload.)

## Solution

Shipped across PR #14 (parser rewrite) and PR #16 (review follow-ups):

- A **sanitized live fixture** (`packages/backend/convex/__tests__/fixtures/conductor-messages-live.json`) captured from a real session became the test anchor.
- `extractMessageText` traverses the nested envelope (`content.rawPayload.message.content[].text`) while still supporting simpler containers.
- Correlation helpers (`messageIdentifiers`/`messageMatchesClient`) match the client UUID case-insensitively across top-level `id`/`messageId` and nested `content.id`/`turnId`/`userMessageId`; `findAgentReplyAfterOurs` accepts only a *correlated* assistant reply with non-empty text — never "any later agent event".
- Event-only records are filtered by **denylisting** known non-reply `rawPayload.type` values (`system`/`result`/`user`) rather than allowlisting `"assistant"` — an allowlist from one Claude fixture would silently strand Codex/Cursor agents (whose reply `type` strings are uncaptured); unknown types are accepted with a `console.warn` so a new agent's shape shows up in logs instead of as a silent 60-minute drift.
- The test suite's MockConductor now emits the **live nested shape by default**, with exactly one explicit legacy-shape test — so integration tests exercise what production sees.

## Prevention

Before writing a parser for an external API response, capture a real payload as a sanitized fixture and make it the test's source of truth — and make the *mock's default* the live shape, not the convenient one. If a contract is documented as "unresolved," that is a blocker for shipping the parser, not a footnote. When gating on a vendor's type/shape enum observed from a single integration (one agent, one tenant), prefer denylisting known negatives + warn-on-unknown over allowlisting the one observed positive.

## Related Issues

- PR #14 (merged) — parser rewrite against the live fixture; PR #16 (merged) — denylist gating + live-shape mock default.
- Open follow-up (docs/BACKLOG.md candidate): capture real Codex/Cursor fixtures to close the reply-type gap properly.
- [history-window-stuck-queued-convex-decode-mismatch](history-window-stuck-queued-convex-decode-mismatch.md) — the client-side half of the same symptom and the same test-fidelity lesson.
