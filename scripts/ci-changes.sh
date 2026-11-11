#!/usr/bin/env bash
# Decides which CI areas a change needs (.github/workflows/ci.yml).
#
# Usage: scripts/ci-changes.sh [--all] < changed-files
#   Reads one changed path per line on stdin and prints `area=true|false` lines for $GITHUB_OUTPUT.
#   --all (or a change to the CI entry point itself) turns every area on: detection fails open.
#
# The path lists here are the single source of truth for which change starts which workflow. When a reusable
# workflow builds from a new directory, add it here and to the `paths` of its verified-check step.
set -euo pipefail

AREAS=(macos ios packages relay tauri)

# Prefixes (directories end in /) whose change needs the area.
paths_for() {
  case "$1" in
    macos) echo "apps/macos/ packages/protocol/ scripts/ui-lint.sh scripts/perf-lint.sh .github/workflows/build.yml .github/actions/" ;;
    ios) echo "apps/ios/ packages/protocol/ .github/workflows/ios.yml .github/actions/" ;;
    packages) echo "packages/core/ .github/workflows/packages.yml .github/actions/" ;;
    relay) echo "apps/relay/ .github/workflows/relay.yml" ;;
    tauri) echo "apps/tauri/ .github/workflows/tauri.yml" ;;
  esac
}

# A change to how CI decides runs everything, so a broken mapping cannot hide a failing build.
ALWAYS_ALL=(.github/workflows/ci.yml scripts/ci-changes.sh)

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
    for prefix in $(paths_for "$area"); do
      for file in ${files[@]+"${files[@]}"}; do
        case "$prefix" in
          */) [[ "$file" == "$prefix"* ]] && needed=true ;;
          *) [ "$file" = "$prefix" ] && needed=true ;;
        esac
      done
    done
  fi
  echo "$area=$needed"
done
