#!/bin/bash
# Runs the end-to-end scenarios (docs/SCENARIOS.md): the real app code in a test process, with the replay agent instead
# of a model, offscreen, against a fresh scenario home. Nook.app is not launched and nothing outside the scenario home
# is written.
#
#   scripts/scenarios.sh                              # all of them
#   scripts/scenarios.sh ReplayTurnStreams            # one (the class name; several may follow)
#
# Results: .scratch/scenarios/out/report.json, summary.md, and per scenario results/<name>/ with result.json and its
# screenshots. Exit 0 when every scenario passed, 1 when one failed (an expectation did not hold), 2 when one could not
# run (build, setup, missing element) or no report came out.
#
# For scripts/prove-scenario.sh: NOOK_SCENARIO_APP_DIR builds and runs another checkout (with the scenarios laid over it),
# NOOK_SCENARIO_WORK_DIR moves the home and output folders. One run at a time per checkout.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${NOOK_SCENARIO_APP_DIR:-$REPO}"
WORK="${NOOK_SCENARIO_WORK_DIR:-$REPO/.scratch/scenarios}"
HOME_DIR="$WORK/home"
OUT_DIR="$WORK/out"
LOCK="$WORK/.lock"

mkdir -p "$WORK"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another scenario run uses $WORK (remove $LOCK if none does)." >&2
  exit 2
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

rm -rf "$HOME_DIR" "$OUT_DIR"
mkdir -p "$HOME_DIR" "$OUT_DIR/results"
chmod 700 "$HOME_DIR"

ONLY=()
if [ $# -eq 0 ]; then
  ONLY=(-only-testing:NookScenarios)
else
  for name in "$@"; do ONLY+=("-only-testing:NookScenarios/$name"); done
fi

echo "Building and running scenarios in $APP_DIR (log: $OUT_DIR/xcodebuild.log)"
# TEST_RUNNER_* reach the test process without the prefix. CFFIXED_USER_HOME makes the scenario home the process's home
# folder for everything the app derives from it (Application Support, ~/.nook, ~/.claude).
NOOK_XCODE_SCHEME=NookScenarios \
TEST_RUNNER_CFFIXED_USER_HOME="$HOME_DIR" \
TEST_RUNNER_NOOK_SCENARIO_HOME="$HOME_DIR" \
TEST_RUNNER_NOOK_SCENARIO_OUT="$OUT_DIR" \
  "$APP_DIR/scripts/xcode.sh" test "${ONLY[@]}" -parallel-testing-enabled NO >"$OUT_DIR/xcodebuild.log" 2>&1 &
XCODE_PID=$!

# On GitHub's macOS 15 runners xcodebuild never exits after the last scenario: the test process is gone, but xcodebuild
# and its DTServiceHub keep waiting until the step times out. So once the top test suite has reported, xcodebuild gets
# NOOK_SCENARIO_EXIT_GRACE seconds (default 60) to finish, then it is stopped and the suite's own verdict counts.
LOG="$OUT_DIR/xcodebuild.log"
GRACE="${NOOK_SCENARIO_EXIT_GRACE:-60}"
SUITE_DONE='^Test Suite '\''(All tests|Selected tests)'\'' (passed|failed) at'
FINISHED_AT=""
STOPPED=0
while kill -0 "$XCODE_PID" 2>/dev/null; do
  if [ -z "$FINISHED_AT" ] && grep -qE "$SUITE_DONE" "$LOG" 2>/dev/null; then FINISHED_AT=$SECONDS; fi
  if [ -n "$FINISHED_AT" ] && [ $((SECONDS - FINISHED_AT)) -ge "$GRACE" ]; then
    echo "xcodebuild still running ${GRACE}s after the last scenario; stopping it." | tee -a "$LOG" >&2
    pkill -TERM -P "$XCODE_PID" 2>/dev/null
    kill -TERM "$XCODE_PID" 2>/dev/null
    sleep 5
    pkill -KILL -P "$XCODE_PID" 2>/dev/null
    kill -KILL "$XCODE_PID" 2>/dev/null
    STOPPED=1
    break
  fi
  sleep 2
done
wait "$XCODE_PID"
XCODE_STATUS=$?
if [ "$STOPPED" = 1 ]; then
  # 65 is what xcodebuild itself returns when a test failed.
  if grep -qE '^Test Suite '\''(All tests|Selected tests)'\'' passed at' "$LOG"; then XCODE_STATUS=0; else XCODE_STATUS=65; fi
fi

if [ ! -f "$OUT_DIR/report.json" ]; then
  # Nothing ran: the build failed or the test process did not start.
  REASON="no scenario wrote a result (xcodebuild exited $XCODE_STATUS; see xcodebuild.log)"
  grep -E "error:|BUILD FAILED|TEST FAILED|\*\* " "$OUT_DIR/xcodebuild.log" | tail -n 15 >&2
  printf '{\n  "error" : "%s",\n  "results" : [\n\n  ]\n}\n' "$REASON" >"$OUT_DIR/report.json"
  printf '# Scenarios\n\nCould not run: %s.\n' "$REASON" >"$OUT_DIR/summary.md"
  echo "Could not run: $REASON" >&2
  exit 2
fi

# A scenario that was asked for but wrote no result crashed the test process: it could not run.
MISSING=0
for name in "$@"; do
  # grep reads all of ls (no -q): with pipefail, ls dying of SIGPIPE after an early match read as "no result".
  if ! ls "$OUT_DIR/results" | grep -E "^$name(-|$)" >/dev/null; then
    echo "$name wrote no result (see xcodebuild.log)" >&2
    MISSING=1
  fi
done

cat "$OUT_DIR/summary.md"
if grep -q '"status" : "error"' "$OUT_DIR/report.json" || [ "$MISSING" = 1 ]; then exit 2; fi
if grep -q '"status" : "failed"' "$OUT_DIR/report.json"; then exit 1; fi
if [ "$XCODE_STATUS" != 0 ]; then
  echo "xcodebuild exited $XCODE_STATUS although every scenario passed (see xcodebuild.log)" >&2
  exit 2
fi
exit 0
