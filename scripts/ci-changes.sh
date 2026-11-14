#!/usr/bin/env bash
# Decides which CI areas a change needs (.github/workflows/ci.yml).
#
# Usage: scripts/ci-changes.sh [--all] < changed-files
#   Reads one changed path per line on stdin and prints `area=true|false` lines for $GITHUB_OUTPUT.
#   --all (or a change to the CI entry point itself) turns every area on: detection fails open.
#
# scripts/ci-changes.test.sh checks the mapping (ci.yml runs it first); add a case there when you change a list.
#
# The path lists here are the single source of truth for which change starts which job. When a reusable workflow
# builds from a new directory, add it here and to the `paths` of its verified-check step.
set -euo pipefail

AREAS=(macos ios packages relay browser_extension tauri chatd core_tests workflows github_scripts docs dependencies)

# Patterns whose change needs the area: a directory ends in /, a pattern with * is a glob over the whole path
# (* also matches /), anything else is one file.
paths_for() {
  case "$1" in
    macos) echo "apps/macos/ packages/protocol/ scripts/ui-lint.sh scripts/perf-lint.sh .github/workflows/build.yml .github/actions/" ;;
    # The companion also compiles a few of the Mac app's files (`path: ../macos/…` in apps/ios/project.yml); the test
    # fails when that list gains one that is missing here.
    ios) echo "apps/ios/ packages/protocol/ apps/macos/Brain/ChartRescue.swift apps/macos/Brain/ChatChart.swift apps/macos/Brain/MarkdownBlock.swift apps/macos/Services/Workspace/ComposerQuotes.swift apps/macos/UI/Components/BrandLogo.swift apps/macos/UI/Shared/ apps/macos/UI/Theme/NookIcon.swift apps/macos/UI/Theme/NookPalette.swift apps/macos/UI/Theme/NookTheme.swift apps/macos/Resources/Lucide.xcassets/ apps/macos/Resources/katex/ apps/macos/Resources/mermaid/ .github/workflows/ios.yml .github/actions/" ;;
    packages) echo "packages/core/ .github/workflows/packages.yml .github/actions/" ;;
    relay) echo "apps/relay/ .github/workflows/relay.yml" ;;
    # Nook's browser extension; its tests also read the Mac app's side of it (the host and the protocol version).
    browser_extension) echo "apps/browser-extension/ apps/macos/Services/BrowserExtension/ .github/workflows/browser-extension.yml" ;;
    tauri) echo "apps/tauri/ .github/workflows/tauri.yml" ;;
    chatd) echo "apps/chatd/ .github/workflows/chatd.yml .github/actions/" ;;
    # scripts/core-tests.sh on Linux: the portable half of NookTests that contributors without a Mac can run.
    core_tests) echo "apps/macos/ scripts/core-tests.sh scripts/core-tests-sync.py .github/workflows/core-tests.yml .github/actions/" ;;
    # zizmor: security audit of the workflows, actions and Dependabot settings.
    workflows) echo ".github/workflows/ .github/actions/ .github/zizmor.yml .github/dependabot.yml" ;;
    # node --test for the scripts the community workflows load (PR overview, welcome).
    github_scripts) echo ".github/scripts/" ;;
    # lychee: relative links and #anchors in Markdown. A renamed heading or moved file breaks links elsewhere too.
    docs) echo "*.md" ;;
    # GitHub's dependency review: new dependencies with known vulnerabilities or a disallowed license.
    dependencies) echo "*package.json *package-lock.json *Cargo.toml *Cargo.lock *Package.swift *Package.resolved *go.mod *go.sum apps/macos/project.yml apps/ios/project.yml" ;;
  esac
}

# A change to how CI decides runs everything, so a broken mapping cannot hide a failing build.
ALWAYS_ALL=(.github/workflows/ci.yml scripts/ci-changes.sh)

# shellcheck disable=SC2053 # in the glob branch the unquoted pattern is meant as a glob
matches() { # file pattern
  case "$2" in
    */) [[ "$1" == "$2"* ]] ;;
    *\**) [[ "$1" == $2 ]] ;;
    *) [ "$1" = "$2" ] ;;
  esac
}

all=false
[ "${1:-}" = "--all" ] && all=true

files=()
if [ "$all" = false ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done
fi

for file in ${files[@]+"${files[@]}"}; do
  for trigger in "${ALWAYS_ALL[@]}"; do
    [ "$file" = "$trigger" ] && all=true
  done
done

for area in "${AREAS[@]}"; do
  needed=$all
  if [ "$needed" = false ]; then
    set -f # keep the * in patterns from expanding against the working directory
    for pattern in $(paths_for "$area"); do
      for file in ${files[@]+"${files[@]}"}; do
        matches "$file" "$pattern" && needed=true
      done
    done
    set +f
  fi
  echo "$area=$needed"
done
