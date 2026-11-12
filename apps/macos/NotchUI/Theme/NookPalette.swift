import Foundation

// The colors behind `NookTheme`, as plain numbers: which palette a theme has for dark and for light, which one shows
// (System / Light / Dark), how a VS Code color theme becomes one, and whether its text stays readable (WCAG). No SwiftUI
// here, so NookTests and the portable core tests check it; `NookTheme` turns the chosen palette into colors that follow
// the window's appearance. Shared with the iPhone companion (apps/ios/project.yml), which stays dark.

/// Every named color of Nook's design, as 0xRRGGBB. The names are `NookTheme`'s: change a palette and every view that
/// takes its colors from `NookTheme` follows. State colors (mint, amber, coral, violet) keep their meaning in every
/// palette; a light palette only darkens them so they read on a light surface.
///
/// Color is rare on purpose: everything is black, white and grey, and a hue appears only where it means
/// something (a change in a diff, a session that is working, waits on you, is done or failed). In dark the state colors
/// are the soft 300 shades at 90 % (status tones), so a list of them stays calm; diff counts keep the brighter
/// 400 shades in `added` and `removed`, because a change is what the eye should find first.
struct NookPalette: Equatable, Sendable {
    var isDark: Bool

    // Surfaces, from the window's canvas up.
    var canvas: UInt32
    var well: UInt32
    var surface: UInt32
    var field: UInt32
    var graphite: UInt32
    var smoke: UInt32
    var rowRest: UInt32
    var rowHover: UInt32
    var rowSelected: UInt32
    var bubble: UInt32
    var chatMine: UInt32
    var chatTheirs: UInt32

    // Lines.
    var line: UInt32
    var line2: UInt32
    var hairline: UInt32
    var border: UInt32
    var separator: UInt32
    var fieldStroke: UInt32

    // Text, strongest first.
    var paper: UInt32
    var textStrong: UInt32
    var textSecondary: UInt32
    var textMuted: UInt32
    var textTertiary: UInt32
    var chatStamp: UInt32

    // Links and state.
    var blue: UInt32
    var mint: UInt32
    var mintSoft: UInt32
    var amber: UInt32
    var coral: UInt32
    var coralSoft: UInt32
    var violet: UInt32
    var music: UInt32
    /// Added and removed lines in a diff and in change counts (diff-addition and diff-deletion foregrounds).
    var added: UInt32
    var removed: UInt32

    /// Nook's color when the user kept the default accent: soft white on dark, near black on light.
    var accent: UInt32

    // Surfaces with a role of their own, so each can be set apart from the shared ones (Settings › Appearance › Colors).
    /// The composer under a conversation.
    var composer: UInt32
    /// Menus, popovers, hover cards and tooltips. They draw their text for dark, so this stays a dark color.
    var menu: UInt32

    // Code in a diff and in the file viewer, muted under the diff's own tints. Only for code, never for state.
    var syntaxKeyword: UInt32
    var syntaxString: UInt32
    var syntaxComment: UInt32
    var syntaxNumber: UInt32
    var syntaxType: UInt32
    var syntaxProperty: UInt32
    var syntaxTag: UInt32
    var syntaxAttribute: UInt32

