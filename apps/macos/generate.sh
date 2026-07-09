#!/usr/bin/env bash
# generate.sh — regenerate Whistle.xcodeproj from project.yml (TECH-SPEC
# §3a). Run this after any edit to project.yml, and before the first
# xcodebuild invocation in a fresh checkout. The .xcodeproj itself is
# gitignored and must never be hand-edited or committed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
