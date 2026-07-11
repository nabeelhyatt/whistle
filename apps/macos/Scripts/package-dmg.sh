#!/usr/bin/env bash
# package-dmg.sh — build, sign, package, and (when credentials allow)
# notarize + staple the Whistle macOS app as a distributable DMG.
# U11, TECH-SPEC §10.
#
# Usage:
#   ./apps/macos/Scripts/package-dmg.sh
#
# Output: apps/macos/dist/Whistle-<version>.dmg (gitignored).
#
# Credentialed steps are ENV-GATED (TECH-SPEC §10): each one checks its
# required configuration first and SKIPS with a logged reason when absent,
# so the same script is correct locally (credentials in .env.local) and in
# CI before secrets are provisioned (see SECRETS.md / release.yml).
#
#   - Signing: uses SIGN_IDENTITY (default "Developer ID Application") if a
#     matching identity exists in the keychain; otherwise falls back to
#     ad-hoc signing and logs that the artifact is not distributable.
#   - Notarization: runs only when NOTARY_KEY_ID, NOTARY_ISSUER_ID, and
#     NOTARY_KEY_PATH are all set and the .p8 file exists.
#
# Environment (all optional; .env.local at the repo root is sourced for
# local runs, values already in the environment win — CI passes them
# directly):
#   NOTARY_KEY_ID     App Store Connect API key ID
#   NOTARY_ISSUER_ID  App Store Connect issuer ID
#   NOTARY_KEY_PATH   Path to the ASC API .p8 private key
#   SIGN_IDENTITY     codesign identity substring (default below)
#   CONFIGURATION     xcodebuild configuration (default Release)

set -euo pipefail

log() { echo "[package-dmg] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DIST_DIR="$MACOS_DIR/dist"
DERIVED_DATA="$DIST_DIR/DerivedData"

# Xcode toolchain — set DEVELOPER_DIR explicitly (TECH-SPEC §2a: never rely
# on ambient xcode-select state). Respect a caller-provided value (CI
# runners keep Xcode elsewhere).
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  log "ERROR: DEVELOPER_DIR not found at $DEVELOPER_DIR"
  exit 1
fi

# --- .env.local (local runs) -------------------------------------------------
# Parse only the NOTARY_* keys we need; strip trailing "# comment" and
# surrounding whitespace. Values already present in the environment win.
ENV_FILE="$REPO_ROOT/.env.local"
env_lookup() {
  # $1 = key. Prints the cleaned value, or nothing.
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" 2>/dev/null \
    | head -n1 \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
if [[ -f "$ENV_FILE" ]]; then
  : "${NOTARY_KEY_ID:=$(env_lookup NOTARY_KEY_ID)}"
  : "${NOTARY_ISSUER_ID:=$(env_lookup NOTARY_ISSUER_ID)}"
  : "${NOTARY_KEY_PATH:=$(env_lookup NOTARY_KEY_PATH)}"
else
  log ".env.local not found at $ENV_FILE — relying on ambient environment"
fi

# --- Build + sign + verify (shared with install-local.sh) ---------------------
# See build-and-sign.sh for xcodegen project generation, signing-identity
# detection, the xcodebuild invocation, Sparkle nested-component
# re-signing, and the codesign --verify --deep --strict check — extracted
# there so a fix to any of that doesn't have to be duplicated by hand into
# install-local.sh (or vice versa).
log "Building Whistle ($CONFIGURATION)"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
APP_PATH="$(
  CONFIGURATION="$CONFIGURATION" \
  SIGN_IDENTITY="$SIGN_IDENTITY" \
  SIGN_TEAM="${SIGN_TEAM:-}" \
  DEVELOPER_DIR="$DEVELOPER_DIR" \
  DERIVED_DATA_DIR="$DERIVED_DATA" \
  "$SCRIPT_DIR/build-and-sign.sh"
)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
log "Built Whistle.app version $VERSION"

# Re-derive whether the app is genuinely Developer ID signed (vs. ad-hoc)
# from the artifact itself, so the DMG-signing/notarization gating below
# always matches what build-and-sign.sh actually did — no separate
# keychain lookup to keep in sync.
HAVE_SIGNING_IDENTITY=0
if codesign -dvvv "$APP_PATH" 2>&1 | grep -q '^Authority='; then
  HAVE_SIGNING_IDENTITY=1
fi

# --- Package the DMG ------------------------------------------------------------
DMG_PATH="$DIST_DIR/Whistle-$VERSION.dmg"
STAGING="$DIST_DIR/dmg-staging"
log "Packaging $DMG_PATH (hdiutil)"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Whistle" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG_PATH"
rm -rf "$STAGING"

# Sign the DMG itself too (recommended for Developer ID distribution: the
# stapled ticket then covers the container as well as the app).
if [[ "$HAVE_SIGNING_IDENTITY" == 1 ]]; then
  log "Signing DMG"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
else
  log "SKIP DMG signing: no Developer ID identity (reason logged above)"
fi

# --- Notarize + staple (env-gated) ----------------------------------------------
notarize() {
  if [[ -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" || -z "${NOTARY_KEY_PATH:-}" ]]; then
    log "SKIP notarization: NOTARY_KEY_ID / NOTARY_ISSUER_ID / NOTARY_KEY_PATH not all set (see SECRETS.md)"
    return 0
  fi
  if [[ ! -f "$NOTARY_KEY_PATH" ]]; then
    log "SKIP notarization: key file not found at NOTARY_KEY_PATH=$NOTARY_KEY_PATH"
    return 0
  fi
  if [[ "$HAVE_SIGNING_IDENTITY" != 1 ]]; then
    log "SKIP notarization: app is ad-hoc signed (Apple only notarizes Developer ID signed artifacts)"
    return 0
  fi

  log "Submitting DMG to Apple notary service (this can take several minutes)…"
  local submit_output
  if ! submit_output="$(xcrun notarytool submit "$DMG_PATH" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --wait 2>&1)"; then
    log "NOTARIZATION FAILED (submission error):"
    printf '%s\n' "$submit_output" >&2
    return 1
  fi
  printf '%s\n' "$submit_output" >&2

  if ! grep -q "status: Accepted" <<<"$submit_output"; then
    local submission_id
    submission_id="$(sed -n 's/^[[:space:]]*id: //p' <<<"$submit_output" | head -n1)"
    log "NOTARIZATION NOT ACCEPTED — fetching log for submission ${submission_id:-<unknown>}"
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" >&2 || true
    fi
    return 1
  fi

  log "Notarization accepted — stapling ticket"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  log "Stapled + validated"
}
notarize

log "Done: $DMG_PATH"