    /// Nook's own dark look: a true black canvas, raised surfaces (cards, menus, the composer) about 3 %
    /// white over it, and separation by 8 % white lines and hover fills rather than grey panels. Text is neutral-100
    /// with neutral-400 for what is quieter. State colors are status tones (emerald, sky and violet 300 at
    /// 90 % on black; red 400 for errors), with a warm honey for what waits on you instead of amber-300's mustard yellow. Chat bubbles keep the colors of the chat apps they come from. Nook's accent
    /// (the main action) is soft white.
    static let nookDark = NookPalette(
        isDark: true,
        canvas: 0x000000, well: 0x0A0A0A, surface: 0x111111, field: 0x0D0D0D, graphite: 0x191A1D, smoke: 0x242424,
        rowRest: 0x0A0A0A, rowHover: 0x141415, rowSelected: 0x1C1C1E, bubble: 0x1E1E1E, chatMine: 0x17493A, chatTheirs: 0x1E1E1E,
        line: 0x1A1A1A, line2: 0x262626, hairline: 0x171717, border: 0x1A1A1A, separator: 0x1F1F1F, fieldStroke: 0x262626,
        paper: 0xF5F5F5, textStrong: 0xE5E5E5, textSecondary: 0xA1A1A1, textMuted: 0x8F8F8F, textTertiary: 0x8F8F8F,
        chatStamp: 0xA3B0AB,
        blue: 0x5DAACC, mint: 0x55D2A3, mintSoft: 0x5EE9B5, amber: 0xF0B65A, coral: 0xFF6467, coralSoft: 0xFCA5A5,
        violet: 0xB0A2E6, music: 0xE6A660, added: 0x00D492, removed: 0xFF6467,
        accent: 0xF4F3F7,
        composer: 0x111111, menu: 0x171717,
        syntaxKeyword: 0xC3A6EE, syntaxString: 0xA8CF96, syntaxComment: 0x6F7378, syntaxNumber: 0xE6B98A,
        syntaxType: 0x8EC7E3, syntaxProperty: 0xA3BCEB, syntaxTag: 0xE79BB8, syntaxAttribute: 0xD9C27E)

    /// Nook in light: an off-white canvas (zinc-25), white cards, zinc lines and zinc-900 text, with the
    /// state colors a few shades deeper so they read on white, and a near-black accent. Every text color reads at 4.5:1 or more up to `smoke`.
    static let nookLight = NookPalette(
        isDark: false,
        canvas: 0xFCFCFC, well: 0xFAFAFA, surface: 0xFFFFFF, field: 0xFFFFFF, graphite: 0xF4F4F5, smoke: 0xE4E4E7,
        rowRest: 0xFAFAFA, rowHover: 0xF4F4F5, rowSelected: 0xEBEBED, bubble: 0xEBEBED, chatMine: 0xD2EFE2, chatTheirs: 0xF0F0F2,
        line: 0xE4E4E7, line2: 0xD4D4D8, hairline: 0xEDEDEF, border: 0xE4E4E7, separator: 0xE4E4E7, fieldStroke: 0xD4D4D8,
        paper: 0x18181B, textStrong: 0x27272A, textSecondary: 0x52525C, textMuted: 0x5C5C66, textTertiary: 0x62626C,
        chatStamp: 0x4E5A55,
        blue: 0x1447E6, mint: 0x006E4D, mintSoft: 0x007A55, amber: 0x973C00, coral: 0xC10007, coralSoft: 0xB91C1C,
        violet: 0x7008E7, music: 0xA84A18, added: 0x007A55, removed: 0xC10007,
        accent: 0x1E1E22,
        composer: 0xFFFFFF, menu: 0x171717,
        syntaxKeyword: 0x7A45B5, syntaxString: 0x3D7A2E, syntaxComment: 0x8A8F96, syntaxNumber: 0x9A5A12,
        syntaxType: 0x1D6E93, syntaxProperty: 0x3B5DA6, syntaxTag: 0xA33A6C, syntaxAttribute: 0x86690F)

    /// The text colors and what they must stay readable on, for the contrast check.
    var textTokens: [(name: String, hex: UInt32)] {
        [("paper", paper), ("textStrong", textStrong), ("textSecondary", textSecondary), ("textMuted", textMuted),
         ("textTertiary", textTertiary)]
    }

    var readingSurfaces: [(name: String, hex: UInt32)] {
        [("canvas", canvas), ("well", well), ("surface", surface), ("field", field), ("graphite", graphite), ("smoke", smoke),
         ("rowSelected", rowSelected)]
    }

