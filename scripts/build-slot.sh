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
# Who holds the slot (pid, start, checkout, command), so a waiting build can say what it waits for and how long that
# build has been running: a wait of many minutes is then visibly the queue, not the change being built.
HOLDER="$LOCK.holder"

# "4m05s" for 245 seconds.
duration() {
  if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi
}

# Inside the slot (this script runs itself under lockf/flock below): record the holder, then run the build in its place.
if [ "${NOOK_BUILD_SLOT_HELD:-}" = 1 ]; then
  asked="${NOOK_BUILD_SLOT_ASKED:-}"
  unset NOOK_BUILD_SLOT_HELD NOOK_BUILD_SLOT_ASKED
  now="$(date +%s)"
  if [ -n "$asked" ] && [ $((now - asked)) -ge 5 ]; then
    echo "Got the build slot after waiting $(duration $((now - asked)))." >&2
  fi
  checkout="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s\n%s\n%s\n%s\n' "$$" "$now" "$checkout" "$*" > "$HOLDER" 2>/dev/null || true
  # exec keeps this pid, so the pid in the holder file is the build's own for as long as it runs.
  exec "${NICE[@]}" "$@"
fi

if [ "${NOOK_BUILD_SLOT:-on}" = off ] || ! touch "$LOCK" 2>/dev/null; then
  exec "${NICE[@]}" "$@"
fi

# The line a build prints when it has to wait: which build holds the slot, in which checkout, for how long already.
waiting() {
  local pid start checkout command words what=""
  if { read -r pid && read -r start && read -r checkout && read -r command; } < "$HOLDER" 2>/dev/null \
      && kill -0 "$pid" 2>/dev/null; then
    read -r -a words <<< "$command"
    what=": ${words[*]:0:2} in $(basename "$checkout"), running for $(duration $(($(date +%s) - start)))"
  fi
  echo "Waiting for another Nook build on $1 to finish$what (lock: $LOCK)…" >&2
}

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
INSIDE=(env NOOK_BUILD_SLOT_HELD=1 "NOOK_BUILD_SLOT_ASKED=$(date +%s)" "$SELF")
if command -v lockf >/dev/null 2>&1; then
  # macOS: lockf holds the lock for as long as the command runs and releases it when the command exits, also on a crash.
  if ! lockf -k -t 0 "$LOCK" true 2>/dev/null; then
    waiting "this Mac"
  fi
  exec lockf -k "$LOCK" "${INSIDE[@]}" "$@"
elif command -v flock >/dev/null 2>&1; then
  # Linux.
  if ! flock -n "$LOCK" true 2>/dev/null; then
    waiting "this machine"
  fi
  exec flock "$LOCK" "${INSIDE[@]}" "$@"
else
  exec "${NICE[@]}" "$@"
fi
