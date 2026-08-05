---
name: release
description: Cut a Whistle release — tag main and publish a signed, notarized build via the GitHub Release workflow. Use when the user says "release", "ship this", "cut a release", "tag a version", or asks to run the RELEASING.md steps. Invoking this skill means the user wants a version pushed to real users, not just a status check.
---

# Release Whistle

Guided wrapper around [`docs/RELEASING.md`](../../../docs/RELEASING.md) — that file is the
authoritative source of truth for *what* the commands are and *why*; read it live below rather
than trusting a copy, since it can change out from under this skill. This skill's job is the
*sequencing*: the checks RELEASING.md narrates in prose but doesn't script, and the confirmation
gate before the one step that actually ships to users.

**Invoking `/release` means the user wants to ship.** Don't stop at "here's what the steps
would be" — walk through them. The one required pause is step 5 below (immediately before the
tag push), because that's the moment real installs start getting the update.

## Context

**Current docs/RELEASING.md:**
!`cat docs/RELEASING.md`

**Latest published tag:**
!`git fetch --tags --quiet; git fetch origin main --quiet; git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "(no tags yet)"`

**origin/main HEAD:**
!`git fetch origin main --quiet && git log origin/main -1 --oneline`

**MARKETING_VERSION on origin/main:**
!`git show origin/main:apps/macos/project.yml | grep MARKETING_VERSION`

**Commits on origin/main since the latest tag:**
!`LAST_TAG=$(git describe --tags --abbrev=0 origin/main 2>/dev/null); if [ -n "$LAST_TAG" ]; then git log "$LAST_TAG"..origin/main --oneline; else git log origin/main --oneline -20; fi`

**Release secrets present (first-time provisioning check):**
!`gh secret list 2>/dev/null | awk '{print $1}'`

## What to do

1. **Confirm main has what the user means to ship.** This is the "v1.0.15" gotcha from
   RELEASING.md's Gotchas section: every PR bumps `MARKETING_VERSION`, so concurrent PRs race for
   version numbers and whichever merges first claims the next one — the version number alone is
   not proof the commit contains what the user thinks. Show the user the commit list since the
   last tag (pulled above) and name which PR(s)/features it contains. If the user asked to release
   something specific, grep for evidence of it in that commit range before proceeding. If anything
   looks off — commits missing that should be there, or commits present that shouldn't ship yet —
   stop and flag it instead of guessing.

2. **Resolve the version to tag.** It's `MARKETING_VERSION` from `origin/main`'s
   `apps/macos/project.yml` (pulled above), with a `v` prefix. Confirm it strictly exceeds the
   latest published tag — if it's equal, nothing was bumped since the last release and there's
   nothing new to ship (tell the user and stop); if a tag for that version already exists, stop
   and ask how to proceed rather than re-tagging.

3. **Confirm secrets are provisioned.** The "release secrets present" check above should list
   `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_ID`,
   `NOTARY_KEY_P8_BASE64`, and `SPARKLE_ED_PRIVATE_KEY`. If any are missing, this is a first
   release from this environment — point the user at `SECRETS.md` before going further.

4. **Draft the release-note bullets.** From the commit range in step 1, write 2-4 short,
   user-facing bullets — what changed for someone using the app, not commit messages or file
   names ("Faster capture panel startup", not "refactor(pipeline): route title generation
   through OpenRouter"). Skip changes with no user-visible effect (internal refactors, test-only
   commits, doc-only commits) rather than padding to a count. If literally nothing in the range
   is user-visible, say so and propose shipping with no notes (a lightweight tag) instead of
   inventing bullets.

5. **Stop and get explicit go-ahead before tagging.** This is the only irreversible-feeling step
   — pushing the tag publishes a public GitHub Release, starts offering the update to every
   existing install, and (per step 4) puts your drafted bullets in front of every one of them.
   State plainly: the version you're about to tag, the commit it points at, and the drafted
   bullets. Invite edits to the bullets specifically — they're user-facing copy, not a technical
   summary, so give the user a real chance to rewrite them. Then end your turn and wait for the
   user to confirm — do not proceed to step 6 without an explicit yes (to the release *and* the
   bullets as drafted or edited) in this turn or an already-received one earlier in the
   conversation. Do not skip this even though the user invoked `/release` wanting to ship — the
   gate exists precisely because this step is the one that matters.

6. **Tag and push.** Use RELEASING.md's annotated-tag form (read the exact shape live from the
   inlined copy above — don't hand-type a remembered version or format, since the doc is the
   source of truth and may have changed), with the message set to the confirmed bullets from
   step 5, one per line. If step 4 concluded there's nothing user-visible to note, use a plain
   lightweight tag instead — don't force placeholder bullets into the annotation.
   **Tag `origin/main` explicitly** (`git tag -a vX.Y.Z origin/main -m "..."`) rather than
   local `HEAD` — your working tree is not guaranteed to be checked out at `main`, let alone
   in sync with `origin/main`, and steps 1-2 already verified `origin/main` specifically.
   Tagging local `HEAD` by accident would land the release on an unverified commit — the exact
   failure RELEASING.md's "v1.0.15" gotcha describes.

7. **Watch the workflow run to completion.** Find the run for the pushed tag
   (`gh run list --workflow=release.yml -L 1`) and watch it (`gh run watch <run-id>`) rather than
   polling blind. Report if it fails — don't silently retry.

8. **Verify the build is actually signed and notarized.** Run RELEASING.md's step 3 commands
   exactly, against the version just tagged. A green workflow is not proof of this — actually run
   the `spctl` check. If it comes back `adhoc` or `rejected`, follow RELEASING.md's rollback
   (`gh release delete vX.Y.Z --cleanup-tag=false`) before reporting anything as shipped.

9. **Sanity-check the feed.** Run RELEASING.md's step 4 command and confirm the appcast has one
   `<item>` for the version just tagged, and that its `<description>` renders the bullets from
   step 5 (skip this half of the check if you shipped a lightweight tag on purpose).

10. **Report the outcome.** Release URL, the signing/notarization verdict, the feed check
    result, and the release notes that shipped (or confirmation that none did, if that was the
    call in step 4). If anything failed partway, say exactly which step and what state things are
    in (tag pushed but not verified, release exists but rolled back, etc.) — don't leave the user
    guessing whether real users are on the new version.

## If something goes wrong mid-release

Don't guess — RELEASING.md's "Rolling back a bad release" and "Gotchas" sections (in the inlined
copy above) cover the failure modes this process has actually hit: empty secrets from a filename
typo, tagging too soon after setting a fresh secret, the brief 404 window during asset upload.
Match the symptom to the documented gotcha before improvising a fix.
