# SECRETS.md — provisioning CI for full releases

Status as of U11 (2026-07-08): the GitHub repo (`nabeelhyatt/whistle`) has
**zero Actions secrets**. All three workflows in `.github/workflows/` are
authored so every credentialed step is env-gated — they run and succeed
today, skipping (with a logged reason) anything that needs a secret.
Provision the secrets below to unlock full signed/notarized releases
(`release.yml`) and automatic backend deploys (`backend-deploy.yml`).

Run all commands from the repo root. `gh` must be authenticated
(`gh auth status`).

---

## 1. Developer ID signing certificate (release.yml)

CI needs the "Developer ID Application: Nabeel HYATT (73JZ8HJ79F)"
certificate **with its private key**, exported as a password-protected
`.p12`. It lives in the login keychain of the machine that built U11.

Export (Keychain Access → My Certificates → right-click the
"Developer ID Application: Nabeel HYATT" entry → Export…, choose `.p12`
and a strong password; save as `developer_id.p12`), then:

```sh
base64 -i developer_id.p12 | gh secret set DEVELOPER_ID_P12_BASE64
gh secret set DEVELOPER_ID_P12_PASSWORD   # paste the .p12 password when prompted
rm developer_id.p12                        # don't leave the cert on disk
```

## 2. Notarization — App Store Connect API key (release.yml)

The same key already used locally (`.env.local`: `NOTARY_KEY_ID`,
`NOTARY_ISSUER_ID`, `NOTARY_KEY_PATH`). Created under App Store Connect →
Users and Access → Integrations → App Store Connect API (role: Developer
or higher).

```sh
# Values from .env.local on the U11 build machine:
gh secret set NOTARY_KEY_ID       # paste the key ID
gh secret set NOTARY_ISSUER_ID    # paste the issuer UUID
base64 -i "<path from NOTARY_KEY_PATH in .env.local>" | gh secret set NOTARY_KEY_P8_BASE64
```

## 3. Sparkle EdDSA private key (release.yml)

The keypair was generated during U11 with Sparkle 2.9.4's `generate_keys`
on the build machine. The **private key lives in that machine's login
keychain** (generic password item: account `ed25519`, service
`https://sparkle-project.org`, label "Private key for signing Sparkle
updates"). The public half is committed in
`apps/macos/Config/Sparkle.xcconfig` (`SU_PUBLIC_ED_KEY`, ends `…zabd4=`)
and baked into the app's Info.plist.

⚠️ Do NOT run `generate_keys` again — a new keypair would not match the
public key shipped in the app, and existing installs would refuse every
update. Export the existing key:

```sh
curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz | tar -xJ bin/generate_keys
./bin/generate_keys -x sparkle_ed_key     # exports the private key from the keychain
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_ed_key
rm sparkle_ed_key                          # don't leave the key on disk
```

Without this secret, `release.yml` still publishes a DMG but cannot sign
an appcast entry — existing installs won't be offered the update.

## 4. Convex deploy key (backend-deploy.yml)

Convex dashboard → team `nabeelo` → project `whistle` → Settings →
"Deploy keys" → generate a **production** deploy key.

```sh
gh secret set CONVEX_DEPLOY_KEY   # paste the key (starts "prod:…")
```

## 5. SENTRY_DSN — optional crash reporting

No Sentry project exists yet (TECH-SPEC §2a). The app has an env-gated
seam (`apps/macos/Whistle/Services/CrashReporting.swift`) that no-ops
with a logged reason while `SENTRY_DSN` is absent/empty — this is the
normal shipping state today.

To turn crash reporting on later:

1. Create a Sentry project (platform: Apple/macOS) and copy its DSN.
2. Add the `sentry-cocoa` SPM package to `apps/macos/project.yml`
   (pinned exact) and wire `SentrySDK.start` inside
   `CrashReporting.start(dsn:)` — the seam is the only file that changes.
3. Provide the DSN at build time (xcconfig value or CI build setting
   feeding the `SENTRY_DSN` Info.plist key), and for CI:

```sh
gh secret set SENTRY_DSN          # paste the DSN
```

---

## Quick verification after provisioning

```sh
gh secret list
# Expect: DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD,
#         NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_P8_BASE64,
#         SPARKLE_ED_PRIVATE_KEY, CONVEX_DEPLOY_KEY, (SENTRY_DSN)
```

Then push a `v*` tag whose version matches `MARKETING_VERSION` in
`apps/macos/project.yml`; `release.yml` builds, signs, notarizes,
staples, signs the appcast entry, and uploads everything to a GitHub
Release. Merge the generated `appcast-item.xml` into
`apps/web/public/appcast.xml` and deploy the web app to offer the update
to existing installs.
