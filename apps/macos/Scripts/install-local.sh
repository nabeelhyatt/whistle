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

# --- Build + sign + verify (shared with package-dmg.sh) ------------------------
# See build-and-sign.sh for xcodegen project generation, signing-identity
# detection, the xcodebuild invocation, Sparkle nested-component
# re-signing, and the codesign --verify --deep --strict check — extracted
# there so a fix to any of that doesn't have to be duplicated by hand into
# package-dmg.sh (or vice versa).
log "Building Whistle ($CONFIGURATION)"
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
# Stage the new build and atomically swap it into place rather than
# ditto-ing straight over an existing /Applications/Whistle.app: ditto
# MERGES into an existing destination directory, so files present in the
# OLD build but removed/renamed in the NEW one (a dropped framework, a
# renamed resource, a Sparkle version bump that changes bundled file
# names) would otherwise survive the "install" inside the bundle. Those
# leftover files aren't covered by the new signature's seal, so
# `codesign --verify --deep --strict` fails against the surviving files,
# and genuinely stale/obsolete components stay active. This runs
# unattended via a launchd agent, so favor robustness over minimalism: the
# rm+mv swap keeps the window where /Applications/Whistle.app doesn't
# exist as short as a single filesystem rename.
log "Installing to /Applications/Whistle.app"
STAGE="/Applications/.Whistle.app.new.$$"
rm -rf "$STAGE"
ditto "$APP_PATH" "$STAGE"
rm -rf /Applications/Whistle.app
mv "$STAGE" /Applications/Whistle.app

log "Relaunching"
open -a /Applications/Whistle.app

mkdir -p "$STATE_DIR"
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
printf '%s\n' "$COMMIT_SHA" > "$STATE_DIR/installed-commit"

osascript -e "display notification \"Whistle updated to version $VERSION\" with title \"Whistle Autobuild\"" >/dev/null 2>&1 || true

log "Done: installed $VERSION ($COMMIT_SHA)"
