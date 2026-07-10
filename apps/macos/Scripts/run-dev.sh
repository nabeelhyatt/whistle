#!/usr/bin/env bash
# run-dev.sh — build Whistle (Debug) for local iteration and launch it.
#
# Usage:
#   ./apps/macos/Scripts/run-dev.sh
#
# Why this exists: project.yml pins Debug's CODE_SIGN_IDENTITY to ad-hoc
# ("-") so `xcodebuild build/test` works with no Apple Developer Program
# team configured (CI has none — see project.yml's settings.base comment).
# Ad-hoc signatures are derived from the binary's own bytes, so every
# rebuild produces a different signature. macOS ties a Keychain item's
# "Always Allow" grant to the app's signing identity, so a rebuilt Debug
# app is treated as a new, untrusted app and re-prompts for Whistle's
# Auth0 credentials item on every launch after every rebuild.
#
# This script mirrors package-dmg.sh's env-gated signing-identity detection
# (Developer ID if present in the local keychain, else ad-hoc) but targets
# Debug and skips packaging/notarization — giving local builds a stable
# signature without touching project.yml or CI's ad-hoc default.
#
# Environment (all optional):
#   SIGN_IDENTITY   codesign identity substring (default "Developer ID Application")

set -euo pipefail

log() { echo "[run-dev] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"

CONFIGURATION=Debug
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DEV_DIR="$MACOS_DIR/dist/dev"
DERIVED_DATA="$DEV_DIR/DerivedData"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  log "ERROR: DEVELOPER_DIR not found at $DEVELOPER_DIR"
  exit 1
fi

cd "$MACOS_DIR"
if ! command -v xcodegen >/dev/null 2>&1; then
  log "ERROR: xcodegen not installed (brew install xcodegen)"
  exit 1
fi
log "Generating Whistle.xcodeproj from project.yml"
xcodegen generate --quiet

# --- Signing identity (same detect-and-fallback as package-dmg.sh) -----------
HAVE_SIGNING_IDENTITY=0
SIGN_TEAM="${SIGN_TEAM:-}"
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -n1 || true)"
if [[ -n "$IDENTITY_LINE" ]]; then
  HAVE_SIGNING_IDENTITY=1
  if [[ -z "$SIGN_TEAM" ]]; then
    SIGN_TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' <<<"$IDENTITY_LINE")"
  fi
  log "Signing identity found: \"$SIGN_IDENTITY\" (team: ${SIGN_TEAM:-<none>}) — Debug build will use it instead of ad-hoc"
else
  log "SKIP Developer ID signing: no \"$SIGN_IDENTITY\" identity in the keychain — building ad-hoc signed (Keychain prompt will repeat on every rebuild)"
fi

# --- Build --------------------------------------------------------------------
# DERIVED_DATA is intentionally persistent across runs (not wiped) so repeat
# invocations of this script incrementally rebuild, like a normal dev loop,
# instead of recompiling Auth0/GRDB/Sparkle/KeyboardShortcuts from scratch
# every time.
log "Building Whistle ($CONFIGURATION)"
mkdir -p "$DEV_DIR"

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
  # Leave the initial build itself ad-hoc (Debug's project.yml default) —
  # passing CODE_SIGN_IDENTITY as a project-wide xcodebuild override here
  # conflicts with SPM package targets (KeyboardShortcuts, Auth0, GRDB) that
  # use automatic signing, since it isn't scoped to just the Whistle target
  # the way Release's project.yml override is. The re-sign step below fully
  # replaces the app's signature (and hardened-runtime flag) afterward, so
  # the initial build's signing identity doesn't matter.
  XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$SIGN_TEAM")
else
  XCODEBUILD_ARGS+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild "${XCODEBUILD_ARGS[@]}" | tail -n 5

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Whistle.app"
if [[ ! -d "$APP_PATH" ]]; then
  log "ERROR: built app not found at $APP_PATH"
  exit 1
fi

# --- Re-sign Sparkle's nested components (hardened runtime + a real
# identity enforce library validation; the un-re-signed SPM Sparkle.framework
# would otherwise fail to load at launch — see package-dmg.sh for the same
# step done ahead of notarization) ---------------------------------------------
if [[ "$HAVE_SIGNING_IDENTITY" == 1 ]]; then
  SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW" ]]; then
    log "Re-signing Sparkle.framework nested components"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --preserve-metadata=entitlements \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign -f -s "$SIGN_IDENTITY" -o runtime \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign -f -s "$SIGN_IDENTITY" -o runtime \
      "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign -f -s "$SIGN_IDENTITY" -o runtime \
      "$SPARKLE_FW/Versions/B/Updater.app"
    codesign -f -s "$SIGN_IDENTITY" -o runtime \
      "$SPARKLE_FW"
    log "Re-signing Whistle.app (seal over the re-signed framework)"
    APP_ENTITLEMENTS="$DEV_DIR/app-entitlements.plist"
    codesign -d --entitlements - --xml "$APP_PATH" > "$APP_ENTITLEMENTS"
    codesign -f -s "$SIGN_IDENTITY" -o runtime \
      --entitlements "$APP_ENTITLEMENTS" \
      "$APP_PATH"
  fi
  log "Verifying app signature (codesign --verify --deep --strict)"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

# --- Launch ---------------------------------------------------------------------
log "Quitting any running Whistle instance"
pkill -x Whistle >/dev/null 2>&1 || true

log "Launching $APP_PATH"
open "$APP_PATH"
