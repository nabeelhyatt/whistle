---
title: "Flaky macOS controller tests that observe real NSPanel state once presentation goes async"
date: 2026-08-04
category: docs/solutions/test-failures
module: "apps/macos (CapturePanelController + WhistleTests)"
problem_type: test_failure
component: test_infrastructure
symptoms:
  - "Controller tests that passed for months start failing intermittently after a UI side-effect is made asynchronous, with no change to the tests themselves"
  - "Whistle_waitUntil { controller.isPanelOpen } times out (condition never met within 1s), worst in .activating panel mode"
  - "A pre-existing, untouched test (e.g. testSubmitQueuesDraftAndClosesPanelUnderBothModes) also starts flaking"
  - "XCTAssertTrue(controller.isPanelOpen) fails at the end of a test after the panel was observed open earlier in the same test"
root_cause: race_condition
resolution_type: code_fix
severity: high
tags:
  - flaky-test
  - appkit
  - nspanel
  - headless-xctest
  - async-presentation
  - test-seam
  - xctest
---

# Flaky macOS controller tests that observe real NSPanel state once presentation goes async

## Problem

`CapturePanelControllerTests` drives a **real `NSPanel`** and asserts on its visibility through `controller.isPanelOpen`. That was reliable for as long as the panel was presented *synchronously* inside `trigger()`. When the capture-panel fix (PR #39) deferred presentation to a screenshot-request acknowledgement (`showPanel` now runs from a `Task` a few ms later), a broad set of controller tests — including pre-existing ones nobody touched — went intermittently red: `Whistle_waitUntil { controller.isPanelOpen }` would time out, and late `XCTAssertTrue(isPanelOpen)` checks would fail even after the panel had been observed open earlier in the same test.

## Root Cause

In a headless XCTest host the app-host process can't let a panel truly hold keyboard focus, so AppKit delivers a **spurious `windowDidResignKey`** immediately after the panel is ordered front. `CapturePanelController`'s resign handler is the click-away dismissal, so it calls `dismissPreservingDraft()` and the panel disappears.

With *synchronous* presentation the test read the panel's state right after `trigger()` returned — before the runloop delivered that resign event — so it never saw the dismissal. With *asynchronous* presentation, `showPanel` runs during the test's `Whistle_waitUntil` polling loop (which yields via `Task.sleep`), giving AppKit's event delivery a window to interleave: the panel is shown, then resign-dismissed, all between two 10ms polls. The instrumented log made it unambiguous:

```
WDIAG complete gen=2 cur=2 pending=true -> WDIAG showPanel   (panelPresented = true)
WDIAG windowDidResignKey                                     (-> dismissPreservingDraft -> panelPresented = false)
Whistle_waitUntil { isPanelOpen }  X  timed out
```

The bug was never in the feature logic — it was **observing real, nondeterministic AppKit window state in a headless process.**

## What Didn't Work

1. **Track presentation in a `panelPresented` flag instead of reading `NSPanel.isVisible`.** Necessary (a no-op seam later depends on it) but insufficient on its own: the *real* `windowDidResignKey` still fired and set the flag false via `dismissPreservingDraft`. Went from 9/20 failing to still-flaky.
2. **Detect XCTest at runtime and suppress the resign dismissal** — first `ProcessInfo…environment["XCTestConfigurationFilePath"]` (not reliably set in the app-host process), then `NSClassFromString("XCTestCase") != nil`. This got to ~20/22 but was still flaky *and* put test-detection into a production behavior path (a code smell two reviewers would later flag).
3. **Brute-force looping the suite 20x** to "prove" a fix. This surfaced the flake but never removed it, and — because the test host is the full `Whistle.app` — every one of those app-host launches re-prompted the login keychain (see the sibling keychain learning). A loop is a detector, not a fix.

## Solution

Inject the controller's raw AppKit window side-effects behind a small closure-struct seam, `CaptureWindowOps`, with real defaults; controller tests pass `.noop`:

```swift
public struct CaptureWindowOps {
    public var orderFrontRegardless: @MainActor (NSPanel) -> Void = { $0.orderFrontRegardless() }
    public var makeKey: @MainActor (NSPanel) -> Void = { $0.makeKey() }
    public var makeKeyAndOrderFront: @MainActor (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }
    public var orderOut: @MainActor (NSPanel) -> Void = { $0.orderOut(nil) }
    public var addGlobalClickMonitor: @MainActor (@escaping (NSEvent) -> Void) -> Any? = { /* NSEvent… */ }
    // …activateApp / frontmostApp / activate / removeMonitor / makeFirstResponder
    public static var noop: CaptureWindowOps { /* every closure a no-op; monitor returns nil */ }
}
```

`showPanel`/`focusExistingPanel`/`dismissPreservingDraft`/`tearDownPanel` call through `windowOps` instead of touching AppKit directly. With `.noop`, **no real `NSPanel` is ever shown or made key** → no key transition → no spurious `windowDidResignKey` → presentation is observed purely through the deterministic, main-actor `panelPresented` flag (`isPanelOpen`). The XCTest-detection hack came back out of production. `CapturePanelController.swift` carries the seam; controller-test construction passes `windowOps: .noop`.

Result: the full controller suite passes in a single run (~1.1s, nothing near the 1s timeout), and CI's macOS suite is green. No 20x loop needed — the race is now structurally impossible, not merely improbable.

## Why This Works

The struct is non-`@MainActor` with `@MainActor`-typed closure properties, so its `init()` is callable from the (nonisolated) init default-argument context while the closures still run on the main actor where the controller invokes them. Because the test injects no-ops, the only observable of "did the panel present" is the controller's own tracked state — which changes *only* on the controller's explicit calls, never on an AppKit event the headless host delivers unpredictably. This is the same principle the repo already applies everywhere else: **protocol/closure fakes over real hardware** (AGENTS.md, "Testing" — 16 injected protocols exist for exactly this reason).

## Prevention

- **When you make a UI or hardware side-effect asynchronous, every test that observes the *real* side-effect's state (window visibility, key/focus, audio, TCC) becomes a race in a headless host.** The old sync tests were only reliable by accident of read-before-runloop timing. Inject the side-effect behind a seam and assert on tracked state instead.
- **Never put runtime test-detection (`NSClassFromString("XCTestCase")`, an env var) into a production behavior path** to paper over a test-host artifact. It's a smell, it's unreliable in the app-host process, and it leaves the production code lying about what it does. Inject a seam the test controls instead.
- **A deterministic seam beats a 20x loop.** The mandated 20x loop (AGENTS.md) proves a *timing race exists*; it never removes one, and looping the app-hosted suite re-launches `Whistle.app` (and re-prompts the keychain) every iteration. Reach for the seam first; then a single green run is sufficient evidence.
- Keep `isPanelOpen` / `hasPreservedDraft` / `isCaptureSessionActive` as tracked-state accessors, not `NSPanel.isVisible` reads — that is what makes them safe to observe from an async test.

## Related Issues

- PR #39 (merged) — the capture-panel present-after-ack fix that introduced the async window and this seam.
- `docs/solutions/test-failures/async-fake-sleep-race-flaky-tests.md` — sibling flake in the same suite (fixed sleep vs un-awaited Task); same "wait on the observable condition, deterministically" moral.
- PR #40 (merged) + AGENTS.md "Testing" — the login-keychain prompt that the 20x app-host loop multiplied, now gated by `WHISTLE_TESTING`.
