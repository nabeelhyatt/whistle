#!/usr/bin/env bash
# build-and-sign.sh — shared build+sign+verify pipeline used by both
# package-dmg.sh (DMG distribution) and install-local.sh (local install).
#
# Extracted so a fix to entitlements handling or Sparkle's nested-framework
# re-signing only ever needs to be made in one place — previously both
# callers duplicated this pipeline (xcodegen, signing-identity detection,
# the xcodebuild invocation, the Sparkle re-sign, the verify step)
# line-for-line, which meant a fix to one could silently be missed in the
# other.
#
# Contract: this script prints ONLY the path to the built, signed .app on
# stdout (as its last, and only, line) — all logging goes to stderr via
# log(). Callers capture the result with:
#   APP_PATH="$("$SCRIPT_DIR/build-and-sign.sh")"
#
# Whether the result is genuinely Developer ID signed (vs. ad-hoc) is NOT
# part of the return value — callers that need to know (e.g. to gate DMG
# signing/notarization) should ask the artifact itself, which stays in sync
# by construction:
#   codesign -dvvv "$APP_PATH" 2>&1 | grep -q '^Authority='
#
# Environment:
#   CONFIGURATION      xcodebuild configuration (default Release)
#   SIGN_IDENTITY      codesign identity substring (default "Developer ID Application")
#   SIGN_TEAM          Developer Team ID; derived from the identity if unset
#   DEVELOPER_DIR      Xcode toolchain path (default /Applications/Xcode.app/Contents/Developer)
#   DERIVED_DATA_DIR   REQUIRED. -derivedDataPath for xcodebuild. Callers use
#                      distinct paths (package-dmg.sh: dist/DerivedData,
#                      install-local.sh: dist/DerivedData-local) so the two
#                      pipelines never share build state.

set -euo pipefail

log() { echo "[build-and-sign] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"

CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
SIGN_TEAM="${SIGN_TEAM:-}"

if [[ -z "${DERIVED_DATA_DIR:-}" ]]; then
  log "ERROR: DERIVED_DATA_DIR must be set by the caller"
  exit 1
fi
# Scratch files (the processed entitlements plist below) live alongside
# DerivedData so package-dmg.sh and install-local.sh — which share the same
# dist/ directory — don't collide.
WORK_DIR="$(dirname "$DERIVED_DATA_DIR")"
mkdir -p "$WORK_DIR"

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

# --- Signing identity (env-gated) ----------------------------------------------
# project.yml pins CODE_SIGN_IDENTITY="Developer ID Application" for Release.
# When no such identity exists (e.g. CI before secrets are provisioned,
# see SECRETS.md), fall back to ad-hoc so the build still succeeds — the
# artifact is then explicitly non-distributable.
HAVE_SIGNING_IDENTITY=0
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

XCODEBUILD_ARGS=(
  -project Whistle.xcodeproj
  -scheme Whistle
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_DIR"
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
xcodebuild "${XCODEBUILD_ARGS[@]}" | tail -n 5 >&2

APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/Whistle.app"
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
    # Namespaced by DERIVED_DATA_DIR's basename (matches the historical
    # app-entitlements.plist / app-entitlements-local.plist names) so
    # package-dmg.sh and install-local.sh don't clobber each other's
    # scratch file when they share the same dist/ directory.
    DERIVED_DATA_BASENAME="$(basename "$DERIVED_DATA_DIR")"
    ENTITLEMENTS_SUFFIX="${DERIVED_DATA_BASENAME#DerivedData}"
    APP_ENTITLEMENTS="$WORK_DIR/app-entitlements${ENTITLEMENTS_SUFFIX}.plist"
    codesign -d --entitlements - --xml "$APP_PATH" > "$APP_ENTITLEMENTS"
    codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp \
      --entitlements "$APP_ENTITLEMENTS" \
      "$APP_PATH"
  fi
fi

# --- Verify the app signature --------------------------------------------------
log "Verifying app signature (codesign --verify --deep --strict)"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --- Return value ---------------------------------------------------------------
# Contract: exactly one line on stdout — the built+signed .app path. Every
# other line above is logged to stderr, either via log() or by explicitly
# redirecting xcodebuild's `tail`ed progress output to stderr above.
printf '%s\n' "$APP_PATH"
