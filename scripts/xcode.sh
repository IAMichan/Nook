#!/bin/bash
# Regenerates the project and builds or tests the macOS app with xcodebuild, keeping the build inside this checkout.
#
# Xcode's default DerivedData gets a new folder (1–5 GB) for every checkout path, and a build under /tmp or an agent's
# scratchpad is never removed. Here the build goes to .build/xcode in the checkout (git-ignored), so it is incremental
# within the checkout and disappears together with the worktree.
#
#   scripts/xcode.sh build
#   scripts/xcode.sh test                                   # the unit tests, without building Nook.app first
#   scripts/xcode.sh test -only-testing:NookTests/ComposerCoreTests
#   NOOK_XCODE_SCHEME=Nook scripts/xcode.sh test            # build the app too, as CI does
#   NOOK_XCODE_SCHEME=NookScenarios scripts/xcode.sh test   # the end-to-end scenarios (scripts/scenarios.sh)
#
# The Mac is in use while this builds, so the build stays out of the way:
#   - it waits for the Mac's single build slot and runs at a lower priority (scripts/build-slot.sh), so the apps you
#     work in keep the CPU when they need it;
#   - it uses as many parallel jobs as the Mac has performance cores, leaving the efficiency cores and the memory that
#     extra compiler processes take for everything else;
#   - it writes no index store (only Xcode's editor reads one, from its own DerivedData) and does not check the
#     packages' remotes for updates on every build (a missing package is still fetched);
#   - tests run in one process instead of a clone per core.
# NOOK_BUILD_SLOT=off (scripts/build-slot.sh) and NOOK_XCODE_JOBS (default: performance cores) change that;
# -parallel-testing-enabled YES among the arguments runs tests in parallel again.
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
# The unit tests have their own scheme: the Nook scheme would build the whole app before running them.
DEFAULT_SCHEME=Nook
[ "$ACTION" = test ] && DEFAULT_SCHEME=NookTests
SCHEME="${NOOK_XCODE_SCHEME:-$DEFAULT_SCHEME}"
EXTRA=()
[ "$ACTION" = test ] && [ $# -eq 0 ] && [ "$SCHEME" = Nook ] && EXTRA=(-only-testing:NookTests)
if [ "$ACTION" = test ] && [[ " $* " != *" -parallel-testing-enabled "* ]]; then
  EXTRA+=(-parallel-testing-enabled NO)
fi

# Packages resolved since project.yml last changed: no need to ask their remotes again. After a version change in
# project.yml, xcodebuild resolves them as usual.
RESOLVED=Nook.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [ -f "$RESOLVED" ] && [ "$RESOLVED" -nt project.yml ]; then
  EXTRA+=(-skipPackageUpdates)
fi

JOBS="${NOOK_XCODE_JOBS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo 4)}"

# One heavy build at a time on this Mac, at a lower priority (scripts/build-slot.sh says why).
exec "$REPO/scripts/build-slot.sh" xcodebuild -project Nook.xcodeproj -scheme "$SCHEME" -destination 'platform=macOS' \
  -derivedDataPath "$REPO/.build/xcode" -jobs "$JOBS" \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  "$ACTION" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
