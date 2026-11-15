#!/bin/bash
# Proves a fix with a scenario (docs/SCENARIOS.md): runs it on a base and a head commit and says whether it fails on
# base and passes on head.
#
#   scripts/prove-scenario.sh ViewedImageThumbnail --base 37f047b9 [--head HEAD]
#
# The scenario and the harness (apps/macos/Scenarios, scripts/scenarios.sh, scripts/xcode.sh) always come from this
# checkout; only the app comes from the commit under test. A commit that is this checkout's clean HEAD runs in place;
# any other gets a temporary worktree under .build/prove/<sha>, with the scenarios laid over it, built with its own
# xcode.sh, and removed afterwards together with its build.
#
# Writes .scratch/scenarios/prove/proof.json (failsOnBase, passesOnHead, baseSha, headSha, verdict, steps and captures
# per side) and proof.md (base and head screenshots side by side, for a pull request description).
# Exit 0: fails on base and passes on head. 1: it ran but did not prove the fix. 2: it could not run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO=""
BASE=""
HEAD_REV="HEAD"
while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` with only the flag left shifts nothing, and the loop never ended.
    --base) BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --head) HEAD_REV="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) SCENARIO="$1"; shift ;;
  esac
done
if [ -z "$SCENARIO" ] || [ -z "$BASE" ]; then
  echo "usage: scripts/prove-scenario.sh <ScenarioName> --base <rev> [--head <rev>]" >&2
  exit 2
fi
if [ ! -f "$REPO/apps/macos/Scenarios/Cases/$SCENARIO.swift" ]; then
  echo "No scenario apps/macos/Scenarios/Cases/$SCENARIO.swift" >&2
  exit 2
fi

PROVE="$REPO/.scratch/scenarios/prove"
rm -rf "$PROVE"
mkdir -p "$PROVE"

resolve() { git -C "$REPO" rev-parse --verify --quiet "$1^{commit}"; }
BASE_SHA="$(resolve "$BASE")" || { echo "Unknown base revision $BASE" >&2; exit 2; }
HEAD_SHA="$(resolve "$HEAD_REV")" || { echo "Unknown head revision $HEAD_REV" >&2; exit 2; }

# Lays this checkout's scenarios over the checkout in $1: the Scenarios folder, the scripts, and the include line.
overlay() {
  local dir="$1"
  rm -rf "$dir/apps/macos/Scenarios"
  cp -R "$REPO/apps/macos/Scenarios" "$dir/apps/macos/Scenarios"
  cp "$REPO/scripts/xcode.sh" "$REPO/scripts/scenarios.sh" "$dir/scripts/"
  if ! grep -q "Scenarios/scenarios.yml" "$dir/apps/macos/project.yml"; then
    { echo "include:"; echo "  - Scenarios/scenarios.yml"; cat "$dir/apps/macos/project.yml"; } >"$dir/apps/macos/project.yml.new"
    mv "$dir/apps/macos/project.yml.new" "$dir/apps/macos/project.yml"
  fi
}

# Runs the scenario against commit $2 and leaves its output in $PROVE/$1. Prints the run's exit code.
run_side() {
  local side="$1" sha="$2" dir status
  local clean
  clean="$(git -C "$REPO" status --porcelain --untracked-files=no)"
  if [ -z "$clean" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$sha" ]; then
    echo "== $side ${sha:0:10}: this checkout" >&2
    NOOK_SCENARIO_WORK_DIR="$PROVE/$side" "$REPO/scripts/scenarios.sh" "$SCENARIO" >&2
    status=$?
  else
    dir="$REPO/.build/prove/${sha:0:12}"
    echo "== $side ${sha:0:10}: worktree $dir" >&2
    git -C "$REPO" worktree remove --force "$dir" >/dev/null 2>&1
    rm -rf "$dir"
    mkdir -p "$REPO/.build/prove"
    if ! git -C "$REPO" worktree add --quiet --detach --force "$dir" "$sha" >&2; then
      echo "Could not make a worktree for $sha" >&2
      echo 2
      return
    fi
    overlay "$dir"
    # Output in this checkout; the home inside the worktree's own build folder.
    NOOK_SCENARIO_APP_DIR="$dir" NOOK_SCENARIO_WORK_DIR="$PROVE/$side" "$REPO/scripts/scenarios.sh" "$SCENARIO" >&2
    status=$?
    # The worktree and its build (several GB) go, whatever happened.
    git -C "$REPO" worktree remove --force "$dir" >/dev/null 2>&1
    rm -rf "$dir"
    git -C "$REPO" worktree prune
  fi
  echo "$status"
}

BASE_STATUS="$(run_side base "$BASE_SHA")"
HEAD_STATUS="$(run_side head "$HEAD_SHA")"
rmdir "$REPO/.build/prove" 2>/dev/null

# The proof itself is written in Swift (Scenarios/Tools/Proof.swift), from the two reports.
xcrun swift "$REPO/apps/macos/Scenarios/Tools/Proof.swift" "$PROVE" "$SCENARIO" "$BASE_SHA" "$HEAD_SHA" "$BASE_STATUS" "$HEAD_STATUS"
exit $?
