#!/usr/bin/env bash
# install-local.sh — build Whistle (Release), sign it with the Developer ID
# identity already in the keychain, and install it straight into
# /Applications on THIS Mac — no DMG, no notarization.
#
# This is package-dmg.sh's build/sign steps without the distribution
# packaging: when the machine that builds the app is the same machine that
# runs it, wrapping in a DMG and round-tripping through Apple's notary
# service is pure overhead. Use package-dmg.sh instead when you need an
# artifact to hand to someone else (see release.yml).
#
# Usage:
#   ./apps/macos/Scripts/install-local.sh
#
# State: records the installed commit SHA to
#   ~/Library/Application Support/WhistleAutobuild/installed-commit
# so autobuild-watch.sh can tell whether a rebuild is needed.

set -euo pipefail

log() { echo "[install-local] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DIST_DIR="$MACOS_DIR/dist"
DERIVED_DATA="$DIST_DIR/DerivedData-local"
STATE_DIR="$HOME/Library/Application Support/WhistleAutobuild"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  log "ERROR: DEVELOPER_DIR not found at $DEVELOPER_DIR"
  exit 1
fi

# --- Generate the Xcode project ----------------------------------------------
cd "$MACOS_DIR"
if ! command -v xcodegen >/dev/null 2>&1; then
  log "ERROR: xcodegen not installed (brew install xcodegen)"
  exit 1
fi
log "Generating Whistle.xcodeproj from project.yml"
xcodegen generate --quiet

# --- Signing identity ---------------------------------------------------------
# project.yml pins CODE_SIGN_IDENTITY="Developer ID Application" for
# Release; fall back to ad-hoc only if that identity isn't in the keychain
# (matches package-dmg.sh's behavior).
HAVE_SIGNING_IDENTITY=0
SIGN_TEAM="${SIGN_TEAM:-}"
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -n1 || true)"
if [[ -n "$IDENTITY_LINE" ]]; then
  HAVE_SIGNING_IDENTITY=1
  if [[ -z "$SIGN_TEAM" ]]; then
    SIGN_TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' <<<"$IDENTITY_LINE")"
  fi
  log "Signing identity found: \"$SIGN_IDENTITY\" (team: ${SIGN_TEAM:-<none>})"
else
  log "SKIP Developer ID signing: no \"$SIGN_IDENTITY\" identity in the keychain — building ad-hoc signed"
fi

# --- Build --------------------------------------------------------------------
log "Building Whistle ($CONFIGURATION)"
mkdir -p "$DIST_DIR"

XCODEBUILD_ARGS=(
  -project Whistle.xcodeproj
  -scheme Whistle
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA"
  -destination "generic/platform=macOS"
  ARCHS=arm64
  build
)
if [[ "$HAVE_SIGNING_IDENTITY" == 1 ]]; then
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

# --- Re-sign Sparkle's nested components --------------------------------------
# xcodebuild does not deep re-sign Sparkle's own-signed nested code on
# embed; re-sign inside-out so `codesign --verify --deep --strict` passes
# (see package-dmg.sh for the full rationale).
if [[ "$HAVE_SIGNING_IDENTITY" == 1 ]]; then
  SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW" ]]; then
    log "Re-signing Sparkle.framework nested components"
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
    APP_ENTITLEMENTS="$DIST_DIR/app-entitlements-local.plist"
    codesign -d --entitlements - --xml "$APP_PATH" > "$APP_ENTITLEMENTS"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      --entitlements "$APP_ENTITLEMENTS" \
      "$APP_PATH"
  fi
fi

log "Verifying app signature (codesign --verify --deep --strict)"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --- Quit the running app, if any ---------------------------------------------
if pgrep -x Whistle >/dev/null 2>&1; then
  log "Quitting running Whistle.app"
  osascript -e 'tell application "Whistle" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x Whistle >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x Whistle >/dev/null 2>&1 || true
fi

# --- Install --------------------------------------------------------------------
log "Installing to /Applications/Whistle.app"
ditto "$APP_PATH" /Applications/Whistle.app

log "Relaunching"
open -a /Applications/Whistle.app

mkdir -p "$STATE_DIR"
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
printf '%s\n' "$COMMIT_SHA" > "$STATE_DIR/installed-commit"

osascript -e "display notification \"Whistle updated to version $VERSION\" with title \"Whistle Autobuild\"" >/dev/null 2>&1 || true

log "Done: installed $VERSION ($COMMIT_SHA)"