    /// A palette made from a few colors: the canvas, the text on it and an accent, with the surfaces stepped from the
    /// canvas toward the text, as Nook's own ramp is. State colors are Nook's for that appearance. Used by the built-in
    /// themes and as the base a VS Code theme is mapped onto.
    static func generated(dark: Bool, canvas: UInt32, text: UInt32, accent: UInt32, link: UInt32? = nil) -> NookPalette {
        let base = dark ? nookDark : nookLight
        func step(_ amount: Double) -> UInt32 { NookColor.mix(canvas, text, amount) }
        var palette = base
        palette.canvas = canvas
        palette.well = dark ? step(0.025) : NookColor.mix(canvas, 0x000000, 0.035)
        palette.surface = dark ? step(0.06) : NookColor.mix(canvas, 0xFFFFFF, 0.6)
        palette.composer = palette.surface
        palette.field = dark ? step(0.05) : NookColor.mix(canvas, 0x000000, 0.02)
        palette.graphite = step(dark ? 0.09 : 0.05)
        palette.smoke = step(dark ? 0.13 : 0.085)
        palette.rowRest = step(dark ? 0.03 : 0.025)
        palette.rowHover = step(dark ? 0.08 : 0.05)
        palette.rowSelected = step(dark ? 0.13 : 0.09)
        palette.bubble = step(dark ? 0.1 : 0.055)
        palette.chatTheirs = step(dark ? 0.12 : 0.06)
        palette.line = step(dark ? 0.1 : 0.08)
        palette.line2 = step(dark ? 0.16 : 0.14)
        palette.hairline = palette.line
        palette.border = step(dark ? 0.11 : 0.1)
        palette.separator = step(dark ? 0.14 : 0.12)
        palette.fieldStroke = step(dark ? 0.15 : 0.16)
        palette.paper = text
        palette.textStrong = step(0.88)
        palette.textSecondary = step(0.68)
        palette.textMuted = step(0.64)
        palette.textTertiary = step(0.62)
        palette.chatStamp = step(0.66)
        palette.accent = accent
        if let link { palette.blue = link }
        return palette.readable()
    }

    /// The same palette with every text color moved toward `paper` until it reads at WCAG AA (4.5:1) on every surface up
    /// to `smoke`; colors that already do stay as they are. An imported theme often has a quiet grey that does not.
    func readable(minimum: Double = NookColor.minimumTextContrast) -> NookPalette {
        var palette = self
        func fix(_ hex: UInt32) -> UInt32 {
            var value = hex
            var amount = 0.0
            while amount < 1, palette.readingSurfaces.contains(where: { NookColor.contrast(value, $0.hex) < minimum }) {
                amount += 0.05
                value = NookColor.mix(hex, palette.paper, amount)
            }
            return value
        }
        palette.textStrong = fix(textStrong)
        palette.textSecondary = fix(textSecondary)
        palette.textMuted = fix(textMuted)
        palette.textTertiary = fix(textTertiary)
        return palette
    }

    /// The lowest contrast of any text color on any reading surface, with the pair that has it.
    var weakestText: (text: String, surface: String, ratio: Double) {
        var worst = (text: "", surface: "", ratio: Double.infinity)
        for text in textTokens {
            for surface in readingSurfaces {
                let ratio = NookColor.contrast(text.hex, surface.hex)
                if ratio < worst.ratio { worst = (text.name, surface.name, ratio) }
            }
        }
        return worst
    }
}

/// Color arithmetic on 0xRRGGBB values.
enum NookColor {
    /// WCAG AA for normal text.
    static let minimumTextContrast = 4.5

    static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    static func hex(r: Double, g: Double, b: Double) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// `from` moved `amount` (0…1) of the way to `to`.
    static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
        let a = components(from), b = components(to)
        return hex(r: a.r + (b.r - a.r) * amount, g: a.g + (b.g - a.g) * amount, b: a.b + (b.b - a.b) * amount)
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = components(hex)
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// WCAG contrast ratio of two colors, 1 to 21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA" (VS Code writes all three); a color with alpha is laid over `background`.
    static func parse(_ text: String?, over background: UInt32? = nil) -> UInt32? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 || text.count == 4 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        guard text.count == 8 else { return UInt32(value) }
        let rgb = UInt32(value >> 8), alpha = Double(value & 0xFF) / 255
        guard alpha < 1 else { return rgb }
        return mix(background ?? rgb, rgb, alpha)
    }

    static func string(_ hex: UInt32) -> String { String(format: "#%06X", hex) }
}

