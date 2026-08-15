---
title: "actions/checkout peels an annotated tag push into a lightweight tag — release notes silently vanished"
date: 2026-08-12
category: docs/solutions/integration-issues
module: ".github/workflows/release.yml (Sparkle appcast generation)"
problem_type: integration_issue
component: ci_workflow
symptoms:
  - "Sparkle update dialog shows no release notes even though the pushed tag was annotated with bullets"
  - "Published appcast-item.xml / appcast.xml has an empty <description> slot"
  - "git cat-file -t \"$GITHUB_REF_NAME\" returns `commit` on the runner but `tag` locally for the same tag"
  - "The release itself is fine — signed, notarized, correctly versioned; only the notes are missing"
root_cause: environment_difference
resolution_type: config_fix
severity: low
tags:
  - github-actions
  - actions-checkout
  - git-tags
  - sparkle
  - release
  - silent-degrade
---

# actions/checkout peels an annotated tag push into a lightweight tag

## Problem

`release.yml` builds the Sparkle appcast item's `<description>` from the annotated tag's
message. Every release through v1.0.21 shipped with no notes — the update dialog was blank —
despite the tags being pushed with `git tag -a … -m "- Bullet one…"`. Locally,
`git cat-file -t v1.0.21` returns `tag` and `git tag -l --format='%(contents)' v1.0.21` prints
the bullets. On the runner, the same commands returned `commit` and nothing.

## Root Cause

For a tag push, `actions/checkout` doesn't fetch the ref as-is. It resolves the commit and
fetches with the refspec `+<commitSHA>:refs/tags/<tag>` — creating a **lightweight** tag that
points at the peeled commit. The annotated tag *object*, and with it the message, tagger, and
any signature, is never downloaded. `GITHUB_REF_NAME` still names the tag, so nothing looks
wrong; the ref just isn't the object that was pushed.

The workflow's own gate then did exactly what it was designed to do:

```bash
if [[ "$(git cat-file -t "$GITHUB_REF_NAME" 2>/dev/null || true)" == "tag" ]]; then
  TAG_NOTES_RAW="$(git tag -l --format='%(contents)' "$GITHUB_REF_NAME")"
fi
```

That gate exists for a real reason — `%(contents)` on a lightweight tag resolves to the
*commit's* message, which would leak a subject/body/trailers into the user-facing update
dialog. It was correct code firing on a false premise. And because the documented behavior for
a lightweight tag is "degrade to no notes, never block the release", the failure produced no
error, no warning, and no red run. The only evidence was the shipped dialog.

## Solution

Re-fetch the real tag object by refspec, immediately after checkout:

```yaml
- name: Restore annotated tag object
  run: |
    set -euo pipefail
    git fetch --force --no-recurse-submodules origin \
      "+refs/tags/${GITHUB_REF_NAME}:refs/tags/${GITHUB_REF_NAME}"
    echo "$GITHUB_REF_NAME is a $(git cat-file -t "$GITHUB_REF_NAME") object"
```

This is correct for a genuinely lightweight tag too (it fetches the lightweight ref, the gate
still declines, notes still degrade), so the "notes are optional, never blocking" invariant
holds.

`fetch-tags: true` on the checkout step is **not** a substitute: it only drops `--no-tags` from
checkout's fetch, which then races checkout's own explicit `+<sha>:refs/tags/<tag>` refspec for
the same ref. Which one wins is an implementation detail of the action. An explicit refspec
fetch is deterministic and says what it's for.

Second half of the fix: the degrade path now emits a `::warning::` with the actual object type
when no notes are found, so the next false trigger shows up in the run summary.

## Prevention

- **Any workflow reading tag metadata off `GITHUB_REF_NAME` is reading a rewritten ref.**
  `%(contents)`, `%(taggername)`, `%(taggerdate)`, `git verify-tag`, `git describe` behavior —
  all of it changes when the annotated object is missing. Re-fetch first.
- **A graceful degrade path needs a loud signal.** This one was indistinguishable from the
  intended behavior for many releases. When a fallback fires on a premise the code can't fully
  verify, log what it observed — silence turns a config bug into a shipped one.
- **Verify environment-dependent git state on the runner, not locally.** The tag was annotated
  on every machine a human looked at.
- Cross-referenced from `docs/RELEASING.md` ("Release notes") so anyone editing the checkout
  step sees why the extra fetch is there.
