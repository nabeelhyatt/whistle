<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Version Bumping

Bump `MARKETING_VERSION` in `apps/macos/project.yml` by one patch increment (e.g. `1.0.0` → `1.0.1`) with every PR that changes app behavior. Docs-only or CI-only changes don't need a bump. Commit the bump in the same PR, not as a separate PR.

## Releasing

Whistle ships as a signed, notarized DMG on GitHub Releases, auto-updated via Sparkle. The release lives entirely in this repo: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which builds, signs, notarizes, and publishes the DMG **plus the Sparkle `appcast.xml` feed itself** as release assets. The app's `SU_FEED_URL` points at `…/releases/latest/download/appcast.xml`, so publishing a release *is* publishing the update — nothing is hand-edited off-repo anymore (a one-time `nabeelhyatt.com` download-page cutover, described in the runbook, is the last off-repo edit). The one invariant that must stay in sync is `MARKETING_VERSION` and the `vX.Y.Z` tag — they must match, and the workflow asserts it. Read **`docs/RELEASING.md`** before cutting any release — it has the full runbook, the invariants, and the verification steps. Critical: missing distribution secrets now fail the run before it builds, but a green run still isn't proof Apple accepted the artifact — always verify the downloaded DMG with `spctl -a -vv`. First-time CI secret provisioning is in `SECRETS.md`.

## Knowledge Store

`docs/solutions/` — documented solutions to past problems (runtime errors, best practices, workflow patterns), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`). Relevant when implementing or debugging in documented areas.

`CONCEPTS.md` — shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts.

`docs/BACKLOG.md` — deferred follow-up work items with context. Check when planning new work (an item may already be scoped); add to it when explicitly deferring something.
