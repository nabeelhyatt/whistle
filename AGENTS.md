<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Testing

Three test suites plus a type/build gate, one command each, run in sequence by `pnpm test`:

```bash
pnpm test:backend   # vitest + convex-test, packages/backend
pnpm test:types     # backend tsc --noEmit + apps/web production build
pnpm test:core      # swift test --package-path packages/whistle-core
pnpm test:app       # xcodegen + xcodebuild, apps/macos
```

`test:types` is in `pnpm test` because CI gates on it too — the point of `pnpm test` is that passing it means CI will pass, so anything CI checks belongs here. Scripts invoke `pnpm -C <dir> run <script>`, never `pnpm --filter <pkg> <script>`: `--filter` exits 0 when the script or package doesn't match, so a rename would silently turn a gate into a no-op that still reports green.

`test:app` regenerates `Whistle.xcodeproj` first — it's gitignored, generated from `apps/macos/project.yml`, and doesn't exist until xcodegen runs. The `-derivedDataPath` flag is not cosmetic: without it `xcodebuild` uses Xcode's shared DerivedData, which in this multi-workspace setup carries a stale SPM package checkout and fails the whole suite from a cold start.

`test:app` also prunes `Logs/Test` and passes `-collect-test-diagnostics never`: xcodebuild otherwise captures a ~144 MB symbolicated process diagnostic *per failing run* and never removes old ones, which snowballs fast when you're iterating on a red test. CI keeps full diagnostics (ephemeral runners, and that's where you want them). DerivedData still settles around 1.6 GB per workspace — mostly SPM checkouts and module cache, not growth — so `pnpm clean:derived` reclaims it; a cold rebuild is only ~38s vs ~9s warm, so cleaning an idle workspace is cheap.

`packages/whistle-core/Package.resolved` tracks app-level pins (Auth0, Sparkle, KeyboardShortcuts) that whistle-core itself doesn't depend on. That's expected, not pollution: Xcode unions the whole dependency graph into the local package's resolve file, and the committed file matches what `test:app` writes — so the suite no longer dirties it. Don't "clean" those pins out; a run would put them straight back and the diff would churn on every PR.

One confusing-but-harmless artifact: `test:core` prints `Test run with 0 tests in 0 suites passed` from the swift-testing runner as the *last* line, after the real XCTest results — so the final line of a green run reads like nothing ran. The count that matters is the `Executed N tests` line above it. These suites are all XCTest.

One false-positive to know about: `pnpm --filter backend typecheck` can pass locally and fail in CI, because `tsc` walks *past* the repo root looking for `node_modules/@types` and can pick up a stray global install (a `~/node_modules/@types/node` did exactly this). Every type a Convex function relies on must be a declared dependency of `packages/backend` — a green local typecheck is not proof that it is.

Run the suite matching what you touched before declaring done — a backend change without `pnpm test:backend` isn't done, same for whistle-core and `swift test`, same for apps/macos and the app suite. `pnpm lint` passing is not evidence the tests pass.

`docs/TECH-SPEC.md` §2a is the definition of done, §11 is the testing strategy. `docs/MANUAL-QA.md` is the deliberate human/hardware complement — anything needing a real mic, TCC permission dialogs, live Auth0, or a specific macOS version lives there, not in an automated suite.

Async tests must wait on the observable condition, never a fixed sleep — a hand-rolled `Task.sleep` poll is the documented flake (`docs/solutions/test-failures/async-fake-sleep-race-flaky-tests.md`; one such race failed 6 CI runs across 4 PRs in a day). Use the poll-based `Whistle_waitUntil` helper (`apps/macos/WhistleTests/CaptureViewModelTests.swift:206`) or a continuation-based waiter on the fake (e.g. `waitForStartTaskCallCount`). Prove a flake fix by looping the single test 20+ times with `xcodebuild test-without-building`, not one green run.

Target observable behavior, not implementation. Don't write tests that assert SwiftUI rendering or exercise composition roots (`apps/macos/Whistle/WhistleApp.swift`) — that's MANUAL-QA's job. Observable behavior in onboarding, the status item, etc. is fair game when it's genuinely observable. The repo's pattern is protocol fakes over real hardware — 16 injected protocols exist for this (`TranscriptionService`, `AudioTapping`, `ConvexServiceProtocol`, `SpeechAnalyzerResultsEngine`, and others); add a fake before reaching for the real thing.

Partial gap worth knowing: the queue/convert half of `LiveSpeechAnalyzerEngine`'s macOS 26 audio path is now pinned by `AnalyzerAudioFeed` + `AnalyzerAudioFeedTests` (FIFO, bounded drop-oldest, and the invariant that every yielded buffer is already in the activated Int16 format — that last one is the guard against the SIGTRAP crash v1.0.9 shipped). Still uncovered inside `apps/macos/Whistle/Services/SpeechAnalyzerTranscriber.swift`: setup orchestration, readiness, and the `AssetInventory` reserve/install handshake — those need the injectable seam described in `docs/BACKLOG.md` and `docs/plans/2026-07-28-001-typewhisper-speech-roadmap.md`. Changing that file still warrants a manual mic capture on macOS 26; a green suite is not sufficient evidence there.

## Version Bumping

Bump `MARKETING_VERSION` in `apps/macos/project.yml` by one patch increment (e.g. `1.0.0` → `1.0.1`) with every PR that changes app behavior. Docs-only or CI-only changes don't need a bump. Commit the bump in the same PR, not as a separate PR.

## Releasing

Whistle ships as a signed, notarized DMG on GitHub Releases, auto-updated via Sparkle. The release lives entirely in this repo: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which builds, signs, notarizes, and publishes the DMG **plus the Sparkle `appcast.xml` feed itself** as release assets. The app's `SU_FEED_URL` points at `…/releases/latest/download/appcast.xml`, so publishing a release *is* publishing the update — nothing is hand-edited off-repo anymore (a one-time `nabeelhyatt.com` download-page cutover, described in the runbook, is the last off-repo edit). The one invariant that must stay in sync is `MARKETING_VERSION` and the `vX.Y.Z` tag — they must match, and the workflow asserts it. Read **`docs/RELEASING.md`** before cutting any release — it has the full runbook, the invariants, and the verification steps. Critical: missing distribution secrets now fail the run before it builds, but a green run still isn't proof Apple accepted the artifact — always verify the downloaded DMG with `spctl -a -vv`. First-time CI secret provisioning is in `SECRETS.md`.

## Knowledge Store

`docs/solutions/` — documented solutions to past problems (runtime errors, best practices, workflow patterns), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`). Relevant when implementing or debugging in documented areas.

`CONCEPTS.md` — shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts.

`docs/BACKLOG.md` — deferred follow-up work items with context. Check when planning new work (an item may already be scoped); add to it when explicitly deferring something.
