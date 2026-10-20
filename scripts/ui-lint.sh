#!/bin/bash
# Checks that the macOS UI stays one design, without a Swift toolchain: the same rules as UIConsistencyTests, as grep.
#
#   scripts/ui-lint.sh            exit 1 and list every offending line
#
# Rules (sources under apps/macos/NotchUI and apps/macos/App):
#   1. Type comes from NookTheme.font / mono / rounded or a NookTheme.TextStyle, never Font.system(size:) inline.
#   2. Colors come from NookTheme by name; a literal hex / RGB / gray is only allowed in the theme, in Nook's character
#      drawings, and in the files listed in OWN_COLORS (brand marks, chart series, palettes that are named once).
#   3. Corner radii come from NookTheme.Radius (chip 6, control 8, card 10, panel 12, sheet 14, pill 20).
# Keep OWN_COLORS equal to UIConsistencyTests.ownColors.
set -uo pipefail
cd "$(dirname "$0")/../apps/macos"

OWN_COLORS=(
  "NotchUI/Theme/NookTheme.swift"
  "NotchUI/Components/BrandLogo.swift"
  "NotchUI/Components/AgentLogo.swift"
  "NotchUI/Components/StatusStyleView.swift"
  "NotchUI/Components/ComposerDropdown.swift"
  "NotchUI/Chat/ChatChartView.swift"
  "NotchUI/Workspace/WorkspaceComponents.swift"
  "NotchUI/Pills/Music/MusicControls.swift"
  "App/MCPSettingsSection.swift"
  "App/Settings/SettingsStyle.swift"
  "App/Settings/SettingsView+Appearance.swift"
)

status=0
report() {  # $1 = rule, stdin = offending lines
  local lines; lines="$(grep -v -E '^[^:]+:[0-9]+:\s*//' || true)"
  if [ -n "$lines" ]; then
    echo "✗ $1"; echo "$lines" | sed 's/^/    /'; status=1
  else
    echo "✓ $1"
  fi
}

grep -rnE '\.font\(\s*\.system\(\s*size:' NotchUI App --include='*.swift' | grep -v '^NotchUI/Theme/NookTheme.swift' \
  | report "type comes from NookTheme.font / mono / rounded (no Font.system(size:))"

exclude=(-e '^NotchUI/Character/')
for file in "${OWN_COLORS[@]}"; do exclude+=(-e "^$file:"); done
grep -rnE '\b(NS)?Color\(\s*(hex|red|white|\.sRGB)\b' NotchUI App --include='*.swift' | grep -v "${exclude[@]}" \
  | report "colors come from NookTheme by name (no literal Color(hex:/red:/white:))"

grep -rnE 'cornerRadius:\s*(6|7|8|9|10|12|13|14|16|20)([^.0-9]|$)' NotchUI App --include='*.swift' \
  | grep -v -e '^NotchUI/Character/' -e '^NotchUI/Theme/NookTheme.swift' \
  | report "corner radii come from NookTheme.Radius (no 6/7/8/9/10/12/13/14/16/20 literals)"

exit $status
