import XCTest

/// Themes (resolution, VS Code import, contrast), math detection and escaping, the composer's Markdown styling and list
/// nesting, and notes on quotes.
final class LookThemesTests: XCTestCase {
    // MARK: Theme resolution

    func testModeResolvesAgainstTheSystem() {
        XCTAssertTrue(NookAppearanceMode.system.isDark(systemIsDark: true))
        XCTAssertFalse(NookAppearanceMode.system.isDark(systemIsDark: false))
        XCTAssertFalse(NookAppearanceMode.light.isDark(systemIsDark: true))
        XCTAssertTrue(NookAppearanceMode.dark.isDark(systemIsDark: false))
    }

    func testChoicePicksTheThemeForTheAppearanceInEffect() {
        let themes = NookColorTheme.builtIn
        let choice = NookThemeChoice(mode: .system, darkTheme: "midnight", lightTheme: "paper")
        XCTAssertEqual(choice.palette(systemIsDark: true, themes: themes), NookColorTheme.midnight.dark)
        XCTAssertEqual(choice.palette(systemIsDark: false, themes: themes), NookColorTheme.paper.light)
        let light = NookThemeChoice(mode: .light, darkTheme: "midnight", lightTheme: "nook")
        XCTAssertEqual(light.palette(systemIsDark: true, themes: themes), .nookLight)
    }

    func testDefaultIsNooksOwnDarkLook() {
        let choice = NookThemeChoice()
        XCTAssertEqual(choice.mode, .dark)
        XCTAssertEqual(choice.palette(systemIsDark: false, themes: NookColorTheme.builtIn), .nookDark)
        XCTAssertEqual(NookPalette.nookDark.canvas, 0x000000)
        XCTAssertEqual(NookPalette.nookDark.paper, 0xF5F5F5)
    }

    func testMissingThemeOrAppearanceFallsBackToNook() {
        var darkOnly = NookColorTheme(id: "x", name: "X", dark: .nookDark, light: nil)
        darkOnly.custom = true
        let choice = NookThemeChoice(mode: .light, darkTheme: "gone", lightTheme: "x")
        XCTAssertEqual(choice.palette(systemIsDark: false, themes: [darkOnly]), .nookLight)
        XCTAssertEqual(choice.palette(dark: true, themes: [darkOnly]), .nookDark)
    }

    // MARK: Contrast

    func testEveryBuiltInPaletteKeepsTextReadable() {
        for theme in NookColorTheme.builtIn {
            for palette in [theme.dark, theme.light].compactMap({ $0 }) {
                let weakest = palette.weakestText
                XCTAssertGreaterThanOrEqual(weakest.ratio, NookColor.minimumTextContrast,
                                            "\(theme.id) \(palette.isDark ? "dark" : "light"): \(weakest.text) on \(weakest.surface)")
            }
        }
    }

    func testWarmAndMonoAreBuiltInAndKeepNookAsTheDefault() {
        XCTAssertEqual(NookColorTheme.builtIn.map(\.id), ["nook", "warm", "mono", "midnight", "paper", "contrast"])
        XCTAssertEqual(NookThemeChoice().darkTheme, "nook")
        // Warm never uses pure white or black as its canvas.
        XCTAssertEqual(NookColorTheme.warm.light?.canvas, 0xFAF9F5)
        XCTAssertNotEqual(NookColorTheme.warm.dark?.canvas, 0x000000)
    }

    func testDensityScalesTextAndSpacing() {
        XCTAssertEqual(NookDensity.comfortable.textScale, 1)
        XCTAssertLessThan(NookDensity.compact.textScale, 1)
        XCTAssertGreaterThan(NookDensity.spacious.spacingScale, 1)
        XCTAssertEqual(NookDensity.allCases.count, 3)
    }

    func testStateColorsReadOnLightCanvas() {
        let light = NookPalette.nookLight
        for (name, hex) in [("mint", light.mint), ("amber", light.amber), ("coral", light.coral), ("violet", light.violet), ("blue", light.blue)] {
            XCTAssertGreaterThanOrEqual(NookColor.contrast(hex, light.canvas), 4.5, name)
        }
    }

