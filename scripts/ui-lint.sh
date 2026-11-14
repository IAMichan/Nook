#!/bin/bash
# Checks that the macOS UI stays one design, without a Swift toolchain: the same rules as UIConsistencyTests, as grep.
#
#   scripts/ui-lint.sh            exit 1 and list every offending line
#
# Rules (sources under apps/macos/UI and apps/macos/App):
#   1. Type comes from NookTheme.font / mono / rounded or a NookTheme.TextStyle, never Font.system(size:) inline.
#   2. Colors come from NookTheme by name; a literal hex / RGB / gray is only allowed in the theme, in Nook's character
#      drawings, and in the files listed in OWN_COLORS (brand marks, chart series, palettes that are named once).
#   3. Corner radii come from NookTheme.Radius (chip 6, control 8, card 10, panel 12, sheet 14, pill 20, composer 24).
#   4. Text uses NookTheme.TextStyle, never SwiftUI's own text styles (.caption, .callout, .headline, .system(.body …)),
#      whose sizes do not line up with the scale.
#   5. State and text colors come from NookTheme (coral, amber, mint, textSecondary …), never the system .red, .orange,
#      .yellow, .green, .secondary, or .tertiary.
#   6. Short UI animations use NookTheme.hover / reveal / scroll / swap, never an inline .easeOut(duration: 0.15).
#   7. A search field is a NookSearchField and a divider a NookDivider (UI/Components/PanelBlocks.swift), so both
#      look and behave the same everywhere.
#   8. A pull request's state, checks and reviews take their icon and color from PullRequestIcon
#      (UI/Components/PullRequestIcons.swift): no arrow.triangle.pull / .merge, and the drawn marks only through
#      PullRequestStateIcon or NookSymbol.
#   9. Icons are drawn with Image(icon:) or NookIcon.nsImage (UI/Theme/NookIcon.swift), which turns an SF Symbol
#      name into Nook's Lucide icon; never Image(systemName:) or NSImage(systemSymbolName:) directly.
#  10. Buttons use Nook's pointer styles (.nookPlain / .nookBorderless / .nookProminent / .nookLink), which show the
#      pointing hand, never the system .plain / .borderless / .borderedProminent / .link, which keep the arrow; menus
#      likewise use .nookBorderlessButton / .nookButton.
#  11. A Label's icon goes through Image(icon:) as well: Label(_:icon:) (UI/Theme/NookIcon.swift), never
#      Label(_:systemImage:). LABEL_SYSTEM_IMAGE_PENDING lists the chat files another change is rewriting.
#  12. A section that folds open turns a DisclosureChevron, a control hidden at rest uses .revealOnHover
#      (UI/Components/HoverReveal.swift), and a clock time comes from NookDates.clock (Core/RelativeTime.swift).
#      PanelParts.swift keeps its own chevron: the iPhone app shares it, and there it follows Dynamic Type.
# Keep OWN_COLORS equal to UIConsistencyTests.ownColors, and LABEL_SYSTEM_IMAGE_PENDING to
# UIConsistencyTests.labelSystemImagePending.
set -uo pipefail
# `report` ends each pipeline below; run it in this shell so the status it sets is the one the script exits with.
shopt -s lastpipe
cd "$(dirname "$0")/../apps/macos"

OWN_COLORS=(
  "UI/Theme/NookTheme.swift"
  "UI/Components/BrandLogo.swift"
  "UI/Shared/AgentLogo.swift"
  "UI/Components/StatusStyleView.swift"
  "UI/Chat/ChatChartView.swift"
  "UI/Workspace/WorkspaceComponents.swift"
  "UI/Workspace/TerminalColors.swift"  # a command's own terminal colors (256-color cube, RGB)
  "UI/Pills/Music/MusicControls.swift"
  "App/MCPSettingsSection.swift"
  "App/Settings/SettingsStyle.swift"
  "App/Settings/SettingsView+Appearance.swift"
)

