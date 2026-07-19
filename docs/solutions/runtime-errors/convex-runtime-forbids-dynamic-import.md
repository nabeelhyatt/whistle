---
title: "Convex runtime forbids dynamic import() — latent crash invisible to vitest"
date: 2026-07-19
category: docs/solutions/runtime-errors
module: "backend/pipelineInternal"
problem_type: runtime_error
component: service_object
symptoms:
  - "pipeline:submit fails every attempt with 'Uncaught TypeError: dynamic module import unsupported'"
  - "Captures stay queued forever with the attempt counter climbing on the backoff schedule"
  - "Only NEW accounts hit it — accounts with a saved prompt template never reach the failing branch"
root_cause: environment_config
resolution_type: code_fix
severity: high
tags:
  - convex
  - dynamic-import
  - runtime-restriction
  - vitest
  - test-environment-mismatch
---

# Convex runtime forbids dynamic import() — latent crash invisible to vitest

## Problem

`getTemplateInternal` (`packages/backend/convex/pipelineInternal.ts`) lazily loaded the default prompt template with `const { defaultTemplate } = await import("./defaultTemplate")` inside its query handler. Convex's production runtime does not support dynamic module imports, so the call threw `Uncaught TypeError: dynamic module import unsupported` — killing every `pipeline:submit` attempt for any user **without** a saved `promptTemplates` row. Users with a template row returned early and never hit the branch, which kept the bug latent from the original v1 implementation (PR #2) until the first genuinely new account signed up months later.

## Root Cause

Test-environment mismatch: vitest's Node/edge-vm environment happily executes dynamic imports, so no test could ever catch this — the suite was green while production was structurally incapable of running the line. The lazy `await import` bought nothing (the module is a small constant) and cost a runtime-only crash.

## Solution

Static import at the top of the file (PR #17, merged):

```ts
// before (crashes in the Convex runtime, fine in vitest)
const { defaultTemplate } = await import("./defaultTemplate");
// after
import { defaultTemplate } from "./defaultTemplate";
```

Plus a regression test pinning that a user with no `promptTemplates` row gets the default template body — with a test comment noting that vitest cannot catch the runtime restriction itself, only the behavior.

## Prevention

- Never use dynamic `import()` in Convex function code — use static top-level imports; grep `await import(` under `packages/backend/convex/` in review.
- Treat "the test environment can do things production cannot" as a standing hazard for Convex code under vitest: runtime restrictions (dynamic import, some Node APIs) are only caught by deploying and exercising the path. A live smoke test on a *fresh* account exercises lazy-seeding branches that established accounts never hit.

## Related Issues

- PR #17 (merged) — the fix.
- Surfaced during the stuck-"Queued" saga's live verification; see [history-window-stuck-queued-convex-decode-mismatch](../integration-issues/history-window-stuck-queued-convex-decode-mismatch.md) for the surrounding investigation.