/// Which appearance Nook's windows take.
enum NookAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    /// Whether the dark palette shows, given whether macOS is dark right now.
    func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }
}

/// How much room Nook gives its text and rows (Settings › Appearance). Comfortable is the design as drawn; compact fits
/// more on screen, spacious reads easier. A scale on the type and on a row's own padding, never on a hit target.
enum NookDensity: String, CaseIterable, Identifiable, Sendable {
    case compact, comfortable, spacious
    var id: String { rawValue }

    /// Multiplies every size of the type scale.
    var textScale: Double {
        switch self {
        case .compact: return 0.93
        case .comfortable: return 1
        case .spacious: return 1.07
        }
    }

    /// Multiplies the padding of rows and cards (`NookTheme.Spacing.scaled`).
    var spacingScale: Double {
        switch self {
        case .compact: return 0.75
        case .comfortable: return 1
        case .spacious: return 1.25
        }
    }
}

/// The colors of added and removed lines in every diff and change count (Settings › Appearance): green and red as most
/// tools draw them, or blue and orange, which people with red-green color blindness (about one man in twelve) tell
/// apart. The two come from the theme's own palette, so they follow a theme and its light or dark look.
enum NookDiffColors: String, CaseIterable, Identifiable, Sendable {
    case redGreen, blueOrange
    var id: String { rawValue }

    func added(_ palette: NookPalette) -> UInt32 {
        self == .redGreen ? palette.added : palette.blue
    }

    func removed(_ palette: NookPalette) -> UInt32 {
        // The theme's amber pulled a little toward its coral: an orange, away from the blue in hue.
        self == .redGreen ? palette.removed : NookColor.mix(palette.amber, palette.coral, 0.45)
    }

    /// A changed file (neither added nor removed): blue with green and red, a quiet grey where blue means added.
    func modified(_ palette: NookPalette) -> UInt32 {
        self == .redGreen ? palette.blue : palette.textSecondary
    }
}

/// A theme: a name and a palette for dark, for light, or both. Built-in ones have both; an imported VS Code theme has the
/// one its `type` says.
struct NookColorTheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var dark: NookPalette?
    var light: NookPalette?
    /// Imported by the user (can be removed); built-in themes cannot.
    var custom = false

    /// Nook's own look (a black canvas and lines, with a white accent), and the default for both appearances.
    static let nook = NookColorTheme(id: "nook", name: "Nook", dark: .nookDark, light: .nookLight)
    /// Cool and deep: a blue-black night and a pale blue-grey day.
    static let midnight = NookColorTheme(
        id: "midnight", name: "Midnight",
        dark: .generated(dark: true, canvas: 0x0B0E14, text: 0xE6EAF2, accent: 0x8AA8F8, link: 0x8AB4F8),
        light: .generated(dark: false, canvas: 0xF4F6FA, text: 0x111827, accent: 0x2F5BD3, link: 0x2457C5))
    /// Warm, like paper under a lamp.
    static let paper = NookColorTheme(
        id: "paper", name: "Paper",
        dark: .generated(dark: true, canvas: 0x15130F, text: 0xEFE8DC, accent: 0xE3B56F, link: 0xA8C0E8),
        light: .generated(dark: false, canvas: 0xF7F3EA, text: 0x1F1A12, accent: 0x7A4E12, link: 0x2E5A9E))
    /// The most contrast: pure black and white, and every grey a step brighter.
    static let contrast = NookColorTheme(
        id: "contrast", name: "High contrast",
        dark: .generated(dark: true, canvas: 0x000000, text: 0xFFFFFF, accent: 0xFFFFFF, link: 0x9CC2FF).raised(by: 0.12),
        light: .generated(dark: false, canvas: 0xFFFFFF, text: 0x000000, accent: 0x000000, link: 0x1747A6).raised(by: 0.12))

    /// Warm neutrals after the Claude app: an ivory day and a soft charcoal night (never pure white or black), one clay
    /// accent, and quiet lines. Surfaces and text are stepped from the canvas as every generated theme is, so text stays AA.
    static let warm = NookColorTheme(
        id: "warm", name: "Warm",
        dark: .generated(dark: true, canvas: 0x1F1E1B, text: 0xF1EEE6, accent: 0xE08A66, link: 0x9DBCEB),
        light: .generated(dark: false, canvas: 0xFAF9F5, text: 0x2B2924, accent: 0xB5542F, link: 0x2F5F9E))
    /// Neutral grey only, with the accent in the text color: no hue anywhere but state.
    static let mono = NookColorTheme(
        id: "mono", name: "Mono",
        dark: .generated(dark: true, canvas: 0x101010, text: 0xEDEDED, accent: 0xEDEDED),
        light: .generated(dark: false, canvas: 0xF6F6F6, text: 0x141414, accent: 0x141414))

    static let builtIn: [NookColorTheme] = [.nook, .warm, .mono, .midnight, .paper, .contrast]

    func palette(dark: Bool) -> NookPalette? { dark ? self.dark : light }
}

