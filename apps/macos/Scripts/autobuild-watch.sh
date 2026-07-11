#!/usr/bin/env bash
# autobuild-watch.sh — poll origin/main and, when it has moved, fetch +
# reset a DEDICATED clone to it and run install-local.sh.
#
# This is meant to be invoked repeatedly by a launchd LaunchAgent (see
# apps/macos/Scripts/launchd/build.conductor.whistle.autobuild.plist). It
# is intentionally cheap to run often: `git ls-remote` is a single small
# network round-trip, and the script exits immediately when nothing has
# changed.
#
# Runs against a dedicated clone (default ~/.whistle-autobuild/repo), NOT
# a Conductor workspace checkout — a Conductor workspace tracks its own
# working branch and may have local changes; this script hard-resets its
# checkout to origin/main on every run, which would destroy in-progress
# work in a workspace.
#
# Env overrides:
#   WHISTLE_AUTOBUILD_REPO   path to the dedicated clone (default below)

set -euo pipefail

log() { echo "[autobuild-watch] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

REPO_DIR="${WHISTLE_AUTOBUILD_REPO:-$HOME/.whistle-autobuild/repo}"
STATE_DIR="$HOME/Library/Application Support/WhistleAutobuild"
LOCK_DIR="$STATE_DIR/lock"
STALE_LOCK_SECONDS=1800

mkdir -p "$STATE_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "ERROR: no git repo at $REPO_DIR — clone it first (see plan: 'git clone <origin-url> $REPO_DIR')"
  exit 1
fi

# --- Lock (mkdir is atomic; guard against a previous run still in flight) -----
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -e "$LOCK_DIR/pid" ]]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if (( LOCK_AGE > STALE_LOCK_SECONDS )); then
      log "Stale lock (${LOCK_AGE}s old) — removing and continuing"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      log "Another run appears to be in progress (lock age ${LOCK_AGE}s) — exiting"
      exit 0
    fi
  else
    log "Lock dir exists without a pid file — exiting"
    exit 0
  fi
fi
echo "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- Compare origin/main to what was last successfully installed --------------
cd "$REPO_DIR"
REMOTE_SHA="$(git ls-remote origin refs/heads/main | cut -f1)"
INSTALLED_SHA="$(cat "$STATE_DIR/installed-commit" 2>/dev/null || true)"

if [[ -z "$REMOTE_SHA" ]]; then
  log "ERROR: could not read origin/main (network down?) — exiting"
  exit 1
fi

if [[ -n "$INSTALLED_SHA" && "$REMOTE_SHA" == "$INSTALLED_SHA" ]]; then
  exit 0
fi

log "origin/main moved ($INSTALLED_SHA -> $REMOTE_SHA) — rebuilding"
git fetch origin main --quiet
git reset --hard origin/main --quiet

if ! "$REPO_DIR/apps/macos/Scripts/install-local.sh" >> "$STATE_DIR/last-build.log" 2>&1; then
  log "install-local.sh FAILED — see $STATE_DIR/last-build.log"
  exit 1
fi

log "Installed $REMOTE_SHA successfully"
