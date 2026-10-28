#!/bin/bash
# Measures what a running Nook costs while you leave it alone, and where the time goes. Read-only: it attaches `sample`
# for a few seconds and never starts or stops Nook.
#
#   scripts/idle-profile.sh               the running Nook, 5 seconds
#   scripts/idle-profile.sh 15            sample for 15 seconds
#   scripts/idle-profile.sh 5 <pid>       a given process
#
# It prints the CPU of the whole process and of its main thread over the window, the memory footprint (dirty memory,
# not the mmapped models Activity Monitor adds to "Memory"), the models that are mapped in, and the Nook functions the
# main thread spent its samples in. At rest the main thread should be near 0%; a function that shows up here with
# hundreds of samples while nothing happens is a loop or a timer to look at.
set -euo pipefail

seconds="${1:-5}"
pid="${2:-$(pgrep -f 'Nook\.app/Contents/MacOS/Nook( |$)' | head -1 || true)}"
[ -n "$pid" ] || { echo "Nook is not running." >&2; exit 1; }

cpu_seconds() {  # $1 = "[[dd-]hh:]mm:ss.ss" → seconds
  awk '{ days = 0; if (sub(/^[0-9]+-/, "&")) { days = $0 + 0; sub(/^[0-9]+-/, "") }
         n = split($0, part, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + part[i]; print days * 86400 + s }' <<<"$1"
}
main_cpu() { ps -M -p "$pid" | awk 'NR == 2 { print $8 }'; }   # the main thread is listed first; column 8 is its user time

out="$(mktemp -t nook-idle)"
trap 'rm -f "$out"' EXIT

before=$(cpu_seconds "$(ps -o time= -p "$pid" | tr -d ' ')")
main_before=$(cpu_seconds "$(main_cpu)")
sample "$pid" "$seconds" 1 -file "$out" >/dev/null 2>&1
after=$(cpu_seconds "$(ps -o time= -p "$pid" | tr -d ' ')")
main_after=$(cpu_seconds "$(main_cpu)")

printf 'Nook %s, %s s\n' "$pid" "$seconds"
awk -v a="$before" -v b="$after" -v s="$seconds" 'BEGIN { printf "  CPU (process):     %5.1f%%\n", (b - a) / s * 100 }'
awk -v a="$main_before" -v b="$main_after" -v s="$seconds" 'BEGIN { printf "  CPU (main thread): %5.1f%%   (user time)\n", (b - a) / s * 100 }'
footprint "$pid" 2>/dev/null | awk '/Footprint:/ { sub(/.*Footprint: /, ""); sub(/ \(.*/, ""); print "  Footprint:         " $0; exit }'

models="$(lsof -p "$pid" 2>/dev/null | grep -iE '\.(gguf|safetensors)$' | awk '{ print $NF }' | sed 's|.*/||' | sort -u || true)"
echo "  Models mapped in:  ${models:-none}" | sed '2,$s/^/                     /'

echo
echo "Nook functions on the main thread (samples, inclusive; ~1 per ms):"
start=$(grep -n 'Thread_[0-9]*: Main Thread\|com.apple.main-thread' "$out" | head -1 | cut -d: -f1)
end=$(awk -v s="$start" 'NR > s && /^    [0-9]+ Thread_/ { print NR; exit }' "$out")
sed -n "${start},${end:-\$}p" "$out" \
  | grep -E '\(in Nook(\.debug\.dylib)?\)' \
  | sed -E 's/^[ +!:|]*//; s/ +\(in Nook[^)]*\).*//' \
  | grep -vE 'assumeIsolated|^[0-9]+ (thunk|partial apply|closure #1 in *$|__debug_main|main$)' \
  | awk '{ n = $1; $1 = ""; total[$0] += n } END { for (f in total) printf "%7d %s\n", total[f], f }' \
  | sort -nr | head -15