# Path prefixes that still use Label(_:systemImage:) while the chats are being rewritten elsewhere;
# drop each once that work lands.
LABEL_SYSTEM_IMAGE_PENDING=(
  "UI/Chat/"
  "UI/Components/Chat"
  "UI/Pills/Chats"
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

grep -rnE '\.font\(\s*\.system\(\s*size:' UI App --include='*.swift' | grep -v '^UI/Theme/NookTheme.swift' \
  | report "type comes from NookTheme.font / mono / rounded (no Font.system(size:))"

exclude=(-e '^UI/Character/')
for file in "${OWN_COLORS[@]}"; do exclude+=(-e "^$file:"); done
grep -rnE '\b(NS)?Color\(\s*(hex|red|white|\.sRGB)\b' UI App --include='*.swift' | grep -v "${exclude[@]}" \
  | report "colors come from NookTheme by name (no literal Color(hex:/red:/white:))"

grep -rnE '(cornerRadius:\s*|(roundedClip|roundedHitShape|NookTheme\.shape)\(\s*)(6|7|8|9|10|12|13|14|16|20)([^.0-9]|$)|(cardBackground|roundedBackground|roundedStroke|roundedStrokeBorder)\(.*radius:\s*[0-9]' UI App --include='*.swift' \
  | grep -v -e '^UI/Character/' -e '^UI/Theme/NookTheme.swift' \
  | report "corner radii come from NookTheme.Radius (no 6/7/8/9/10/12/13/14/16/20 literals)"

grep -rnE '\.font\(\s*(Font)?\.(caption2?|footnote|body|headline|subheadline|callout|title[23]?|largeTitle|system\(\s*\.)' UI App --include='*.swift' \
  | grep -v '^UI/Theme/NookTheme.swift' \
  | report "text uses NookTheme.TextStyle (no .caption / .callout / .headline / .system(.body))"

grep -rnE '\b(foregroundStyle|foregroundColor|fill|tint|stroke)\(\s*\.(red|orange|yellow|green|secondary|tertiary)\b|(^|[^A-Za-z0-9_.])Color\.(red|orange|yellow|green|secondary|tertiary)\b|return \.(red|orange|yellow|green|secondary|tertiary)\b' \
  UI App --include='*.swift' | grep -v -e '^UI/Character/' -e '^UI/Theme/NookTheme.swift' \
  | report "state and text colors come from NookTheme (no system .red / .orange / .green / .secondary)"

grep -rnE 'withAnimation\(\.(easeOut|easeInOut|easeIn)\(duration: 0\.[12][0-9]*\)\)|\.animation\(\.(easeOut|easeInOut|easeIn)\(duration: 0\.[12][0-9]*\), value:' \
  UI App --include='*.swift' | grep -v -e '^UI/Character/' -e '^UI/Theme/NookTheme.swift' \
  | report "short animations use NookTheme.hover / reveal / scroll / swap (no inline .easeOut(duration: 0.15))"

grep -rnE 'Image\((systemName|icon): "magnifyingglass"\)' UI App --include='*.swift' \
  | grep -v -e '^UI/Components/PanelBlocks.swift:' -e '^UI/Pills/TimelineFind.swift:' \
  | report "search fields are a NookSearchField (no magnifying glass and text field built inline)"

grep -rnE '(^|[^A-Za-z])Image\(systemName:|NSImage\(systemSymbolName:' UI App --include='*.swift' \
  | grep -v '^UI/Theme/NookIcon.swift:' \
  | report "icons go through Image(icon:) / NookIcon.nsImage, so they are Nook's Lucide icons (no raw SF Symbols)"

pending=()
for prefix in "${LABEL_SYSTEM_IMAGE_PENDING[@]}"; do pending+=(-e "^$prefix"); done
grep -rnE '\bsystemImage:' UI App --include='*.swift' | grep -v "${pending[@]}" \
  | report "labels draw their icon through Label(_:icon:) (no Label(_:systemImage:))"

grep -rnE 'RoundedRectangle\(cornerRadius:' UI App --include='*.swift' \
  | grep -v '^UI/Theme/NookTheme.swift:' \
  | report "rounded shapes come from NookTheme.shape / .roundedBackground / .roundedStroke / .roundedClip (no RoundedRectangle built inline)"

grep -rnE '\.(background|overlay|contentShape|clipShape)\(Capsule\(' UI App --include='*.swift' \
  | report "chips and buttons sit on NookTheme.Radius.chip / .control (no Capsule behind words; Capsule is for bars and tracks)"

grep -rnE 'Rectangle\(\)\.fill\(NookTheme\.(line|line2|hairline|separator)[^)]*\)\.frame\(height: 1\)' UI App --include='*.swift' \
  | grep -v '^UI/Components/PanelBlocks.swift:' \
  | report "dividers are a NookDivider (no 1 pt Rectangle drawn inline)"

grep -rnE '"arrow\.triangle\.(pull|merge)"|PullRequestStateGlyph\(' UI App --include='*.swift' \
  | grep -v -e '^UI/Components/PullRequestIcons.swift:' -e '^UI/Components/NookSymbol.swift:' -e '^UI/Pills/AgentsExtras.swift:' \
  | report "pull request icons come from PullRequestIcon / PullRequestStateIcon (no arrow.triangle.pull or a hand-sized mark)"

grep -rnE '\.buttonStyle\(\s*\.(plain|borderless|borderedProminent|bordered|link)\s*\)' UI App --include='*.swift' \
  | report "buttons show the pointing hand (.nookPlain / .nookBorderless / .nookProminent / .nookLink, not the system styles)"

grep -rnE '\.textFieldStyle\(\s*\.roundedBorder\s*\)' App --include='*.swift' | grep -E '^App/(Settings/|[^/]*Settings)' \
  | report "Settings text fields use .settingsField() (no system .roundedBorder)"

grep -rnE '\.menuStyle\(\s*\.(borderlessButton|button)\s*\)' UI App --include='*.swift' \
  | report "menus show the pointing hand (.nookBorderlessButton / .nookButton, not the system menu styles)"

grep -rnE -A3 'Image\(icon: "chevron\.(right|down|up|left)"\)' UI App --include='*.swift' \
  | grep -E '^[^:]+-[0-9]+-.*\.rotationEffect\(' \
  | grep -v -e '^UI/Components/HoverReveal.swift-' -e '^UI/Shared/PanelParts.swift-' \
  | report "folding chevrons are a DisclosureChevron (no chevron image with a rotationEffect of its own)"

grep -rnE -A1 '\.opacity\(.+ \? 1 : 0\)\s*$' UI App --include='*.swift' \
  | grep -E '^[^:]+-[0-9]+-\s*\.allowsHitTesting\(' \
  | grep -v '^UI/Components/HoverReveal.swift-' \
  | report "controls hidden at rest use .revealOnHover (no opacity and allowsHitTesting by hand)"

grep -rnE 'dateFormat\s*=\s*"H{1,2}:mm"' UI App --include='*.swift' \
  | report "clock times come from NookDates.clock / clockOrDay / dayAndClock (no DateFormatter of a view's own for HH:mm)"

exit $status
