import XCTest

/// The notch, the main window, and Settings stay one design: every view takes its colors, type, and corner radii from
/// `NookTheme` instead of inventing its own. The sources under `NotchUI` and `App` are read as text (like
/// `I18nCoverageTests`), so the test needs nothing of the app and also runs through `scripts/core-tests.sh`.
///
/// `scripts/ui-lint.sh` checks the same rules without a Swift toolchain; keep the two in step.
final class UIConsistencyTests: XCTestCase {
    /// `apps/macos`: from the environment when the tests run as a throwaway package, else relative to this file.
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    /// Files whose literal colors are part of what they draw: the theme itself, Nook's face and accessories, brand marks,
    /// chart series, and palettes that are named once and used through their name.
    private static let ownColors: Set<String> = [
        "NotchUI/Theme/NookTheme.swift",
        "NotchUI/Components/BrandLogo.swift",
        "NotchUI/Shared/AgentLogo.swift",
        "NotchUI/Components/StatusStyleView.swift",
        "NotchUI/Components/ComposerDropdown.swift",
        "NotchUI/Chat/ChatChartView.swift",
        "NotchUI/Workspace/WorkspaceComponents.swift",
        // A command's own terminal colors (256-color cube, RGB) in a tool call's output.
        "NotchUI/Workspace/TerminalColors.swift",
        "NotchUI/Pills/Music/MusicControls.swift",
        "App/MCPSettingsSection.swift",
        "App/Settings/SettingsStyle.swift",
        "App/Settings/SettingsView+Appearance.swift",
    ]