extension NookPalette {
    /// Every grey text moved `amount` closer to `paper`: for the high-contrast theme.
    func raised(by amount: Double) -> NookPalette {
        var palette = self
        palette.textStrong = NookColor.mix(textStrong, paper, amount * 2)
        palette.textSecondary = NookColor.mix(textSecondary, paper, amount * 2)
        palette.textMuted = NookColor.mix(textMuted, paper, amount * 2)
        palette.textTertiary = NookColor.mix(textTertiary, paper, amount * 2)
        palette.border = NookColor.mix(border, paper, amount)
        palette.separator = NookColor.mix(separator, paper, amount)
        palette.fieldStroke = NookColor.mix(fieldStroke, paper, amount)
        return palette
    }
}

/// What the user chose: the appearance, and which theme shows in dark and which in light.
struct NookThemeChoice: Equatable, Sendable {
    var mode: NookAppearanceMode = .dark
    var darkTheme: String = NookColorTheme.nook.id
    var lightTheme: String = NookColorTheme.nook.id
    /// The colors set one by one in Settings › Appearance › Colors, over the chosen themes.
    var overrides = NookColorOverrides()

    /// The palette that shows: the chosen theme's for the appearance in effect; Nook's own when that theme is gone or has
    /// no palette for it (a dark-only VS Code theme picked for light).
    func palette(systemIsDark: Bool, themes: [NookColorTheme]) -> NookPalette {
        let dark = mode.isDark(systemIsDark: systemIsDark)
        return palette(dark: dark, themes: themes)
    }

    func palette(dark: Bool, themes: [NookColorTheme]) -> NookPalette {
        themePalette(dark: dark, themes: themes).applying(overrides.values(dark: dark))
    }

    /// The chosen theme's own palette, without the user's colors: what "Reset" goes back to.
    func themePalette(dark: Bool, themes: [NookColorTheme]) -> NookPalette {
        let id = dark ? darkTheme : lightTheme
        return themes.first { $0.id == id }?.palette(dark: dark) ?? (dark ? .nookDark : .nookLight)
    }
}

/// A VS Code color theme (the JSON a theme extension ships, comments and trailing commas allowed) as a Nook theme: the
/// editor's background is the canvas, the side bar the lifted surface, its inputs the fields, its lists the rows, its
/// foregrounds the text, its button or focus color the accent, and the terminal's ANSI colors the state colors.
enum VSCodeThemeImport {
    enum Failure: Error, Equatable { case notJSON, noColors }

    struct Result: Equatable {
        var name: String
        var palette: NookPalette
    }

