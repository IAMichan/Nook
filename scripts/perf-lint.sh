#!/bin/bash
# Checks the macOS app for the patterns that kept Nook busy while nothing happened, without a Swift toolchain.
#
#   scripts/perf-lint.sh          exit 1 and list every offending line
#
# Rules (sources under apps/macos, tests excluded):
#   1. A Combine subscription to published state (`store.$value … .sink`) drops repeats with removeDuplicates, throttle
#      or debounce. A @Published property publishes on every write, also of the same value, so a subscriber that writes
#      back to what it watches runs forever: CompanionRelayClient.apply() cleared `pending` that was already nil, which
#      published, which ran apply() again, at 100% of a core.
#      A subscription that must see every write says why on the line above: `// perf: <why every write matters>`.
#   2. Endless animations run on a `.nookFrames` timeline that pauses, never `.repeatForever`: that runs at the display's
#      own rate (up to 120 frames a second) and redraws the whole window with it.
#   3. A `TimelineView(.animation …)` passes `paused:`, so it stops when what it shows stops.
set -uo pipefail
cd "$(dirname "$0")/../apps/macos"

status=0
report() {  # $1 = rule, stdin = offending lines
  local lines; lines="$(grep -v -E '^[^:]+:[0-9]+:\s*//' || true)"
  if [ -n "$lines" ]; then
    echo "✗ $1"; echo "$lines" | sed 's/^/    /'; status=1
  else
    echo "✓ $1"
  fi
}

sources() { find . -name '*.swift' -not -path './Tests/*' -not -path './*Tests/*' | sed 's|^\./||' | sort; }

# A chain starts at a line with `x.$name` (not a TaskLocal's `.withValue`) and goes on over the lines that start with `.`.
report "subscriptions to published state drop repeats (removeDuplicates / throttle / debounce, or a // perf: reason)" < <(sources | while read -r file; do
  awk -v file="$file" '
    function flush() {
      if (start && chain ~ /\.(sink|assign)[ ({]/ && chain !~ /removeDuplicates|throttle|debounce/ && before !~ /\/\/ perf:/)
        printf "%s:%d:%s\n", file, start, first
      start = 0; chain = ""
    }
    {
      line = $0
      if (start && line ~ /^[ \t]*\/\//) next
      if (start && line ~ /^[ \t]*\./) { chain = chain "\n" line; prev = line; next }
      flush()
      if (line ~ /[A-Za-z0-9_)]\.\$[a-z][A-Za-z0-9_]*/ && line !~ /\.withValue/ && line !~ /^[ \t]*\/\//) {
        start = NR; chain = line; first = line; before = prev
      }
      prev = line
    }
    END { flush() }
  ' "$file"
done)

report "endless animations run on a pausing .nookFrames timeline (no .repeatForever)" < <(grep -rnE '\.repeatForever\(' NotchUI App --include='*.swift')

report "TimelineView(.animation) passes paused: so it stops when its content does" < <(grep -rnE 'TimelineView\(\.animation' NotchUI App --include='*.swift' | grep -v 'paused:')

exit $status
