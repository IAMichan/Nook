#!/bin/bash
# Regenerates the project and builds or tests the macOS app with xcodebuild, keeping the build inside this checkout.
#
# Xcode's default DerivedData gets a new folder (1–5 GB) for every checkout path, and a build under /tmp or an agent's
# scratchpad is never removed. Here the build goes to .build/xcode in the checkout (git-ignored), so it is incremental
# within the checkout and disappears together with the worktree.
#
#   scripts/xcode.sh build
#   scripts/xcode.sh test -only-testing:NookTests/ComposerCoreTests
#   NOOK_XCODE_SCHEME=NookScenarios scripts/xcode.sh test   # the end-to-end scenarios (scripts/scenarios.sh)
#
# Extra arguments go to xcodebuild.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/apps/macos"
# Always: the project is generated, and a stale one misses files added since. --use-cache skips rewriting
# Nook.xcodeproj when the spec and source file list are unchanged, so an open Xcode does not reload it mid-build.
xcodegen --use-cache >/dev/null

ACTION="${1:-build}"
[ $# -gt 0 ] && shift
SCHEME="${NOOK_XCODE_SCHEME:-Nook}"
EXTRA=()
[ "$ACTION" = test ] && [ $# -eq 0 ] && [ "$SCHEME" = Nook ] && EXTRA=(-only-testing:NookTests)

# One heavy build at a time on this Mac, at a lower priority (scripts/build-slot.sh says why).
exec "$REPO/scripts/build-slot.sh" xcodebuild -project Nook.xcodeproj -scheme "$SCHEME" -destination 'platform=macOS' \
  -derivedDataPath "$REPO/.build/xcode" CODE_SIGNING_ALLOWED=NO \
  "$ACTION" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
