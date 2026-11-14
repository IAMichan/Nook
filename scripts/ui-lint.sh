#!/bin/bash
# Checks that the macOS UI stays one design, without a Swift toolchain: the same rules as UIConsistencyTests, as grep.
#
#   scripts/ui-lint.sh            exit 1 and list every offending line
#
# Rules (sources under apps/macos/NotchUI and apps/macos/App):
#   1. Type comes from NookTheme.font / mono / rounded or a NookTheme.TextStyle, never Font.system(size:) inline.
#   2. Colors come from NookTheme by name; a literal hex / RGB / gray is only allowed in the theme, in Nook's character
#      drawings, and in the files listed in OWN_COLORS (brand marks, chart series, palettes that are named once).
#   3. Corner radii come from NookTheme.Radius (chip 6, control 8, card 10, panel 12, sheet 14, pill 20, composer 24).
#   4. Text uses NookTheme.TextStyle, never SwiftUI's own text styles (.caption, .callout, .headline, .system(.body …)),
#      whose sizes do not line up with the scale.
#   5. State and text colors come from NookTheme (coral, amber, mint, textSecondary …), never the system .red, .orange,
#      .yellow, .green, .secondary, or .tertiary.
#   6. Short UI animations use NookTheme.hover / reveal / scroll / swap, never an inline .easeOut(duration: 0.15).
#   7. A search field is a NookSearchField and a divider a NookDivider (NotchUI/Components/PanelBlocks.swift), so both
#      look and behave the same everywhere.
#   8. A pull request's state, checks and reviews take their icon and color from PullRequestIcon
#      (NotchUI/Components/PullRequestIcons.swift): no arrow.triangle.pull / .merge, and the drawn marks only through
#      PullRequestStateIcon or NookSymbol.
#   9. Icons are drawn with Image(icon:) or NookIcon.nsImage (NotchUI/Theme/NookIcon.swift), which turns an SF Symbol
#      name into Nook's Lucide icon; never Image(systemName:) or NSImage(systemSymbolName:) directly.
#  10. Buttons use Nook's pointer styles (.nookPlain / .nookBorderless / .nookProminent / .nookLink), which show the
#      pointing hand, never the system .plain / .borderless / .borderedProminent / .link, which keep the arrow; menus
#      likewise use .nookBorderlessButton / .nookButton.
#  11. A Label's icon goes through Image(icon:) as well: Label(_:icon:) (NotchUI/Theme/NookIcon.swift), never
#      Label(_:systemImage:). LABEL_SYSTEM_IMAGE_PENDING lists the chat files another change is rewriting.
#  12. A section that folds open turns a DisclosureChevron, a control hidden at rest uses .revealOnHover
#      (NotchUI/Components/HoverReveal.swift), and a clock time comes from NookDates.clock (Core/RelativeTime.swift).
#      PanelParts.swift keeps its own chevron: the iPhone app shares it, and there it follows Dynamic Type.
# Keep OWN_COLORS equal to UIConsistencyTests.ownColors, and LABEL_SYSTEM_IMAGE_PENDING to
# UIConsistencyTests.labelSystemImagePending.
set -uo pipefail
# `report` reads each check from a process substitution, so it runs in this shell and the status it sets is the one
# the script exits with. (Not `cmd | report` with `shopt -s lastpipe`: macOS's /bin/bash 3.2 has no lastpipe, so
# report ran in a subshell there and the script passed whatever it found.)
cd "$(dirname "$0")/../apps/macos"

OWN_COLORS=(
  "NotchUI/Theme/NookTheme.swift"
  "NotchUI/Components/BrandLogo.swift"
  "NotchUI/Shared/AgentLogo.swift"
  "NotchUI/Components/StatusStyleView.swift"
  "NotchUI/Chat/ChatChartView.swift"
  "NotchUI/Workspace/WorkspaceComponents.swift"
  "NotchUI/Workspace/TerminalColors.swift"  # a command's own terminal colors (256-color cube, RGB)
  "NotchUI/Pills/Music/MusicControls.swift"
  "App/MCPSettingsSection.swift"
  "App/Settings/SettingsStyle.swift"
  "App/Settings/SettingsView+Appearance.swift"
)

