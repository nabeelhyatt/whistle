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

# --- Generate the Xcode project ----------------------------------------------
cd "$MACOS_DIR"
if ! command -v xcodegen >/dev/null 2>&1; then
  log "ERROR: xcodegen not installed (brew install xcodegen)"
  exit 1
fi
log "Generating Whistle.xcodeproj from project.yml"
xcodegen generate --quiet

# --- Signing identity (env-gated) ----------------------------------------------
# project.yml pins CODE_SIGN_IDENTITY="Developer ID Application" for Release.
# When no such identity exists (e.g. CI before secrets are provisioned,
# see SECRETS.md), fall back to ad-hoc so the build still succeeds — the
# artifact is then explicitly non-distributable.
HAVE_SIGNING_IDENTITY=0
SIGN_TEAM="${SIGN_TEAM:-}"
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -n1 || true)"
if [[ -n "$IDENTITY_LINE" ]]; then
  HAVE_SIGNING_IDENTITY=1
  # Manual signing needs DEVELOPMENT_TEAM as well as the identity; derive
  # the team ID from the identity's own name, e.g.
  #   "Developer ID Application: Nabeel HYATT (73JZ8HJ79F)" -> 73JZ8HJ79F
  if [[ -z "$SIGN_TEAM" ]]; then
    SIGN_TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' <<<"$IDENTITY_LINE")"
  fi
  log "Signing identity found: \"$SIGN_IDENTITY\" (team: ${SIGN_TEAM:-<none>})"
else
  log "SKIP Developer ID signing: no \"$SIGN_IDENTITY\" identity in the keychain — building ad-hoc signed (NOT distributable; see SECRETS.md)"
fi

# --- Build --------------------------------------------------------------------
log "Building Whistle ($CONFIGURATION)"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

XCODEBUILD_ARGS=(
  -project Whistle.xcodeproj
  -scheme Whistle
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA"
  -destination "generic/platform=macOS"
  # arm64-only on purpose: convex-swift ships an arm64-only
  # libconvexmobile-rs.xcframework, so a universal (x86_64 slice) Release
  # build cannot link. Apple Silicon-only distribution until upstream
  # ships a universal binary.
  ARCHS=arm64
  build
)
if [[ "$HAVE_SIGNING_IDENTITY" == 1 ]]; then
  # --timestamp: notarization requires a secure timestamp on every
  # signature; xcodebuild does not add one for plain (non-archive) builds.
  # DEVELOPMENT_TEAM: manual signing fails without a team even when the
  # identity is fully specified.
  # CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: plain (non-archive) builds
  # otherwise inject com.apple.security.get-task-allow (a debugger
  # entitlement), which Apple's notary service rejects outright.
  XCODEBUILD_ARGS+=(
    OTHER_CODE_SIGN_FLAGS=--timestamp
    "DEVELOPMENT_TEAM=$SIGN_TEAM"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  )
else
  XCODEBUILD_ARGS+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild "${XCODEBUILD_ARGS[@]}" | tail -n 5

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Whistle.app"
if [[ ! -d "$APP_PATH" ]]; then
  log "ERROR: built app not found at $APP_PATH"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
log "Built Whistle.app version $VERSION"

# --- Re-sign Sparkle's nested components ----------------------------------------
# SPM-distributed Sparkle.framework ships with Sparkle's own signatures on
# its nested code (XPC services, Autoupdate, Updater.app), and xcodebuild
# does NOT deep re-sign those on embed — Apple's notary service rejects
# them ("not signed with a valid Developer ID certificate" / "signature
# does not include a secure timestamp"). Re-sign inside-out with our
# identity, hardened runtime, and a secure timestamp, per Sparkle's own
# signing docs. Downloader.xpc keeps its upstream entitlements
# (--preserve-metadata=entitlements); the app is re-signed last so its
# seal covers the updated framework.
if [[ "$HAVE_SIGNING_IDENTITY" == 1 ]]; then
  SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW" ]]; then
    log "Re-signing Sparkle.framework nested components for notarization"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp --preserve-metadata=entitlements \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      "$SPARKLE_FW/Versions/B/Updater.app"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      "$SPARKLE_FW"
    log "Re-signing Whistle.app (seal over the re-signed framework)"
    # Use the PROCESSED entitlements from the Xcode-signed app, not the
    # source Whistle.entitlements: the source file contains
    # $(PRODUCT_BUNDLE_IDENTIFIER) substitutions that only Xcode expands.
    APP_ENTITLEMENTS="$DIST_DIR/app-entitlements.plist"
    codesign -d --entitlements - --xml "$APP_PATH" > "$APP_ENTITLEMENTS"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      --entitlements "$APP_ENTITLEMENTS" \
      "$APP_PATH"
  fi
fi

# --- Verify the app signature --------------------------------------------------
log "Verifying app signature (codesign --verify --deep --strict)"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

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
