#!/bin/bash
# Builds or tests the macOS app with xcodebuild, keeping the build inside this checkout.
#
# Xcode's default DerivedData gets a new folder (1–5 GB) for every checkout path, and a build under /tmp or an agent's
# scratchpad is never removed. Here the build goes to .build/xcode in the checkout (git-ignored), so it is incremental
# within the checkout and disappears together with the worktree.
#
#   scripts/xcode.sh build
#   scripts/xcode.sh test -only-testing:NookTests/ComposerCoreTests
#
# Extra arguments go to xcodebuild.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/apps/macos"
[ -d Nook.xcodeproj ] || xcodegen >/dev/null

ACTION="${1:-build}"
[ $# -gt 0 ] && shift
EXTRA=()
[ "$ACTION" = test ] && [ $# -eq 0 ] && EXTRA=(-only-testing:NookTests)

exec xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' \
  -derivedDataPath "$REPO/.build/xcode" CODE_SIGNING_ALLOWED=NO \
  "$ACTION" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
