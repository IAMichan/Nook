#!/bin/bash
# Runs a heavy build command in one of this Mac's build slots, behind the user's own work.
#
# Every agent worktree builds from scratch, and each xcodebuild or `swift build` starts a compiler per core. Three or four
# agents building at once once drove the load to 185 on 14 cores and pushed 9 GB into swap, so the whole Mac and the
# running Nook froze. So at most NOOK_BUILD_SLOTS builds (default 2) run at once; the others wait, and say so.
#
# The builds that wait take the slots in the order they asked (a ticket each in $LOCK.queue): racing for a free slot
# every two seconds let newer builds win again and again, and one agent's build waited over a quarter of an hour while
# builds that asked minutes later went first, so its session looked stuck.
#
# Hold a slot only while compiling: a test run uses a core or two, and keeping the slot through it made other agents
# wait up to 19 minutes on an idle Mac. scripts/core-tests.sh and scripts/xcode.sh build inside the slot and run the
# tests outside it.
#
#   scripts/build-slot.sh xcodebuild …      (scripts/xcode.sh and scripts/core-tests.sh do this for you)
#
#   NOOK_BUILD_SLOT=off   run right away, without waiting for a slot (the priority is still lowered)
#   NOOK_BUILD_SLOTS=n    how many builds may run at once (default 2)
#   NOOK_BUILD_LOCK=path  the first slot's lock file; slot n uses path.n (default: one per user in /tmp, which every
#                         agent sandbox can write)
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: $0 command [args…]" >&2; exit 2; }

# The build runs at nice 10 so the windows, the running Nook and typing stay responsive while the compilers run. Nook
# already starts its agents at nice 10: lowering it again would put the build at 20, behind every other agent's work.
NICE_TARGET=10
current_nice="$(ps -o nice= -p $$ 2>/dev/null | tr -d ' ' || true)"
[[ "$current_nice" =~ ^-?[0-9]+$ ]] || current_nice=0
NICE=()
if [ "$current_nice" -lt "$NICE_TARGET" ]; then
  NICE=(nice -n $((NICE_TARGET - current_nice)))
fi

LOCK="${NOOK_BUILD_LOCK:-/tmp/nook-build-$(id -u).lock}"
SLOTS="${NOOK_BUILD_SLOTS:-2}"
[[ "$SLOTS" =~ ^[1-9][0-9]*$ ]] || SLOTS=2
# The first slot keeps the old lock name, so a checkout with the earlier one-slot script still shares it.
slot_lock() {
  if [ "$1" = 1 ]; then echo "$LOCK"; else echo "$LOCK.$1"; fi
}
# Exit status of lockf/flock when the lock is taken (EX_TEMPFAIL).
BUSY=75

# "4m05s" for 245 seconds.
duration() {
  if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi
}

# Whether process $1 is still one of these scripts. `kill -0` alone is not enough: a build killed with SIGKILL (a
# closed session) leaves its ticket and holder behind, and once the system hands its PID to another process, that
# ticket would count as a live build ahead in the queue forever and every later build would wait for it.
SELF_NAME="$(basename "$0")"
is_slot_process() {
  local command
  kill -0 "$1" 2>/dev/null || return 1
  command="$(ps -p "$1" -o command= 2>/dev/null)" || return 0  # ps could not tell: trust kill -0, as before
  [[ "$command" == *"$SELF_NAME"* ]]
}

# Inside a slot (this script runs itself under lockf/flock below): record who holds it, then run the build.
if [ "${NOOK_BUILD_SLOT_HELD:-}" = 1 ]; then
  asked="${NOOK_BUILD_SLOT_ASKED:-}"
  holder="${NOOK_BUILD_SLOT_HOLDER:-$LOCK.holder}"
  # Out of the queue: the next build in line may take the other slot now.
  [ -n "${NOOK_BUILD_SLOT_TICKET:-}" ] && rm -f "$NOOK_BUILD_SLOT_TICKET" 2>/dev/null
  unset NOOK_BUILD_SLOT_HELD NOOK_BUILD_SLOT_ASKED NOOK_BUILD_SLOT_HOLDER NOOK_BUILD_SLOT_TICKET
  now="$(date +%s)"
  if [ -n "$asked" ] && [ $((now - asked)) -ge 5 ]; then
    echo "Got a build slot after waiting $(duration $((now - asked)))." >&2
  fi
  checkout="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s\n%s\n%s\n%s\n' "$$" "$now" "$checkout" "$*" > "$holder" 2>/dev/null || true
  status=0
  ${NICE[@]+"${NICE[@]}"} "$@" || status=$?
  # 75 would read as "slot taken" to the loop below and run the build again.
  [ "$status" = "$BUSY" ] && status=1
  exit "$status"
