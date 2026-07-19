---
title: "Project picker permanently empty — subscription-fed freshness gate starved the refresh"
date: 2026-07-19
category: docs/solutions/logic-errors
module: "WhistleCore/ProjectsSyncCoordinator"
problem_type: logic_error
component: service_object
symptoms:
  - "Capture panel's project picker shows no projects for a new account, forever"
  - "Settings 'Default project' dropdown offers only None"
  - "projects:refreshProjects never appears in backend logs — the client never calls it"
  - "Captures submit with an empty projectId and fail at workspace creation (GET /v0/projects//workspaces — 500)"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags:
  - freshness-gate
  - staleness
  - subscription
  - projects
  - onboarding
  - deadlock
---

# Project picker permanently empty — subscription-fed freshness gate starved the refresh

## Problem

For any brand-new account, the project picker never populated: `ProjectsSyncCoordinator.refreshIfStale()` (`packages/whistle-core/Sources/WhistleCore/ProjectsSyncCoordinator.swift`) gated the server-side `conductor.refreshProjects` call solely on the local snapshot's `fetchedAt` being older than one hour — but the coordinator's own `projects:list` subscription persists **every yield** as a fresh snapshot, including the *empty* list a new account's server cache legitimately returns. Sequence: sign in → subscription yields `[]` → snapshot persisted fresh-and-empty → user opens the capture panel → `refreshIfStale` sees a fresh snapshot and skips the refresh → the server-side project cache is never populated → picker empty → captures submit with `projectId: ""` and fail downstream.

## Root Cause

A freshness timestamp fed by one data path (the cache-read subscription) gated a different data path (the upstream fetch that actually populates the cache). "Fresh" and "populated" were conflated: an empty-but-recent snapshot is *fresh* by timestamp while being exactly the state that most needs a refresh. The unit test suite actually **encoded the bug** — the existing "skips when fresh" test used an empty snapshot and asserted no refresh call.

## Solution

Shipped in PR #15: `refreshIfStale` now treats an empty (or missing) snapshot as stale regardless of `fetchedAt` — an empty snapshot is never a reason to skip a cheap refresh. The silently-swallowed `try?` on the refresh call became a `do/catch` with an `NSLog` matching the codebase's failure-logging idiom. The bug-encoding test was fixed to use a non-empty snapshot, and a dedicated regression test asserts a fresh-but-empty snapshot *does* trigger the refresh.

## Prevention

When a staleness/freshness gate protects an expensive upstream fetch, ask: **can the cheap path refresh the timestamp without ever populating the data?** If the gated fetch is the only thing that can fill an empty state, emptiness must count as stale. And when writing "skips when fresh" tests for any gate, construct the *populated* fresh state explicitly — a test fixture that happens to be empty can silently pin the deadlock as intended behavior.

## Related Issues

- PR #15 (merged) — the fix, alongside the wire-decode root cause.
- Discovered live during the stuck-"Queued" saga's smoke test (new GitHub-login account); see [history-window-stuck-queued-convex-decode-mismatch](../integration-issues/history-window-stuck-queued-convex-decode-mismatch.md).
- docs/BACKLOG.md — "Local DB partitioning by account" (the adjacent account-split hazard that exposed this path).
