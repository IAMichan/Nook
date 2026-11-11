#!/bin/bash
# Runs a heavy build command in this Mac's single build slot, at a lower priority.
#
# Every agent worktree builds from scratch, and each xcodebuild or `swift test` starts a compiler per core. Three or four
# agents building at once once drove the load to 185 on 14 cores and pushed 9 GB into swap, so the whole Mac and the
# running Nook froze. Builds that share the slot run one after another instead: the others wait, and say so.
#
#   scripts/build-slot.sh xcodebuild …      (scripts/xcode.sh and scripts/core-tests.sh do this for you)
#
#   NOOK_BUILD_SLOT=off   run right away, without waiting for the slot (the priority is still lowered)
#   NOOK_BUILD_LOCK=path  the lock file (default: one per user in /tmp, which every agent sandbox can write)
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: $0 command [args…]" >&2; exit 2; }

# A lower priority keeps the windows, the running Nook, and typing responsive while the compilers run.
NICE=(nice -n 10)

LOCK="${NOOK_BUILD_LOCK:-/tmp/nook-build-$(id -u).lock}"
if [ "${NOOK_BUILD_SLOT:-on}" = off ] || ! touch "$LOCK" 2>/dev/null; then
  exec "${NICE[@]}" "$@"
fi

if command -v lockf >/dev/null 2>&1; then
  # macOS: lockf holds the lock for as long as the command runs and releases it when the command exits, also on a crash.
  if ! lockf -k -t 0 "$LOCK" true 2>/dev/null; then
    echo "Waiting for another Nook build on this Mac to finish (lock: $LOCK)…" >&2
  fi
  exec lockf -k "$LOCK" "${NICE[@]}" "$@"
elif command -v flock >/dev/null 2>&1; then
  # Linux.
  if ! flock -n "$LOCK" true 2>/dev/null; then
    echo "Waiting for another Nook build on this machine to finish (lock: $LOCK)…" >&2
  fi
  exec flock "$LOCK" "${NICE[@]}" "$@"
else
  exec "${NICE[@]}" "$@"
fi