fi

run_now() {
  if [ ${#NICE[@]} -gt 0 ]; then exec "${NICE[@]}" "$@"; else exec "$@"; fi
}

if [ "${NOOK_BUILD_SLOT:-on}" = off ] || ! touch "$LOCK" 2>/dev/null; then
  run_now "$@"
fi

if command -v lockf >/dev/null 2>&1; then
  # macOS: lockf holds the lock for as long as the command runs and releases it when the command exits, also on a crash.
  try_slot() { lockf -s -k -t 0 "$1" "${@:2}"; }
  where="this Mac"
elif command -v flock >/dev/null 2>&1; then
  try_slot() { flock -n -E "$BUSY" "$1" "${@:2}"; }
  where="this machine"
else
  run_now "$@"
fi

# The line a build prints when it has to wait: which builds hold the slots, in which checkout, for how long already.
waiting() {
  local i pid start checkout command words what=""
  for ((i = 1; i <= SLOTS; i++)); do
    if { read -r pid && read -r start && read -r checkout && read -r command; } 2>/dev/null < "$(slot_lock "$i").holder" \
        && is_slot_process "$pid"; then
      read -r -a words <<< "$command"
      what="$what${what:+; }${words[*]:0:2} in $(basename "$checkout"), running for $(duration $(($(date +%s) - start)))"
    fi
  done
  echo "Waiting for a free Nook build slot on $where (${SLOTS} at once)${what:+: $what}…" >&2
}

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ASKED="$(date +%s)"

# The queue: one ticket per waiting build, named so that they sort in the order they asked. A ticket whose build is gone
# (killed while it waited) is removed by whoever finds it.
QUEUE="$LOCK.queue"
TICKET=""
if mkdir -p "$QUEUE" 2>/dev/null; then
  TICKET="$QUEUE/$(printf '%012d.%010d' "$ASKED" "$$")"
  if : > "$TICKET" 2>/dev/null; then
    trap 'rm -f "$TICKET" 2>/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  else
    TICKET=""
  fi
fi

# Whether this build is next in line: fewer than SLOTS live builds asked before it. Without a queue, every build may try.
my_turn() {
  [ -n "$TICKET" ] && [ -e "$TICKET" ] || return 0
  local ahead=0 ticket name pid
  for ticket in "$QUEUE"/*; do
    [ -e "$ticket" ] || continue
    [ "$ticket" = "$TICKET" ] && break
    [[ "$ticket" < "$TICKET" ]] || continue
    name="$(basename "$ticket")"
    pid="$((10#${name##*.}))"
    if is_slot_process "$pid"; then
      ahead=$((ahead + 1))
    else
      rm -f "$ticket" 2>/dev/null
    fi
  done
  [ "$ahead" -lt "$SLOTS" ]
}

said=0
while true; do
  if my_turn; then
    for ((i = 1; i <= SLOTS; i++)); do
      lock="$(slot_lock "$i")"
      touch "$lock" 2>/dev/null || continue
      status=0
      try_slot "$lock" env NOOK_BUILD_SLOT_HELD=1 "NOOK_BUILD_SLOT_ASKED=$ASKED" "NOOK_BUILD_SLOT_HOLDER=$lock.holder" \
        "NOOK_BUILD_SLOT_TICKET=$TICKET" "$SELF" "$@" || status=$?
      [ "$status" = "$BUSY" ] || exit "$status"
    done
  fi
  if [ "$said" = 0 ]; then
    waiting
    said=1
  fi
  sleep 2
done