    /// All Swift sources of the user interface, as (path relative to `apps/macos`, text).
    private static let sources: [(path: String, text: String)] = {
        var result: [(String, String)] = []
        for folder in ["NotchUI", "App"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = folder + "/" + String(url.path.dropFirst(base.path.count + 1))
                result.append((relative, text))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }()

    private func isCharacter(_ path: String) -> Bool { path.hasPrefix("NotchUI/Character/") }

    /// "path:line: text" for every line of every source that matches `pattern`, skipping `excluded` files.
    private func offenders(_ pattern: String, excluding excluded: (String) -> Bool = { _ in false }) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for (path, text) in Self.sources where !excluded(path) {
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(path):\(index + 1): \(trimmed)")
                }
            }
        }
        return found
    }

    func testTheSourcesWereFound() {
        XCTAssertGreaterThan(Self.sources.count, 100, "UI sources not read from \(Self.root.path)")
        XCTAssertTrue(Self.sources.contains { $0.path == "NotchUI/Theme/NookTheme.swift" })
    }

    /// Type comes from the scale: `NookTheme.font`, `mono`, `rounded`, or a `TextStyle`, never `Font.system(size:)` inline.
    func testFontsComeFromTheTheme() {
        let found = offenders(#"\.font\(\s*\.system\(\s*size:"#) { $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.font / mono / rounded instead of Font.system(size:)")
    }

    /// Colors come from the theme: a literal hex, RGB, or gray belongs in `NookTheme` (or in a file that draws something
    /// of its own, listed in `ownColors`) and is used everywhere else by name.
    func testColorsComeFromTheTheme() {
        let literal = #"\b(NS)?Color\(\s*(hex|red|white|\.sRGB)\b"#
        let found = offenders(literal) { Self.ownColors.contains($0) || self.isCharacter($0) }
        XCTAssertEqual(found, [], "use a NookTheme color, or add the file to UIConsistencyTests.ownColors when it draws its own")
    }

    /// Corners sit on the radius scale: `NookTheme.Radius.chip … pill`, not a number that happens to look right.
    func testCornerRadiiComeFromTheScale() {
        let found = offenders(#"(cornerRadius:\s*|(roundedClip|roundedHitShape|NookTheme\.shape)\(\s*)(6|7|8|9|10|12|13|14|16|20)(?![.0-9])|(cardBackground|roundedBackground|roundedStroke|roundedStrokeBorder)\(.*radius:\s*[0-9]"#) { self.isCharacter($0) || $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.Radius (chip 6, control 8, card 10, panel 12, sheet 14, pill 20, composer 24)")
    }

    /// A rounded shape is Nook's: `NookTheme.shape(_:)` or a `.rounded…` helper (a continuous corner on a radius from the
    /// scale), never a `RoundedRectangle(cornerRadius:)` built at the call site with a corner style of its own.
    func testRoundedShapesComeFromTheTheme() {
        let found = offenders(#"RoundedRectangle\(cornerRadius:"#) { $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.shape(_:) or .roundedBackground / .roundedStroke / .roundedClip / .roundedHitShape")
    }

    /// Chips, badges and buttons are rounded rectangles on the chip or control radius, never a pill:
    /// `Capsule()` is only for shapes without words (progress tracks, indicator bars, drag handles).
    func testChipsAndButtonsAreNotPills() {
        let found = offenders(#"\.(background|overlay|contentShape|clipShape)\(Capsule\("#) { _ in false }
        XCTAssertEqual(found, [], "use NookTheme.shape(NookTheme.Radius.chip) or .control instead of a Capsule behind words")
    }

    /// Text sits on the type scale: SwiftUI's own styles (`.caption`, `.callout`, `.headline`, `.system(.body)`) have
    /// sizes of their own that do not line up with `NookTheme.TextStyle`.
    func testTextUsesTheTypeScale() {
        let found = offenders(#"\.font\(\s*(Font)?\.(caption2?|footnote|body|headline|subheadline|callout|title[23]?|largeTitle|system\(\s*\.)"#) {
            $0 == "NotchUI/Theme/NookTheme.swift"
        }
        XCTAssertEqual(found, [], "use a NookTheme.TextStyle (caption, detail, label, body, strong, title, heading, code)")
    }

    /// State keeps its meaning: an error is `coral`, a warning `amber`, done `mint`, and muted text `textSecondary`, never
    /// the system red, orange, green, or secondary, which are a different red, orange, and gray.
    func testStateColorsComeFromTheTheme() {
        let system = #"\b(foregroundStyle|foregroundColor|fill|tint|stroke)\(\s*\.(red|orange|yellow|green|secondary|tertiary)\b|(^|[^A-Za-z0-9_.])Color\.(red|orange|yellow|green|secondary|tertiary)\b|return \.(red|orange|yellow|green|secondary|tertiary)\b"#
        let found = offenders(system) { self.isCharacter($0) || $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.coral / amber / mint / textSecondary / textTertiary")
    }

    /// Motion feels the same everywhere: a hover, a section that opens, or a scroll to a line uses its `NookTheme` animation
    /// instead of a duration picked on the spot.
    func testShortAnimationsComeFromTheTheme() {
        let inline = #"withAnimation\(\.(easeOut|easeInOut|easeIn)\(duration: 0\.[12][0-9]*\)\)|\.animation\(\.(easeOut|easeInOut|easeIn)\(duration: 0\.[12][0-9]*\), value:"#
        let found = offenders(inline) { self.isCharacter($0) || $0 == "NotchUI/Theme/NookTheme.swift" }
        XCTAssertEqual(found, [], "use NookTheme.hover / reveal / scroll / swap")
    }

    /// A search looks and behaves the same everywhere (clear button, Escape, height): it is a `NookSearchField`, never a
    /// magnifying glass and a text field put together on the spot. The timeline's find bar, with its own next and
    /// previous, is the one exception.
    func testSearchFieldsAreTheSharedComponent() {
        let found = offenders(#"Image\((systemName|icon): "magnifyingglass"\)"#) {
            $0 == "NotchUI/Components/PanelBlocks.swift" || $0 == "NotchUI/Pills/TimelineFind.swift"
        }
        XCTAssertEqual(found, [], "use NookSearchField (NotchUI/Components/PanelBlocks.swift)")
    }

    /// Every icon is drawn through `Image(icon:)` or `NookIcon.nsImage`, so `NookIcon` turns it into Nook's Lucide icon
    /// and the app keeps one icon style; a raw SF Symbol would bypass that table.
    func testIconsGoThroughNookIcon() {
        let found = offenders(#"(^|[^A-Za-z])Image\(systemName:|NSImage\(systemSymbolName:"#) {
            $0 == "NotchUI/Theme/NookIcon.swift"
        }
        XCTAssertEqual(found, [], "use Image(icon:) or NookIcon.nsImage (NotchUI/Theme/NookIcon.swift)")
    }

    /// A line between rows or regions is a `NookDivider`, so every divider has the same weight and color.
    func testDividersAreTheSharedComponent() {
        let found = offenders(#"Rectangle\(\)\.fill\(NookTheme\.(line|line2|hairline|separator)[^)]*\)\.frame\(height: 1\)"#) {
            $0 == "NotchUI/Components/PanelBlocks.swift"
        }
        XCTAssertEqual(found, [], "use NookDivider (NotchUI/Components/PanelBlocks.swift)")
    }

    /// Text stays readable on every surface, in every theme and appearance: each text color of a palette
    /// (`NookPalette`, which `NookTheme` draws from) keeps WCAG AA contrast (4.5:1) on the canvas, the raised surfaces
    /// and a selected row, and a selected row stands clearly further from the rest than a hovered one.
    func testTextColorsKeepReadableContrast() throws {
        for theme in NookColorTheme.builtIn {
            for palette in [theme.dark, theme.light].compactMap({ $0 }) {
                let label = "\(theme.id) \(palette.isDark ? "dark" : "light")"
                for text in palette.textTokens {
                    for surface in palette.readingSurfaces {
                        XCTAssertGreaterThanOrEqual(NookColor.contrast(text.hex, surface.hex), 4.5,
                                                    "\(label): \(text.name) on \(surface.name) is below WCAG AA")
                    }
                }
                let hover = NookColor.contrast(palette.rowHover, palette.rowRest) - 1
                let selected = NookColor.contrast(palette.rowSelected, palette.rowRest) - 1
                XCTAssertGreaterThan(selected, hover * 1.5, "\(label): a selected row must stand clearly above a hovered one")
            }
        }
    }

    /// A pull request's state, checks and reviews look the same everywhere: their icon and color come from
    /// `PullRequestIcon`, and the drawn marks only through `PullRequestStateIcon` or `NookSymbol`.
    func testPullRequestIconsAreTheSharedComponent() {
        let found = offenders(#""arrow\.triangle\.(pull|merge)"|PullRequestStateGlyph\("#) {
            ["NotchUI/Components/PullRequestIcons.swift", "NotchUI/Components/NookSymbol.swift", "NotchUI/Pills/AgentsExtras.swift"].contains($0)
        }
        XCTAssertEqual(found, [], "use PullRequestIcon / PullRequestStateIcon (NotchUI/Components/PullRequestIcons.swift)")
    }

    /// Every token the scale promises exists, so the names in the docs and in the lint script stay true.
    func testThemeDefinesTheScales() {
        guard let theme = Self.sources.first(where: { $0.path == "NotchUI/Theme/NookTheme.swift" })?.text else {
            return XCTFail("NookTheme.swift not found")
        }
        for name in ["enum Radius", "enum Spacing", "enum TextStyle", "static let canvas", "static let well", "static let surface",
                     "static let hairline", "static let fieldStroke", "static func rounded(", "static let xxxl", "static var detail", "static var heading", "static var display", "static let reveal", "static let scroll"] {
            XCTAssertTrue(theme.contains(name), "NookTheme lost \(name)")
        }
    }

    /// `SelectableProse` is an `NSViewRepresentable` with `sizeThatFits`, which SwiftUI otherwise gives a 0 baseline:
    /// `ProseSegment` must pass `SelectableProse.firstBaseline` to `.alignmentGuide(.firstTextBaseline)` so controls
    /// beside a `MarkdownView` (such as task boxes in `PullRequestDescription`) line up with the first line of text.
    func testProseExposesFirstTextBaseline() throws {
        let markdown = try XCTUnwrap(Self.sources.first { $0.path == "NotchUI/Chat/MarkdownView.swift" }?.text)
        let prose = try XCTUnwrap(Self.sources.first { $0.path == "NotchUI/Chat/SelectableProse.swift" }?.text)
        XCTAssertTrue(markdown.contains(".alignmentGuide(.firstTextBaseline) { _ in SelectableProse.firstBaseline(blocks, size: size) }"))
        XCTAssertTrue(prose.contains("static func firstBaseline(_ blocks: [MarkdownBlock], size: CGFloat) -> CGFloat"))
    }
}
