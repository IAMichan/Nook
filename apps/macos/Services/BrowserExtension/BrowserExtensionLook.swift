import Foundation

/// How Nook looks right now, as the browser extension's side panel and page strip draw it: System / Light / Dark, the
/// palette for each appearance (the chosen theme with the colors set one by one laid over it), the accent as drawn, the
/// diff colors and the density. The side panel turns it into CSS variables, so it shows the same theme as the main
/// window, also an imported VS Code theme. Plain Foundation, so the core tests check it.
///
/// Colors go as `#RRGGBB` only; the extension accepts nothing else, so a value can never become other CSS.
enum BrowserExtensionLook {
    /// The palette tokens the extension uses, by the names it gives its CSS variables (`--canvas`, `--text-strong`…).
    static let tokens: [(css: String, keyPath: KeyPath<NookPalette, UInt32>)] = [
        ("canvas", \.canvas), ("well", \.well), ("surface", \.surface), ("field", \.field), ("graphite", \.graphite),
        ("smoke", \.smoke), ("row-hover", \.rowHover), ("row-selected", \.rowSelected), ("bubble", \.bubble),
        ("composer", \.composer), ("composer-tray", \.composerTray), ("menu", \.menu),
        ("line", \.line), ("line2", \.line2), ("border", \.border), ("separator", \.separator), ("field-stroke", \.fieldStroke),
        ("paper", \.paper), ("text-strong", \.textStrong), ("text-secondary", \.textSecondary), ("text-muted", \.textMuted),
        ("text-tertiary", \.textTertiary),
        ("blue", \.blue), ("mint", \.mint), ("amber", \.amber), ("coral", \.coral), ("violet", \.violet),
    ]

    /// The look for the extension. `accent` is the user's accent; when it is `defaultAccent` each appearance takes its
    /// theme's own accent, as `NookTheme.accent(dark:)` does.
    static func payload(choice: NookThemeChoice, themes: [NookColorTheme], accent: UInt32, defaultAccent: UInt32,
                        density: NookDensity, diffColors: NookDiffColors) -> [String: Any] {
        func side(dark: Bool) -> [String: String] {
            let palette = choice.palette(dark: dark, themes: themes)
            var colors: [String: String] = [:]
            for token in tokens { colors[token.css] = NookColor.string(palette[keyPath: token.keyPath] & 0xFFFFFF) }
            let drawn = (accent & 0xFFFFFF) == (defaultAccent & 0xFFFFFF) ? palette.accent : accent & 0xFFFFFF
            colors["accent"] = NookColor.string(drawn)
            // Text on the accent: dark on a light accent (Nook's soft white), white on a deep one.
            colors["on-accent"] = NookColor.string(NookColor.luminance(drawn) > 0.45 ? 0x0B0B0D : 0xFFFFFF)
            colors["accent-hover"] = NookColor.string(NookColor.mix(drawn, palette.canvas, 0.12))
            colors["added"] = NookColor.string(diffColors.added(palette))
            colors["removed"] = NookColor.string(diffColors.removed(palette))
            return colors
        }
        return [
            "ok": true,
            "appearance": choice.mode.rawValue,
            "density": density.rawValue,
            "textScale": density.textScale,
            "spacingScale": density.spacingScale,
            "dark": side(dark: true),
            "light": side(dark: false),
        ]
    }
}
