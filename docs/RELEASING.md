# Releasing Whistle

How to cut a public release. Since v1.0.16 the whole release lives in **this repo** —
pushing a tag is the entire process. Read this before tagging. First-time CI provisioning
is in [`SECRETS.md`](../SECRETS.md).

## How it works

`.github/workflows/release.yml` fires on a `v*` tag and publishes a GitHub Release with
four assets:

| Asset | Purpose |
| --- | --- |
| `Whistle-X.Y.Z.dmg` | the signed, notarized build; what the appcast `<enclosure>` points at |
| `Whistle.dmg` | byte-identical unversioned copy, so a download page can link to a permanent URL |
| `appcast.xml` | **the live Sparkle update feed** |
| `appcast-item.xml` | just this release's signed `<item>`, kept so feed history is reconstructible |

The trick that removes all hand-editing: `/releases/latest/download/<asset>` is a permanent
URL that always resolves to the newest release's copy. So `SU_FEED_URL` in
`apps/macos/Config/Sparkle.xcconfig` is

```text
https://github.com/nabeelhyatt/whistle/releases/latest/download/appcast.xml
```

and publishing a release *is* publishing the update. Likewise the download button on
`nabeelhyatt.com/experiments/whistle` points at
`https://github.com/nabeelhyatt/whistle/releases/latest/download/Whistle.dmg` and never needs
touching again.

The feed carries **only the current release's item**. Sparkle only ever offers the newest
applicable item, every release shares `minimumSystemVersion` 14.0, and the items carry no
release notes — so historical items would change nothing, while depending on every past
release's asset staying well-formed forever would be a standing hazard (v1.0.9's published
item is in fact invalid XML: duplicate `length` attribute, since fixed).

### Invariants

- **Tag == version.** `vX.Y.Z` must exactly equal `MARKETING_VERSION` in
  `apps/macos/project.yml` (`release.yml` asserts this and fails otherwise).
- **`sparkle:version` must increase every release.** Sparkle decides "is this an update?" by
  comparing the appcast item's `sparkle:version` (= the built app's `CFBundleVersion`) against
  the installed app's — `sparkle:shortVersionString` is display-only.
  `CURRENT_PROJECT_VERSION` is set to `$(MARKETING_VERSION)` so a normal version bump handles
  it; don't pin it back to a constant (it was `"1"` through v1.0.12, which made every published
  update compare equal to every install and never be offered). `release.yml` now asserts the
  new item's `sparkle:version` strictly exceeds the previous release's.
- **Every release must publish `appcast.xml`.** It's the feed. A release without it 404s
  updates for every install — which is why a missing `SPARKLE_ED_PRIVATE_KEY` is a hard
  failure, not a skip.
- **`<enclosure>` URLs stay versioned.** The EdDSA signature binds to exact bytes;
  `latest/download/Whistle.dmg` changes content every release and must never be an enclosure.
- **Repo stays public.** The feed, the enclosures, and the download button are all public
  Release assets. Making the repo private breaks auto-update for every install.
- **Feed URL is compile-time.** Moving the feed means editing `SU_FEED_URL`, re-running
  `xcodegen generate`, **and** shipping a new build — existing installs keep checking whatever
  URL was baked into them.

## Cutting a release

1. **Bump the version.** In the PR with your app changes, bump `MARKETING_VERSION` in
   `apps/macos/project.yml` by one patch (per AGENTS.md "Version Bumping"). Merge to `main`.
2. **Tag and push.** From `main` at the merged commit:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z    # vX.Y.Z must match MARKETING_VERSION
   ```
   This builds → Developer-ID signs → notarizes → staples → signs the appcast item → assembles
   `appcast.xml` → publishes the Release. Existing installs are offered the update as soon as
   the assets finish uploading; no other step is required.
3. **VERIFY THE BUILD IS ACTUALLY SIGNED (do not skip).** Missing distribution secrets now
   fail the workflow before the build, but a successful credential import is still not proof
   that Apple accepted the artifact. Confirm:
   ```sh
   # The cert-import step must have succeeded:
   gh run view <run-id> --json jobs \
     --jq '.jobs[].steps[] | select(.name|test("Import Developer ID")) | .conclusion'   # want: success

   # The published DMG must be notarized (not adhoc):
   gh release download vX.Y.Z --pattern 'Whistle-X.Y.Z.dmg' --dir /tmp/wv
   hdiutil attach /tmp/wv/Whistle-X.Y.Z.dmg -nobrowse -mountpoint /tmp/wv/mnt
   spctl -a -vv /tmp/wv/mnt/Whistle.app     # want: accepted, source=Notarized Developer ID
   hdiutil detach /tmp/wv/mnt
   ```
   If it shows `adhoc` / `rejected`, inspect the signing and notarization logs, delete the
   release (`gh release delete vX.Y.Z --cleanup-tag=false`), fix the failure, and re-run
   (`gh run rerun <run-id>`).
4. **Sanity-check the feed** (optional but cheap):
   ```sh
   curl -sL https://github.com/nabeelhyatt/whistle/releases/latest/download/appcast.xml \
     | xmllint --format -        # want: one <item> with the version you just tagged
   ```

### Rolling back a bad release

`gh release delete vX.Y.Z` — because the feed is resolved through `latest`, deleting the
release rolls the update feed back to the previous release atomically. Before the first
GitHub-hosted-feed release is published, the workflow also adds a complete feed asset to the
previous release, so this rollback path remains valid across the migration.

## Gotchas (learned the hard way)

- **Green ≠ notarized.** See step 3. Missing secrets now fail the release before it can publish,
  but always run the spctl check to verify the final downloaded DMG.
- **Empty secrets from a filename typo.** `base64 -i wrong-name.p12 | gh secret set …` pipes
  an *empty* value on failure, and the secret still appears in `gh secret list`. After setting
  cert secrets, sanity-check: `base64 -i <file>.p12 | wc -c` should be thousands of chars.
- **Fresh secrets + immediate tag.** Setting a secret and tagging within ~2 minutes can race
  propagation. Set secrets, confirm `gh secret list`, then tag.
- **A version bump on `main` does NOT mean the change you care about is on `main`.** Because
  every PR bumps `MARKETING_VERSION` (AGENTS.md), concurrent PRs race for version numbers, and
  whichever merges first claims the next one. Tagging then ships *that* PR, not yours. This
  burned v1.0.15: an unrelated PR merged with the bump, the tag was cut from `main`, and the
  release shipped without the change the version was meant to carry. Before tagging, confirm
  the commit `main` points at actually contains your work — `git log origin/main --oneline -1`
  plus a grep for something your change introduced — not just that the version number looks
  right.
- **Brief 404 window.** For the few seconds while `gh release create` uploads assets, the feed
  URL 404s. Harmless: Sparkle treats it as a failed check and retries on schedule, and the
  first-launch probe in `UpdateCoordinator.swift` does not retire a check on fetch failure.
- **App is arm64-only, macOS 14+.** State this on the download page — Intel Macs can't run it.
- **Pre-v1.0.16 installs are stranded.** Builds up to and including v1.0.15 baked in the old
  `nabeelhyatt.com/experiments/whistle/appcast.xml` feed URL, which is no longer maintained.
  There were no real users at cutover, so this was accepted rather than migrated; any such
  install must be replaced by re-downloading. v1.0.16's run backfills a complete feed asset
  onto v1.0.15 anyway, but only so the rollback path below works — no v1.0.15 install ever
  reads it.
