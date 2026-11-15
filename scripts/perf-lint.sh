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
#   4. A loop that shows work under way (a pulse, a halo, a spinner, a shimmer, dots) is a `LayerLoop`, `ShimmerLayer` or
#      `LayerLevelBars` (LayerLoops.swift): Core Animation draws it in the render server and the main thread does nothing per
#      frame. A SwiftUI timeline draws every frame on the main thread, once for each running session in the list. A
#      `.nookFrames` timeline that must stay one (it follows the pointer or live levels) says why on the line above:
#      `// perf: <why>`.
#   5. A symbol that pulses or turns for as long as something runs is a `LayerSymbol` (LayerLoops.swift). `.symbolEffect`
#      is a SwiftUI animation: measured offscreen, a single repeating symbol lays out its window 100 times a second, as
#      `.repeatForever` does, and that window can hold a long chat. A one-shot effect (`.bounce`, `value:`) says so on
#      the line above: `// perf: <why>`.
#   6. A name taken from a path is `(path as NSString).lastPathComponent`, not `URL(fileURLWithPath: path).lastPathComponent`:
#      without `isDirectory:` that URL asks the disk whether the path is a folder (a `stat`, ~5 µs against ~1 µs), and
#      these run per event of a transcript, per session of a scan and per row of a redraw.
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

report "endless animations run on a pausing .nookFrames timeline (no .repeatForever)" < <(grep -rnE '\.repeatForever\(' UI App --include='*.swift')

report "TimelineView(.animation) passes paused: so it stops when its content does" < <(grep -rnE 'TimelineView\(\.animation' UI App --include='*.swift' | grep -v 'paused:')

report "looping animations are a LayerLoop; a .nookFrames timeline says why not (// perf: reason)" < <(sources | grep -E '^(UI|App)/' | while read -r file; do
  awk -v file="$file" '
    /TimelineView\(\.nookFrames/ && $0 !~ /^[ \t]*\/\// {
      if (prev !~ /\/\/ perf:/) printf "%s:%d:%s\n", file, NR, $0
    }
    { prev = $0 }
  ' "$file"
done)

report "symbols that loop are a LayerSymbol; a .symbolEffect says why not (// perf: reason)" < <(sources | while read -r file; do
  awk -v file="$file" '
    /\.symbolEffect\(/ && $0 !~ /^[ \t]*\/\// {
      if (prev !~ /\/\/ perf:/) printf "%s:%d:%s\n", file, NR, $0
    }
    { prev = $0 }
  ' "$file"
done)

report "a name from a path is (path as NSString).lastPathComponent (no URL(fileURLWithPath:) stat for it)" < <(grep -rnE 'URL\(fileURLWithPath: [^()]+\)\.lastPathComponent' Core Services UI App --include='*.swift')

exit $status