# Path prefixes that still use Label(_:systemImage:) while the chats are being rewritten elsewhere;
# drop each once that work lands.
LABEL_SYSTEM_IMAGE_PENDING=(
  "NotchUI/Chat/"
  "NotchUI/Components/Chat"
  "NotchUI/Pills/Chats"
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

report "type comes from NookTheme.font / mono / rounded (no Font.system(size:))" < <(grep -rnE '\.font\(\s*\.system\(\s*size:' NotchUI App --include='*.swift' | grep -v '^NotchUI/Theme/NookTheme.swift')

exclude=(-e '^NotchUI/Character/')
for file in "${OWN_COLORS[@]}"; do exclude+=(-e "^$file:"); done
report "colors come from NookTheme by name (no literal Color(hex:/red:/white:))" < <(grep -rnE '\b(NS)?Color\(\s*(hex|red|white|\.sRGB)\b' NotchUI App --include='*.swift' | grep -v "${exclude[@]}")

report "corner radii come from NookTheme.Radius (no 6/7/8/9/10/12/13/14/16/20 literals)" < <(grep -rnE '(cornerRadius:\s*|(roundedClip|roundedHitShape|NookTheme\.shape)\(\s*)(6|7|8|9|10|12|13|14|16|20)([^.0-9]|$)|(cardBackground|roundedBackground|roundedStroke|roundedStrokeBorder)\(.*radius:\s*[0-9]' NotchUI App --include='*.swift' \
  | grep -v -e '^NotchUI/Character/' -e '^NotchUI/Theme/NookTheme.swift')

report "text uses NookTheme.TextStyle (no .caption / .callout / .headline / .system(.body))" < <(grep -rnE '\.font\(\s*(Font)?\.(caption2?|footnote|body|headline|subheadline|callout|title[23]?|largeTitle|system\(\s*\.)' NotchUI App --include='*.swift' \
  | grep -v '^NotchUI/Theme/NookTheme.swift')

report "state and text colors come from NookTheme (no system .red / .orange / .green / .secondary)" < <(grep -rnE '\b(foregroundStyle|foregroundColor|fill|tint|stroke)\(\s*\.(red|orange|yellow|green|secondary|tertiary)\b|(^|[^A-Za-z0-9_.])Color\.(red|orange|yellow|green|secondary|tertiary)\b|return \.(red|orange|yellow|green|secondary|tertiary)\b' \
  NotchUI App --include='*.swift' | grep -v -e '^NotchUI/Character/' -e '^NotchUI/Theme/NookTheme.swift')

report "short animations use NookTheme.hover / reveal / scroll / swap (no inline .easeOut(duration: 0.15))" < <(grep -rnE 'withAnimation\(\.(easeOut|easeInOut|easeIn)\(duration: 0\.[12][0-9]*\)\)|\.animation\(\.(easeOut|easeInOut|easeIn)\(duration: 0\.[12][0-9]*\), value:' \
  NotchUI App --include='*.swift' | grep -v -e '^NotchUI/Character/' -e '^NotchUI/Theme/NookTheme.swift')

report "search fields are a NookSearchField (no magnifying glass and text field built inline)" < <(grep -rnE 'Image\((systemName|icon): "magnifyingglass"\)' NotchUI App --include='*.swift' \
  | grep -v -e '^NotchUI/Components/PanelBlocks.swift:' -e '^NotchUI/Pills/TimelineFind.swift:')

report "icons go through Image(icon:) / NookIcon.nsImage, so they are Nook's Lucide icons (no raw SF Symbols)" < <(grep -rnE '(^|[^A-Za-z])Image\(systemName:|NSImage\(systemSymbolName:' NotchUI App --include='*.swift' \
  | grep -v '^NotchUI/Theme/NookIcon.swift:')

pending=()
for prefix in "${LABEL_SYSTEM_IMAGE_PENDING[@]}"; do pending+=(-e "^$prefix"); done
report "labels draw their icon through Label(_:icon:) (no Label(_:systemImage:))" < <(grep -rnE '\bsystemImage:' NotchUI App --include='*.swift' | grep -v "${pending[@]}")

report "rounded shapes come from NookTheme.shape / .roundedBackground / .roundedStroke / .roundedClip (no RoundedRectangle built inline)" < <(grep -rnE 'RoundedRectangle\(cornerRadius:' NotchUI App --include='*.swift' \
  | grep -v '^NotchUI/Theme/NookTheme.swift:')

report "chips and buttons sit on NookTheme.Radius.chip / .control (no Capsule behind words; Capsule is for bars and tracks)" < <(grep -rnE '\.(background|overlay|contentShape|clipShape)\(Capsule\(' NotchUI App --include='*.swift')

report "dividers are a NookDivider (no 1 pt Rectangle drawn inline)" < <(grep -rnE 'Rectangle\(\)\.fill\(NookTheme\.(line|line2|hairline|separator)[^)]*\)\.frame\(height: 1\)' NotchUI App --include='*.swift' \
  | grep -v '^NotchUI/Components/PanelBlocks.swift:')

report "pull request icons come from PullRequestIcon / PullRequestStateIcon (no arrow.triangle.pull or a hand-sized mark)" < <(grep -rnE '"arrow\.triangle\.(pull|merge)"|PullRequestStateGlyph\(' NotchUI App --include='*.swift' \
  | grep -v -e '^NotchUI/Components/PullRequestIcons.swift:' -e '^NotchUI/Components/NookSymbol.swift:' -e '^NotchUI/Pills/AgentsExtras.swift:')

report "buttons show the pointing hand (.nookPlain / .nookBorderless / .nookProminent / .nookLink, not the system styles)" < <(grep -rnE '\.buttonStyle\(\s*\.(plain|borderless|borderedProminent|bordered|link)\s*\)' NotchUI App --include='*.swift')

report "Settings text fields use .settingsField() (no system .roundedBorder)" < <(grep -rnE '\.textFieldStyle\(\s*\.roundedBorder\s*\)' App --include='*.swift' | grep -E '^App/(Settings/|[^/]*Settings)')

report "menus show the pointing hand (.nookBorderlessButton / .nookButton, not the system menu styles)" < <(grep -rnE '\.menuStyle\(\s*\.(borderlessButton|button)\s*\)' NotchUI App --include='*.swift')

report "folding chevrons are a DisclosureChevron (no chevron image with a rotationEffect of its own)" < <(grep -rnE -A3 'Image\(icon: "chevron\.(right|down|up|left)"\)' NotchUI App --include='*.swift' \
  | grep -E '^[^:]+-[0-9]+-.*\.rotationEffect\(' \
  | grep -v -e '^NotchUI/Components/HoverReveal.swift-' -e '^NotchUI/Shared/PanelParts.swift-')

report "controls hidden at rest use .revealOnHover (no opacity and allowsHitTesting by hand)" < <(grep -rnE -A1 '\.opacity\(.+ \? 1 : 0\)\s*$' NotchUI App --include='*.swift' \
  | grep -E '^[^:]+-[0-9]+-\s*\.allowsHitTesting\(' \
  | grep -v '^NotchUI/Components/HoverReveal.swift-')

report "clock times come from NookDates.clock / clockOrDay / dayAndClock (no DateFormatter of a view's own for HH:mm)" < <(grep -rnE 'dateFormat\s*=\s*"H{1,2}:mm"' NotchUI App --include='*.swift')

exit $status