    func testReadableLiftsAQuietGrey() {
        var palette = NookPalette.nookLight
        palette.textTertiary = 0xBBBBBB
        XCTAssertLessThan(palette.weakestText.ratio, 4.5)
        XCTAssertGreaterThanOrEqual(palette.readable().weakestText.ratio, 4.5)
    }

    func testContrastMath() {
        XCTAssertEqual(NookColor.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(NookColor.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
        XCTAssertEqual(NookColor.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
    }

    // MARK: VS Code import

    func testColorParsing() {
        XCTAssertEqual(NookColor.parse("#1e1e1e"), 0x1E1E1E)
        XCTAssertEqual(NookColor.parse("#fff"), 0xFFFFFF)
        XCTAssertEqual(NookColor.parse("#FFFFFF80", over: 0x000000), 0x808080)
        XCTAssertNil(NookColor.parse("red"))
    }

    func testVSCodeThemeMapsEditorSidebarAndAccent() throws {
        let source = """
        // A theme with comments and a trailing comma, as VS Code writes them.
        {
          "name": "Night Owl Test",
          "type": "dark",
          "colors": {
            "editor.background": "#011627",
            "editor.foreground": "#d6deeb",
            "sideBar.background": "#011627ff",
            "editorWidget.background": "#021320",
            "button.background": "#7e57c2",
            "list.activeSelectionBackground": "#234d70",
            "input.background": "#0b253a",
            "terminal.ansiRed": "#ef5350", /* errors */
            "textLink.foreground": "#82aaff",
          },
          "tokenColors": []
        }
        """
        let result = try VSCodeThemeImport.parse(source)
        XCTAssertEqual(result.name, "Night Owl Test")
        XCTAssertTrue(result.palette.isDark)
        XCTAssertEqual(result.palette.canvas, 0x011627)
        XCTAssertEqual(result.palette.paper, 0xD6DEEB)
        XCTAssertEqual(result.palette.surface, 0x011627)
        XCTAssertEqual(result.palette.graphite, 0x021320)
        XCTAssertEqual(result.palette.accent, 0x7E57C2)
        XCTAssertEqual(result.palette.rowSelected, 0x234D70)
        XCTAssertEqual(result.palette.field, 0x0B253A)
        XCTAssertEqual(result.palette.coral, 0xEF5350)
        XCTAssertEqual(result.palette.blue, 0x82AAFF)
        XCTAssertGreaterThanOrEqual(result.palette.weakestText.ratio, 4.5)
    }

    func testVSCodeLightThemeWithoutTypeReadsTheBackground() throws {
        let result = try VSCodeThemeImport.parse(##"{"colors": {"editor.background": "#ffffff", "editor.foreground": "#333333"}}"##,
                                                 fallbackName: "light-plus")
        XCTAssertFalse(result.palette.isDark)
        XCTAssertEqual(result.name, "light-plus")
        XCTAssertEqual(result.palette.mint, NookPalette.nookLight.mint)
    }

    func testVSCodeImportRefusesOtherFiles() {
        XCTAssertThrowsError(try VSCodeThemeImport.parse("not json")) { XCTAssertEqual($0 as? VSCodeThemeImport.Failure, .notJSON) }
        XCTAssertThrowsError(try VSCodeThemeImport.parse(#"{"name": "x"}"#)) { XCTAssertEqual($0 as? VSCodeThemeImport.Failure, .noColors) }
    }

    func testCommentStrippingLeavesStringsAlone() {
        XCTAssertEqual(VSCodeThemeImport.stripComments(#"{"a": "http://x//y", /* c */ "b": [1,],}"#), #"{"a": "http://x//y",  "b": [1]}"#)
    }

    func testCustomThemeKeepsItsAppearance() {
        let custom = NookCustomTheme(id: "custom-1", name: "Mine", source: ##"{"type":"light","colors":{"editor.background":"#fdf6e3"}}"##)
        let theme = custom.theme
        XCTAssertNotNil(theme?.light)
        XCTAssertNil(theme?.dark)
        XCTAssertEqual(theme?.custom, true)
    }

    // MARK: Math

    func testInlineAndDisplayMath() {
        XCTAssertEqual(MathText.split("Energy $E=mc^2$ here"), [.text("Energy "), .inline("E=mc^2"), .text(" here")])
        XCTAssertEqual(MathText.split(#"Use \(a+b\) and \[x^2\]"#), [.text("Use "), .inline("a+b"), .text(" and "), .display("x^2")])
        XCTAssertEqual(MathText.split("so $$\\sum_i x_i$$."), [.text("so "), .display("\\sum_i x_i"), .text(".")])
    }

    func testDollarAmountsStayText() {
        XCTAssertFalse(MathText.containsMath("It costs $5 and $10 today"))
        XCTAssertFalse(MathText.containsMath("between $ 5 and 6 $"))
        XCTAssertFalse(MathText.containsMath(#"a literal \$x\$ sign"#))
        XCTAssertEqual(MathText.split(#"price \$5"#), [.text("price $5")])
        XCTAssertFalse(MathText.containsMath("no math at all"))
    }

    func testMathInsideCodeIsLeftAlone() {
        XCTAssertFalse(MathText.containsMath("run `echo $HOME$` now"))
        XCTAssertTrue(MathText.containsMath("`code` then $x$"))
    }

    func testUnclosedFormulaWhileStreamingStaysText() {
        XCTAssertFalse(MathText.containsMath("the value $x^2 + "))
        XCTAssertFalse(MathText.containsMath("$$\\int_0^1"))
    }

    func testRenderingSwitchTurnsDetectionOff() {
        MathText.renderingEnabled = false
        defer { MathText.renderingEnabled = true }
        XCTAssertFalse(MathText.containsMath("$x$"))
    }

    func testHTMLEscapesTextAndTeX() {
        let html = MathText.html("a < b and $x<y$ **bold**")
        XCTAssertTrue(html.contains("a &lt; b"))
        XCTAssertTrue(html.contains(#"data-tex="x&lt;y""#))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertFalse(html.contains("<y"))
        XCTAssertEqual(MathText.escapeHTML(#"<"&'>"#), "&lt;&quot;&amp;&#39;&gt;")
        XCTAssertTrue(MathText.html("\\frac{a}{b}", display: true).hasPrefix(#"<span class="tex display""#))
    }

    #if os(macOS)  // MarkdownBlock is the Mac's (scripts/core-tests.sh leaves it out on Linux)
    func testMarkdownMathBlocks() {
        XCTAssertEqual(MarkdownBlock.parse("```math\n\\int_0^1 x\\,dx\n```"), [.math("\\int_0^1 x\\,dx")])
        XCTAssertEqual(MarkdownBlock.parse("Before\n\n$$\na^2 + b^2 = c^2\n$$\n\nAfter"),
                       [.paragraph("Before"), .math("a^2 + b^2 = c^2"), .paragraph("After")])
        XCTAssertEqual(MarkdownBlock.parse("\\[x = 1\\]"), [.math("x = 1")])
        // Never closed (still streaming): a paragraph for now.
        XCTAssertEqual(MarkdownBlock.parse("$$\nx"), [.paragraph("$$\nx")])
    }
    #endif

    // MARK: Composer styling

    private func kinds(_ text: String) -> [(ComposerMarkdownStyle.Kind, String)] {
        let ns = text as NSString
        return ComposerMarkdownStyle.spans(text).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func has(_ text: String, _ kind: ComposerMarkdownStyle.Kind, _ part: String) -> Bool {
        kinds(text).contains { $0.0 == kind && $0.1 == part }
    }

    func testInlineStyles() {
        let text = "a **bold** and *it* and `co*de*` and ~~gone~~"
        XCTAssertTrue(has(text, .bold, "**bold**"))
        XCTAssertTrue(has(text, .italic, "*it*"))
        XCTAssertTrue(has(text, .code, "`co*de*`"))
        XCTAssertTrue(has(text, .strike, "~~gone~~"))
        XCTAssertFalse(has(text, .italic, "*de*"), "emphasis inside code")
        XCTAssertTrue(has(text, .syntax, "**"))
        XCTAssertFalse(kinds("2 * 3 * 4").contains { $0.0 == .italic })
    }

    func testLineStyles() {
        let text = "# Title\n- item\n- [x] done\n1. first\n> quoted"
        XCTAssertTrue(has(text, .heading(1), "# Title"))
        XCTAssertTrue(has(text, .listMarker, "- "))
        XCTAssertTrue(has(text, .task(done: true), "[x]"))
        XCTAssertTrue(has(text, .listMarker, "1. "))
        XCTAssertTrue(has(text, .quote, "> quoted"))
        XCTAssertFalse(kinds("* item").contains { $0.0 == .italic })
    }

    func testCodeFenceHidesMarkdownInside() {
        let text = "```\n# not a heading **x**\n```\nafter **b**"
        XCTAssertTrue(kinds(text).contains { $0.0 == .codeBlock })
        XCTAssertFalse(kinds(text).contains { $0.0 == .heading(1) })
        XCTAssertFalse(has(text, .bold, "**x**"))
        XCTAssertTrue(has(text, .bold, "**b**"))
        // An open fence styles to the end while it is being written.
        XCTAssertTrue(has("```swift\nlet a", .codeBlock, "```swift\nlet a"))
    }

    func testHugeDraftStaysPlain() {
        XCTAssertTrue(ComposerMarkdownStyle.spans(String(repeating: "**a** ", count: 5_000)).isEmpty)
    }

    func testTabNestsListItems() {
        let text = "- one\n- two"
        let caret = NSRange(location: 8, length: 0)
        let nested = ComposerLists.nest(text, selection: caret, outdent: false)
        XCTAssertEqual(nested?.text, "- one\n  - two")
        XCTAssertEqual(nested?.selection, NSRange(location: 10, length: 0))
        let back = ComposerLists.nest(nested!.text, selection: nested!.selection, outdent: true)
        XCTAssertEqual(back?.text, text)
        XCTAssertEqual(back?.selection, caret)
        XCTAssertNil(ComposerLists.nest("plain text", selection: NSRange(location: 2, length: 0), outdent: false))
        XCTAssertEqual(ComposerLists.nest("- a\n- b", selection: NSRange(location: 0, length: 7), outdent: false)?.text, "  - a\n  - b")
    }

    // MARK: Quote notes

    func testQuoteNoteGoesUnderItsQuote() {
        var quotes = ComposerQuotes()
        quotes.add("first line\nsecond")
        quotes.add("other")
        quotes.setNote("  why this?  ", for: quotes.items[0].id)
        XCTAssertEqual(quotes.items[0].title, "why this?")
        XCTAssertEqual(quotes.message("Please fix"), "> first line\n> second\n\nwhy this?\n\n> other\n\nPlease fix")
        quotes.setNote("", for: quotes.items[0].id)
        XCTAssertEqual(quotes.message(""), "> first line\n> second\n\n> other")
    }

    func testQuoteSourceIsTheNewestAnswerHoldingIt() {
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [(id: a, text: "The **cache** is   warm now."), (id: b, text: "Unrelated."), (id: c, text: "Again: the cache is warm now!")]
        XCTAssertEqual(ComposerQuotes.source(of: "cache is warm", in: entries), c)
        XCTAssertEqual(ComposerQuotes.source(of: "The cache is warm", in: Array(entries.prefix(2))), a)
        XCTAssertNil(ComposerQuotes.source(of: "nowhere to be found", in: entries))
        var quotes = ComposerQuotes()
        quotes.add("cache is warm", source: c)
        XCTAssertEqual(quotes.items.first?.source, c)
    }

    // MARK: Colors set one by one

    func testColorTokensAreUniqueAndCoverEveryGroup() {
        let ids = NookColorToken.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for group in NookColorToken.Group.allCases {
            XCTAssertTrue(NookColorToken.all.contains { $0.group == group }, group.rawValue)
        }
        XCTAssertNil(NookColorToken.named("accent"), "the accent has its own control")
    }

    func testNoOverridesKeepNooksColors() {
        let choice = NookThemeChoice()
        XCTAssertEqual(choice.palette(dark: true, themes: NookColorTheme.builtIn), .nookDark)
        XCTAssertEqual(choice.palette(dark: false, themes: NookColorTheme.builtIn), .nookLight)
    }

    func testAnOverrideChangesOnlyItsColorAndAppearance() {
        var choice = NookThemeChoice()
        choice.overrides.set("composer", to: 0x202020, dark: true)
        choice.overrides.set("nope", to: 0x123456, dark: true)
        let dark = choice.palette(dark: true, themes: NookColorTheme.builtIn)
        XCTAssertEqual(dark.composer, 0x202020)
        XCTAssertEqual(dark.surface, NookPalette.nookDark.surface)
        XCTAssertEqual(choice.palette(dark: false, themes: NookColorTheme.builtIn), .nookLight)
        XCTAssertEqual(choice.themePalette(dark: true, themes: NookColorTheme.builtIn), .nookDark)
    }

    func testSettingTheThemesOwnColorRemovesTheOverride() {
        var overrides = NookColorOverrides()
        overrides.set("amber", to: 0x111111, dark: true, themeValue: NookPalette.nookDark.amber)
        XCTAssertFalse(overrides.isEmpty)
        overrides.set("amber", to: NookPalette.nookDark.amber, dark: true, themeValue: NookPalette.nookDark.amber)
        XCTAssertTrue(overrides.isEmpty)
    }

    func testOverridesRoundTrip() throws {
        var overrides = NookColorOverrides()
        overrides.set("added", to: 0x00FF00, dark: false)
        let data = try JSONEncoder().encode(overrides)
        XCTAssertEqual(try JSONDecoder().decode(NookColorOverrides.self, from: data), overrides)
    }

    func testComposerFollowsAGeneratedThemesSurface() {
        for theme in NookColorTheme.builtIn where theme.id != "nook" {
            for palette in [theme.dark, theme.light].compactMap({ $0 }) {
                XCTAssertEqual(palette.composer, palette.surface, theme.id)
            }
        }
    }

    // MARK: Diff colors

    func testDiffColorsComeFromTheThemesPalette() {
        for theme in NookColorTheme.builtIn {
            for palette in [theme.dark, theme.light].compactMap({ $0 }) {
                XCTAssertEqual(NookDiffColors.redGreen.added(palette), palette.added, theme.id)
                XCTAssertEqual(NookDiffColors.redGreen.removed(palette), palette.removed, theme.id)
                XCTAssertEqual(NookDiffColors.blueOrange.added(palette), palette.blue, theme.id)
                XCTAssertNotEqual(NookDiffColors.blueOrange.added(palette), NookDiffColors.blueOrange.removed(palette), theme.id)
                XCTAssertNotEqual(NookDiffColors.blueOrange.modified(palette), palette.blue,
                                  "\(theme.id): a changed file is not drawn as an added one")
            }
        }
    }

    func testBlueOrangeRemovedIsAnOrange() throws {
        let palette = try XCTUnwrap(NookColorTheme.nook.dark)
        let removed = NookColor.components(NookDiffColors.blueOrange.removed(palette))
        XCTAssertGreaterThan(removed.r, removed.g)
        XCTAssertGreaterThan(removed.g, removed.b)
        XCTAssertGreaterThan(removed.g, 0.4, "orange, not the red that red-green color blindness mixes up with green")
    }
}