    static func parse(_ source: String, fallbackName: String = "Imported") throws -> Result {
        guard let data = stripComments(source).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.notJSON }
        guard let colors = object["colors"] as? [String: Any], !colors.isEmpty else { throw Failure.noColors }
        let type = (object["type"] as? String)?.lowercased() ?? ""
        func raw(_ keys: String...) -> String? { keys.lazy.compactMap { colors[$0] as? String }.first }
        // The editor first: everything else is laid over it.
        let editorBackground = NookColor.parse(raw("editor.background"))
        let dark: Bool = {
            if type.contains("light") { return false }
            if type.contains("dark") || type == "hc" { return true }
            return NookColor.luminance(editorBackground ?? 0) < 0.4
        }()
        let base = dark ? NookPalette.nookDark : NookPalette.nookLight
        let canvas = editorBackground ?? base.canvas
        func color(_ keys: String...) -> UInt32? {
            keys.lazy.compactMap { NookColor.parse(colors[$0] as? String, over: canvas) }.first
        }
        let text = color("editor.foreground", "foreground") ?? base.paper
        let accent = color("button.background", "focusBorder", "activityBarBadge.background", "textLink.foreground") ?? base.accent
        var palette = NookPalette.generated(dark: dark, canvas: canvas, text: text, accent: accent,
                                            link: color("textLink.foreground"))
        if let value = color("sideBar.background", "panel.background") { palette.surface = value; palette.composer = value }
        if let value = color("editorWidget.background", "dropdown.background") { palette.graphite = value }
        if let value = color("input.background") { palette.field = value }
        if let value = color("input.border") { palette.fieldStroke = value }
        if let value = color("sideBar.border", "panel.border", "editorGroup.border") { palette.border = value }
        if let value = color("list.hoverBackground") { palette.rowHover = value }
        if let value = color("list.activeSelectionBackground", "list.inactiveSelectionBackground") {
            palette.rowSelected = value
            palette.smoke = value
        }
        if let value = color("sideBar.foreground") { palette.textStrong = value }
        if let value = color("descriptionForeground") { palette.textSecondary = value }
        if let value = color("terminal.ansiGreen", "gitDecoration.addedResourceForeground") {
            palette.mint = value; palette.mintSoft = value; palette.added = value
        }
        if let value = color("terminal.ansiYellow", "editorWarning.foreground") { palette.amber = value }
        if let value = color("terminal.ansiRed", "errorForeground", "editorError.foreground") {
            palette.coral = value; palette.coralSoft = value; palette.removed = value
        }
        if let value = color("terminal.ansiMagenta") { palette.violet = value }
        let name = (object["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fallbackName
        return Result(name: name, palette: palette.readable())
    }

    /// JSON with comments (`//`, `/* */`) and trailing commas, as VS Code allows, made strict. Strings stay untouched.
    static func stripComments(_ source: String) -> String {
        var out = ""
        var chars = Array(source)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                // A comma before a closing bracket (after whitespace) is dropped.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        chars.removeAll()
        return out
    }
}

/// A theme the user imported, kept as the file it came from, so a newer Nook maps it again with what it knows then.
struct NookCustomTheme: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var source: String

    var theme: NookColorTheme? {
        guard let result = try? VSCodeThemeImport.parse(source, fallbackName: name) else { return nil }
        return NookColorTheme(id: id, name: name, dark: result.palette.isDark ? result.palette : nil,
                              light: result.palette.isDark ? nil : result.palette, custom: true)
    }
}

// MARK: Colors you set yourself

