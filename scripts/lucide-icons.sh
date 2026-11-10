#!/bin/bash
# Regenerates apps/macos/Resources/Lucide.xcassets: one custom SF Symbol per Lucide icon named in NookIcon.table
# (apps/macos/NotchUI/Theme/NookIcon.swift). Lucide's stroked 24×24 SVGs become symbol templates with SwiftDraw, which also
# derives the ultralight and black weights, so the icons follow the font weight around them like an SF Symbol.
#
#   scripts/lucide-icons.sh            needs npm and swiftdraw (brew install swiftdraw)
#
# Lucide is ISC licensed (see THIRD-PARTY-NOTICES.md). Bump LUCIDE_VERSION to take newer icons.
set -euo pipefail

LUCIDE_VERSION="0.564.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TABLE="$ROOT/apps/macos/NotchUI/Theme/NookIcon.swift"
OUT="$ROOT/apps/macos/Resources/Lucide.xcassets"

command -v swiftdraw >/dev/null || { echo "swiftdraw is missing: brew install swiftdraw" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nook-lucide.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
(cd "$WORK" && npm pack "lucide-static@$LUCIDE_VERSION" --silent >/dev/null && tar xzf "lucide-static-$LUCIDE_VERSION.tgz")
ICONS="$WORK/package/icons"

# The right-hand side of every `"sf.name": "lucide-name",` row.
NAMES=$(sed -nE 's/^ *"[^"]+": "([a-z0-9-]+)",$/\1/p' "$TABLE" | sort -u)

rm -rf "$OUT"
mkdir -p "$OUT"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$OUT/Contents.json"

count=0
for name in $NAMES; do
  [ -f "$ICONS/$name.svg" ] || { echo "Lucide $LUCIDE_VERSION has no icon \"$name\"" >&2; exit 1; }
  set="$OUT/lucide.$name.symbolset"
  mkdir -p "$set"
  # Lucide draws in 2..22 of its 24 grid. Aligning that 20 pt box (insets of 2) to the symbol's cap height makes every
  # icon the size of the SF Symbol it replaces at the same font size, and all icons the same size; SwiftDraw's default
  # ("auto") fits each one to its own outline and draws them about 40 % smaller.
  swiftdraw "$ICONS/$name.svg" --format sfsymbol --insets 2,2,2,2 --ultralight-insets 2,2,2,2 --black-insets 2,2,2,2 \
    --output "$set/lucide.$name.svg" >/dev/null
  printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "symbols" : [\n    {\n      "filename" : "lucide.%s.svg",\n      "idiom" : "universal"\n    }\n  ]\n}\n' "$name" > "$set/Contents.json"
  count=$((count + 1))
done
echo "Wrote $count Lucide symbols to ${OUT#$ROOT/}"
