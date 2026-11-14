import Foundation

/// Everything that sets how Nook looks, as one file to hand to someone else (Settings › Appearance › Share): the accent,
/// System / Light / Dark, the theme for each appearance (an imported VS Code theme travels inside the file), the colors
/// set one by one, the diff colors, the density, and Nook's own face. Importing it gives the other person the same look
/// and feel; nothing else of theirs changes.
///
/// The file is JSON with colors as `#RRGGBB`, so it reads (and diffs) as text. Reading is lenient like `NookLook(stored:)`:
/// a field that is missing or holds a value this Nook does not know keeps the receiver's own setting.
struct NookLookShare: Equatable {
    static let fileExtension = "nooklook"
    static let format = "nook-look"
    static let version = 1

    enum Failure: Error, Equatable { case notALookFile }

    var accent: UInt32?
    var mode: NookAppearanceMode?
    var darkTheme: String?
    var lightTheme: String?
    /// The imported themes the two choices above point at, as their VS Code source.
    var themes: [NookCustomTheme] = []
    var overrides = NookColorOverrides()
    var diffColors: NookDiffColors?
    var density: NookDensity?
    var look: NookLook?

    /// The share of what is set now. Only the imported themes in use go along, not every one ever imported.
    init(accent: UInt32, choice: NookThemeChoice, customThemes: [NookCustomTheme], diffColors: NookDiffColors,
         density: NookDensity, look: NookLook) {
        self.accent = accent & 0xFFFFFF
        mode = choice.mode
        darkTheme = choice.darkTheme
        lightTheme = choice.lightTheme
        themes = customThemes.filter { $0.id == choice.darkTheme || $0.id == choice.lightTheme }
        overrides = choice.overrides
        self.diffColors = diffColors
        self.density = density
        self.look = look
    }

    init() {}

    // MARK: File

    func encoded() -> Data {
        func side(_ theme: String?, _ colors: [String: UInt32]) -> [String: Any] {
            var out: [String: Any] = ["colors": colors.mapValues { NookColor.string($0 & 0xFFFFFF) }]
            if let theme { out["theme"] = theme }
            return out
        }
        var object: [String: Any] = [
            "format": Self.format,
            "version": Self.version,
            "dark": side(darkTheme, overrides.dark),
            "light": side(lightTheme, overrides.light),
            "themes": themes.map { ["id": $0.id, "name": $0.name, "source": $0.source] },
        ]
        if let accent { object["accent"] = NookColor.string(accent) }
        if let mode { object["appearance"] = mode.rawValue }
        if let diffColors { object["diffColors"] = diffColors.rawValue }
        if let density { object["density"] = density.rawValue }
        if let look, let data = look.stored.data(using: .utf8), let face = try? JSONSerialization.jsonObject(with: data) {
            object["nook"] = face
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Reads a look file; anything that is not one (another JSON, a VS Code theme) is refused.
    static func decode(_ data: Data) throws -> NookLookShare {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == format else { throw Failure.notALookFile }
        var share = NookLookShare()
        share.accent = NookColor.parse(object["accent"] as? String)
        share.mode = (object["appearance"] as? String).flatMap(NookAppearanceMode.init(rawValue:))
        share.diffColors = (object["diffColors"] as? String).flatMap(NookDiffColors.init(rawValue:))
        share.density = (object["density"] as? String).flatMap(NookDensity.init(rawValue:))
        if let face = object["nook"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: face) {
            share.look = NookLook(stored: String(decoding: data, as: UTF8.self))
        }
        func side(_ key: String) -> (theme: String?, colors: [String: UInt32]) {
            let side = object[key] as? [String: Any] ?? [:]
            let raw = side["colors"] as? [String: Any] ?? [:]
            var colors: [String: UInt32] = [:]
            for (id, value) in raw {
                // Only colors this Nook knows; one from a newer Nook is skipped instead of lying unused in the settings.
                guard NookColorToken.named(id) != nil, let hex = NookColor.parse(value as? String) else { continue }
                colors[id] = hex
            }
            return (side["theme"] as? String, colors)
        }
        let dark = side("dark"), light = side("light")
        share.darkTheme = dark.theme
        share.lightTheme = light.theme
        share.overrides = NookColorOverrides(dark: dark.colors, light: light.colors)
        share.themes = (object["themes"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let source = item["source"] as? String else { return nil }
            let theme = NookCustomTheme(id: id, name: item["name"] as? String ?? id, source: source)
            return theme.theme == nil ? nil : theme
        }
        return share
    }

    // MARK: Import

    /// What importing changes in the receiver's theme settings: the imported themes they get (theirs, plus the ones in
    /// the file they do not have yet) and the theme for each appearance. A theme they already have (the same source) is
    /// reused; one whose id they use for another theme gets a new id. A theme id that is neither built in nor in the file
    /// keeps theirs.
    struct ThemeResult: Equatable {
        var customThemes: [NookCustomTheme]
        var darkTheme: String
        var lightTheme: String
    }

    func themes(mergedInto existing: [NookCustomTheme], darkTheme currentDark: String, lightTheme currentLight: String,
                newID: () -> String = { "custom-" + UUID().uuidString.prefix(8).lowercased() }) -> ThemeResult {
        var result = existing
        var renamed: [String: String] = [:]
        for theme in themes where theme.id == darkTheme || theme.id == lightTheme {
            if let same = result.first(where: { $0.source == theme.source }) {
                renamed[theme.id] = same.id
                continue
            }
            var added = theme
            let taken = Set(result.map(\.id) + NookColorTheme.builtIn.map(\.id))
            while taken.contains(added.id) { added.id = newID() }
            renamed[theme.id] = added.id
            result.append(added)
        }
        func resolve(_ id: String?, current: String) -> String {
            guard let id else { return current }
            if let mapped = renamed[id] { return mapped }
            return NookColorTheme.builtIn.contains { $0.id == id } ? id : current
        }
        return ThemeResult(customThemes: result, darkTheme: resolve(darkTheme, current: currentDark),
                           lightTheme: resolve(lightTheme, current: currentLight))
    }
}
