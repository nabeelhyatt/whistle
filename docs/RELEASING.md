# Releasing Whistle

How to cut a public release and keep every moving part in sync. Read this before
tagging a version. First-time CI provisioning is in [`SECRETS.md`](../SECRETS.md).

## The pieces that must stay in sync

A release spans **three** places. Getting them out of sync is the main failure mode:

1. **This repo** — `MARKETING_VERSION` in `apps/macos/project.yml` and the git tag `vX.Y.Z`.
2. **GitHub Releases** (`github.com/nabeelhyatt/whistle/releases`) — the signed DMG +
   `appcast-item.xml`, produced automatically by `.github/workflows/release.yml`.
3. **`nabeelhyatt.com/experiments/whistle`** — a separately-hosted page (NOT in this repo):
   `index.html` (download button) + `appcast.xml` (Sparkle update feed). These are edited
   by hand on that host every release.

### Invariants (if any of these drift, updates or downloads break)

- **Tag == version.** The git tag `vX.Y.Z` must exactly equal `MARKETING_VERSION`
  (`release.yml` asserts this and fails otherwise).
- **`sparkle:version` must increase every release.** Sparkle decides "is this an update?"
  by comparing the appcast item's `sparkle:version` (= the built app's `CFBundleVersion`,
  which release.yml reads via PlistBuddy) against the installed app's `CFBundleVersion` —
  `sparkle:shortVersionString` is display-only. `CURRENT_PROJECT_VERSION` in
  `apps/macos/project.yml` is set to `$(MARKETING_VERSION)` so this happens automatically
  with the normal version bump; don't pin it back to a constant (it was `"1"` through
  v1.0.12, which made every published update compare equal to every install and never be
  offered).
- **Feed URL == hosting location.** `SU_FEED_URL` in `apps/macos/Config/Sparkle.xcconfig`
  is compiled into the app at build time and currently points at
  `https://nabeelhyatt.com/experiments/whistle/appcast.xml`. If the feed ever moves, you
  must change `SU_FEED_URL` **and ship a new build** — old installs keep checking the old URL.
- **Page download link == latest DMG.** The button in the hosted `index.html` points at a
  version-specific asset (`Whistle-X.Y.Z.dmg`); bump it every release.
- **Repo stays public.** The `<enclosure>` URLs and the download button point at public
  GitHub Release assets. If the repo goes private, both break.
- **The repo's `apps/web/public/appcast.xml` is a TEMPLATE, not the live feed.** No workflow
  deploys `apps/web`. Editing that file publishes nothing — the authoritative feed is the
  hand-maintained copy on nabeelhyatt.com. Keep the repo copy as a reference shell.

## Cutting a release

1. **Bump the version.** In the PR with your app changes, bump `MARKETING_VERSION` in
   `apps/macos/project.yml` by one patch (per AGENTS.md "Version Bumping"). Merge to `main`.
2. **Tag and push.** From `main` at the merged commit:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z    # vX.Y.Z must match MARKETING_VERSION
   ```
   This triggers `release.yml`, which builds → Developer-ID signs → notarizes → staples →
   signs the appcast item → publishes a GitHub Release with `Whistle-X.Y.Z.dmg` and
   `appcast-item.xml`.
3. **VERIFY THE BUILD IS ACTUALLY SIGNED (do not skip).** A green run does NOT guarantee a
   distributable DMG — the signing/notarization steps are env-gated and **skip silently**
   (run still "succeeds") if a secret is missing or empty. Confirm:
   ```sh
   # The cert-import step must have RUN, not skipped:
   gh run view <run-id> --json jobs \
     --jq '.jobs[].steps[] | select(.name|test("Import Developer ID")) | .conclusion'   # want: success

   # The published DMG must be notarized (not adhoc):
   gh release download vX.Y.Z --pattern 'Whistle-X.Y.Z.dmg' --dir /tmp/wv
   hdiutil attach /tmp/wv/Whistle-X.Y.Z.dmg -nobrowse -mountpoint /tmp/wv/mnt
   spctl -a -vv /tmp/wv/mnt/Whistle.app     # want: accepted, source=Notarized Developer ID
   hdiutil detach /tmp/wv/mnt
   ```
   If it shows `adhoc` / `rejected`, signing was skipped — check `gh secret list` shows all
   6 secrets with real values, delete the release (`gh release delete vX.Y.Z --cleanup-tag=false`),
   fix the secret, and re-run (`gh run rerun <run-id>`).
4. **Update the nabeelhyatt.com page** (on that host, by hand):
   - **`index.html`**: point the download button at the new
     `https://github.com/nabeelhyatt/whistle/releases/download/vX.Y.Z/Whistle-X.Y.Z.dmg`.
   - **`appcast.xml`**: append the new `<item>` from the release's `appcast-item.xml`
     (`gh release download vX.Y.Z --pattern appcast-item.xml --clobber`). **Keep older items**
     — Sparkle picks the newest applicable. Serve as `Content-Type: application/xml` over HTTPS
     at the exact feed URL. (The `index.html` link only affects brand-new downloads; existing
     installs auto-update purely from `appcast.xml`.)

   **Since v1.0.14, `appcast.xml` is the safety net for a stale `index.html` too.** On its
   very first launch (from `/Applications`, not the mounted DMG) the app silently probes the
   feed and, if something newer is there, shows the update prompt *before* the onboarding
   wizard — so a new user who downloaded last release's DMG is offered the current one within
   seconds instead of a day later. See `apps/macos/Whistle/Updates/UpdateCoordinator.swift`.
   Two consequences for this step: a forgotten `index.html` bump is now self-correcting, but a
   broken or stale `appcast.xml` silently costs every new user their first-launch upgrade.

## Gotchas (learned the hard way, v1.0.9)

- **Green ≠ signed.** See step 3. The first v1.0.9 run "succeeded" but shipped an ad-hoc,
  Gatekeeper-rejected DMG because a secret was empty. Always run the spctl check.
- **Empty secrets from a filename typo.** `base64 -i wrong-name.p12 | gh secret set …` pipes
  an *empty* value on failure, and the secret still appears in `gh secret list`. After setting
  cert secrets, sanity-check: `base64 -i <file>.p12 | wc -c` should be thousands of chars.
- **Fresh secrets + immediate tag.** Setting a secret and tagging within ~2 minutes can race
  propagation. Set secrets, confirm `gh secret list`, then tag.
- **App is arm64-only, macOS 14+.** State this on the download page — Intel Macs can't run it.
