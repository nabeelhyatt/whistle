---
title: "Flaky macOS tests from fixed sleeps racing un-awaited Tasks in fakes"
date: 2026-07-19
category: docs/solutions/test-failures
module: "apps/macos WhistleTests (fakes + async assertions)"
problem_type: test_failure
component: test_infrastructure
symptoms:
  - "A test passes locally and on rerun but fails intermittently on CI runners with no code change"
  - "XCTAssertEqual on a fake's call counter reads N-1 instead of N (assert-before-increment)"
  - "The same test blocks unrelated PRs repeatedly (this pattern failed 6 CI runs across 4 PRs in one day)"
root_cause: race_condition
resolution_type: test_fix
severity: medium
tags:
  - flaky-test
  - task-race
  - fixed-sleep
  - deterministic-waiter
  - xctest
  - ci
---

# Flaky macOS tests from fixed sleeps racing un-awaited Tasks in fakes

## Problem

Two Whistle test suites exhibited the same intermittent CI failure shape: production code fires work on a spawned, un-awaited `Task` (e.g. `CapturePanelController.trigger()` launching the screenshot capture), the fake records the call asynchronously (incrementing a counter inside that Task, or inside its own spawned Task), and the test waits a **fixed sleep** (20ms) before asserting the counter. On loaded GitHub Actions macOS runners the Task hadn't run yet — assert-before-increment. `CapturePanelControllerTests.testDismissPreservesDraftAndReopenRestoresItWithoutNewScreenshot` alone failed six CI runs across four unrelated PRs in a single day, each passing on rerun; `TranscriptStitchingTests` had the same class of race on a fake's `startTaskCallCount`.

## Root Cause

A fixed sleep encodes an assumption about scheduler latency that CI runners violate. Any test asserting on state mutated by a Task the test does not await is a race; the sleep just sets the odds.

## Solution

Replace the sleep with a **deterministic waiter on the observable state** — two repo precedents, both test-only:

- Poll-based: `waitForScreenshotCount(1, counter:)` built on the existing `Whistle_waitUntil` poller (PR #18) — wait until the counter reaches the target or time out loudly.
- Continuation-based: the fake exposes `waitForStartTaskCallCount(_:)`, resuming a `CheckedContinuation` when the Nth call lands (the `TranscriptStitchingTests` fix), so the test suspends until the fake *observes* the call.

Proven by running the fixed test 20+ consecutive times (`xcodebuild build-for-testing` once, then repeated `test-without-building -only-testing:...`). After PR #18 merged, every subsequent macOS CI run in the session passed first-try.

## Prevention

- In tests, never pair "spawned Task in production or fake" with "fixed sleep then assert." Wait on the condition itself: poll with a bounded timeout, or have the fake expose an awaitable signal for its Nth call.
- When a test fails on CI and passes on rerun with zero code change more than once, stop rerunning and fix it deterministically — a recurring flake taxes every PR (here: six red CI runs in one day, each costing a rerun cycle on an unrelated change).
- Prove the fix by looping the single test 20+ times via `test-without-building`, not by one green run.

## Related Issues

- PR #18 (merged) — capture-panel fix; the transcript-test fix shipped inside PR #15's commit series.