/// One named color of the palette that can be set in Settings › Appearance › Colors: its id (the stored key and the
/// `colors.token.<id>` text), the group it is listed under, and where it lives in `NookPalette`. Every view takes its
/// colors from these (through `NookTheme`), so a color set here changes everywhere it is used. The accent has its own
/// control above the themes and is left out.
struct NookColorToken: Identifiable, @unchecked Sendable {
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case surfaces, lines, text, state, changes, chat, code
        var id: String { rawValue }
    }

    let id: String
    let group: Group
    let keyPath: WritableKeyPath<NookPalette, UInt32>

    static let all: [NookColorToken] = [
        .init(id: "canvas", group: .surfaces, keyPath: \.canvas),
        .init(id: "well", group: .surfaces, keyPath: \.well),
        .init(id: "surface", group: .surfaces, keyPath: \.surface),
        .init(id: "composer", group: .surfaces, keyPath: \.composer),
        .init(id: "menu", group: .surfaces, keyPath: \.menu),
        .init(id: "field", group: .surfaces, keyPath: \.field),
        .init(id: "graphite", group: .surfaces, keyPath: \.graphite),
        .init(id: "smoke", group: .surfaces, keyPath: \.smoke),
        .init(id: "rowRest", group: .surfaces, keyPath: \.rowRest),
        .init(id: "rowHover", group: .surfaces, keyPath: \.rowHover),
        .init(id: "rowSelected", group: .surfaces, keyPath: \.rowSelected),
        .init(id: "bubble", group: .surfaces, keyPath: \.bubble),
        .init(id: "line", group: .lines, keyPath: \.line),
        .init(id: "line2", group: .lines, keyPath: \.line2),
        .init(id: "hairline", group: .lines, keyPath: \.hairline),
        .init(id: "border", group: .lines, keyPath: \.border),
        .init(id: "separator", group: .lines, keyPath: \.separator),
        .init(id: "fieldStroke", group: .lines, keyPath: \.fieldStroke),
        .init(id: "paper", group: .text, keyPath: \.paper),
        .init(id: "textStrong", group: .text, keyPath: \.textStrong),
        .init(id: "textSecondary", group: .text, keyPath: \.textSecondary),
        .init(id: "textMuted", group: .text, keyPath: \.textMuted),
        .init(id: "textTertiary", group: .text, keyPath: \.textTertiary),
        .init(id: "blue", group: .state, keyPath: \.blue),
        .init(id: "mint", group: .state, keyPath: \.mint),
        .init(id: "mintSoft", group: .state, keyPath: \.mintSoft),
        .init(id: "amber", group: .state, keyPath: \.amber),
        .init(id: "coral", group: .state, keyPath: \.coral),
        .init(id: "coralSoft", group: .state, keyPath: \.coralSoft),
        .init(id: "violet", group: .state, keyPath: \.violet),
        .init(id: "music", group: .state, keyPath: \.music),
        .init(id: "added", group: .changes, keyPath: \.added),
        .init(id: "removed", group: .changes, keyPath: \.removed),
        .init(id: "chatMine", group: .chat, keyPath: \.chatMine),
        .init(id: "chatTheirs", group: .chat, keyPath: \.chatTheirs),
        .init(id: "chatStamp", group: .chat, keyPath: \.chatStamp),
        .init(id: "syntaxKeyword", group: .code, keyPath: \.syntaxKeyword),
        .init(id: "syntaxString", group: .code, keyPath: \.syntaxString),
        .init(id: "syntaxComment", group: .code, keyPath: \.syntaxComment),
        .init(id: "syntaxNumber", group: .code, keyPath: \.syntaxNumber),
        .init(id: "syntaxType", group: .code, keyPath: \.syntaxType),
        .init(id: "syntaxProperty", group: .code, keyPath: \.syntaxProperty),
        .init(id: "syntaxTag", group: .code, keyPath: \.syntaxTag),
        .init(id: "syntaxAttribute", group: .code, keyPath: \.syntaxAttribute),
    ]

    static func named(_ id: String) -> NookColorToken? { all.first { $0.id == id } }
}

/// The colors the user set, per appearance, as token id to 0xRRGGBB. They lie over whichever theme is chosen, so a
/// theme stays the default and "Reset" brings its color back. Empty by default: Nook's colors as designed.
struct NookColorOverrides: Codable, Equatable, Sendable {
    var dark: [String: UInt32] = [:]
    var light: [String: UInt32] = [:]

    var isEmpty: Bool { dark.isEmpty && light.isEmpty }

    func values(dark isDark: Bool) -> [String: UInt32] { isDark ? dark : light }

    /// Sets one color for one appearance; nil (or the theme's own value) removes the override.
    mutating func set(_ id: String, to hex: UInt32?, dark isDark: Bool, themeValue: UInt32? = nil) {
        let value = hex == themeValue ? nil : hex
        if isDark { dark[id] = value } else { light[id] = value }
    }
}

extension NookPalette {
    /// The palette with the user's colors laid over it; unknown ids (from a newer or older Nook) are skipped.
    func applying(_ overrides: [String: UInt32]) -> NookPalette {
        var palette = self
        for (id, hex) in overrides {
            guard let token = NookColorToken.named(id) else { continue }
            palette[keyPath: token.keyPath] = hex & 0xFFFFFF
        }
        return palette
    }
}
