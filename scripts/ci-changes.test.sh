#!/usr/bin/env bash
# Tests scripts/ci-changes.sh: which changed paths start which CI areas. ci.yml runs it before detection.
#
# Usage: scripts/ci-changes.test.sh
#   Each case gives changed paths (separated by spaces) and the areas that must be on; every other area must be off.
#   `ALL` means every area. Add a case when you add an area or a path to the mapping.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
check() { # "paths" "expected areas"
  local paths="$1" expected="$2" got
  got="$(tr ' ' '\n' <<<"$paths" | scripts/ci-changes.sh | sed -n 's/=true$//p' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$expected" = ALL ]; then
    expected="$(scripts/ci-changes.sh --all | sed -n 's/=true$//p' | sort | tr '\n' ' ' | sed 's/ $//')"
  else
    expected="$(tr ' ' '\n' <<<"$expected" | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
  fi
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $paths"
    echo "  expected: ${expected:-(none)}"
    echo "  got:      ${got:-(none)}"
    failures=$((failures + 1))
  fi
}

# The macOS app also runs the portable core tests on Linux.
check "apps/macos/App/AppDelegate.swift" "macos core_tests"
check "apps/macos/project.yml" "macos core_tests dependencies"
check "packages/protocol/Sources/Protocol/Message.swift" "macos ios"
check "apps/ios/Sources/ContentView.swift" "ios"
check "packages/core/Sources/Core/Thing.swift" "packages"
check "apps/relay/worker/index.js" "relay"
check "apps/relay/package.json" "relay dependencies"
check "apps/browser-extension/background.js" "browser_extension"
check "apps/browser-extension/package.json" "browser_extension dependencies"
check "apps/macos/Services/BrowserExtension/BrowserExtensionHost.swift" "macos core_tests browser_extension"
check "apps/tauri/src/main.ts" "tauri"
check "apps/tauri/src-tauri/Cargo.lock" "tauri dependencies"
check "apps/chatd/main.go" "chatd"
check "scripts/ui-lint.sh" "macos"
check "scripts/core-tests.sh" "core_tests"
# Shared actions feed every job that fingerprints its inputs, and are audited as workflows.
check ".github/actions/verified-check/action.yml" "macos ios packages chatd core_tests workflows"
check ".github/workflows/build.yml" "macos workflows"
check ".github/workflows/release.yml" "workflows"
check ".github/scripts/pr-overview.cjs" "github_scripts"
check "docs/CI.md" "docs"
check "apps/macos/README.md" "macos core_tests docs"
# Nothing to build.
check "LICENSE" ""
check "" ""
# A move: --no-renames in ci.yml lists the old and the new path, and the old path still starts its area.
check "apps/macos/Core/Moved.swift docs/Moved.swift" "macos core_tests"
# A change to how CI decides runs everything.
check ".github/workflows/ci.yml" ALL
check "scripts/ci-changes.sh" ALL

# The iPhone companion compiles some of the Mac app's files; a change to any of them must build iOS.
check "apps/macos/UI/Theme/NookTheme.swift" "macos core_tests ios"
check "apps/macos/UI/Shared/AgentRow.swift" "macos core_tests ios"
while IFS= read -r shared; do
  probe="apps/${shared#../}"
  [ -d "$probe" ] && probe="$probe/Probe.swift"
  # grep reads all of the output (no -q): with pipefail, an early exit would fail the pipe on SIGPIPE.
  if ! printf '%s\n' "$probe" | scripts/ci-changes.sh | grep -x 'ios=true' >/dev/null; then
    echo "FAIL: apps/ios/project.yml builds $shared, but a change to it does not start the ios area (scripts/ci-changes.sh)."
    failures=$((failures + 1))
  fi
done < <(sed -n 's/^ *- path: \(\.\.\/macos\/[^ ]*\).*/\1/p' apps/ios/project.yml)

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "ci-changes: all cases pass."
