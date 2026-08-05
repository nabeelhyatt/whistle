# SECRETS.md — provisioning CI for full releases

Status as of U11 (2026-07-08): the GitHub repo (`nabeelhyatt/whistle`) has
**zero Actions secrets**. All three workflows in `.github/workflows/` are
authored so local packaging can run without credentials, but a tagged GitHub
release fails before building unless every distribution secret is present.
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

This secret is REQUIRED: `release.yml` fails without it, because the
signed `appcast.xml` it produces *is* the live update feed (served from
`/releases/latest/download/appcast.xml`). A release missing that asset
would 404 the feed for every install. See `docs/RELEASING.md`.

## 4. Convex deploy key (backend-deploy.yml)

Convex dashboard → team `nabeelo` → project `whistle` → Settings →
"Deploy keys" → generate a **production** deploy key.

```sh
gh secret set CONVEX_DEPLOY_KEY   # paste the key (starts "prod:…")
```

**Load-bearing, and it was missing until 2026-08-05.** Without it,
`backend-deploy.yml` skips its deploy step and the whole workflow still
reports **green** — so backend changes merge to main and never reach users,
with no red build anywhere. That is exactly how PR #38 sat undeployed for a
day. If backend behavior doesn't match `main`, check this secret exists and
that the workflow's `Deploy to Convex` step actually *ran* rather than
showing as skipped:

```sh
gh run list --workflow=backend-deploy.yml -L 1
gh run view <id> --json jobs -q '.jobs[].steps[] | "\(.conclusion) \(.name)"'
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

## 6. Auth0 tenant — PROVISIONED (2026-07-08)

A real Auth0 tenant now backs sign-in. The identifiers below are **public**
(an OAuth native-app domain + client ID are not secrets — there is no
client secret in a native PKCE flow) and are committed in
`apps/macos/Config/Auth0.xcconfig`:

- `AUTH0_DOMAIN` = `dev-jrm7z08z1lx4u3pg.us.auth0.com`
- `AUTH0_CLIENT_ID` = `jvCvc5uGUuTJjirvZMI7RAl7A3wrduYj`

The same values must be set on **both** Convex deployments so the backend
validates the app's Auth0 ID tokens (`packages/backend/convex/auth.config.ts`
uses `AUTH0_AUDIENCE` as the provider `applicationID`, which for ID-token
validation is the client ID). Convex env vars are per-deployment — setting
one does not set the other:

```sh
cd packages/backend
# prod (precious-loris-637) — what the shipped app talks to
npx convex env set --prod AUTH0_DOMAIN dev-jrm7z08z1lx4u3pg.us.auth0.com
npx convex env set --prod AUTH0_AUDIENCE jvCvc5uGUuTJjirvZMI7RAl7A3wrduYj
npx convex deploy         # redeploy so auth.config.ts picks the values up

# dev (grandiose-alpaca-243) — local development only
npx convex env set AUTH0_DOMAIN dev-jrm7z08z1lx4u3pg.us.auth0.com
npx convex env set AUTH0_AUDIENCE jvCvc5uGUuTJjirvZMI7RAl7A3wrduYj
npx convex dev --once
```

Verify with `npx convex env list --prod` and `npx convex env list`. A value
present on dev but missing on prod is invisible in local testing and only
shows up as failing auth for real users.

### Auth0 application settings (dashboard)

Application type: **Native**. Auth0.swift 2.24.1 on macOS builds the
WebAuth redirect URL as (verbatim format from
`Auth0WebAuth.redirectURL`, custom-scheme path — the app does not call
`useHTTPS()`):

```
{bundleIdentifier}://{AUTH0_DOMAIN}/macos/{bundleIdentifier}/callback
```

With our bundle ID (`build.conductor.whistle.app`) the exact value to
allowlist in **Allowed Callback URLs** (and Allowed Logout URLs) is:

```
build.conductor.whistle.app://dev-jrm7z08z1lx4u3pg.us.auth0.com/macos/build.conductor.whistle.app/callback
```

The app requests scope `openid profile email offline_access` — the
`offline_access` scope means a **refresh token** is issued and stored by
Auth0.swift's `CredentialsManager` in the Keychain, so the Auth0
application must have the **Refresh Token** grant type enabled
(Application → Advanced Settings → Grant Types; it is on by default for
Native apps).

If the xcconfig values are ever reverted to placeholders, the app detects
that (`Auth0Config.fromInfoPlist`) and degrades to a clearly-labeled local
"Dev sign-in" fallback instead of a doomed network call.

---

## 7. OPENROUTER_API_KEY — PROVISIONED (2026-08-04)

Convex env var only (never a GitHub secret, never in the app bundle) — the
call is made server-side by `packages/backend/convex/titleGenerator.ts` to
generate the 3-5 word Conductor workspace title. Set on **both**
deployments, same caveat as Auth0 above:

Copy the key from openrouter.ai → Keys, then pipe it in from the clipboard.
Omitting the value keeps the secret out of shell history and out of the
process argument list (`ps`), which passing it inline would not:

```sh
cd packages/backend
pbpaste | npx convex env set --prod OPENROUTER_API_KEY
pbpaste | npx convex env set        OPENROUTER_API_KEY
```

It funds `anthropic/claude-haiku-4.5` (`TITLE_MODEL`), roughly a few hundred
output tokens per capture.

**This one fails silently by design.** `generateWorkspaceTitle` never
throws: a missing key returns `null` and `buildWorkspaceName` falls back to
the first six raw words of the notes/transcript. So a deployment missing
this var produces workspace names like `on the detail page off the #a7be3e`
with no error anywhere — the symptom is ugly branch names, not a failure.
If titles look raw, check `npx convex env list --prod` first.

---

## Quick verification after provisioning

```sh
gh secret list
# Expect: DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD,
#         NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_P8_BASE64,
#         SPARKLE_ED_PRIVATE_KEY, CONVEX_DEPLOY_KEY, (SENTRY_DSN)

cd packages/backend
# Both deployments need all three — a var set on one is NOT visible to the
# other, and a gap on prod is invisible in local testing.
npx convex env list --names-only --prod   # prod: AUTH0_DOMAIN, AUTH0_AUDIENCE, OPENROUTER_API_KEY
npx convex env list --names-only          # dev:  same three
```

Then push a `v*` tag whose version matches `MARKETING_VERSION` in
`apps/macos/project.yml`; `release.yml` builds, signs, notarizes,
staples, signs the appcast entry, assembles `appcast.xml`, and uploads
everything to a GitHub Release. That's the whole release — the published
`appcast.xml` asset is the live Sparkle feed, so existing installs are
offered the update with no further steps.
