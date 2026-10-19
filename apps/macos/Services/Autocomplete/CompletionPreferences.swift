import Foundation

/// A key with its modifiers. The modifier bits are Nook's own, so this file needs no AppKit.
struct CompletionShortcut: Codable, Equatable, Hashable {
    static let command = 1, option = 2, control = 4, shift = 8

    var keyCode: Int
    var modifiers: Int
    /// As shown, e.g. "⇧⇥".
    var label: String

    init(keyCode: Int, modifiers: Int = 0, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    func matches(keyCode: Int, modifiers: Int) -> Bool { self.keyCode == keyCode && self.modifiers == modifiers }

    static let tab = CompletionShortcut(keyCode: 48, label: "⇥")
    static let shiftTab = CompletionShortcut(keyCode: 48, modifiers: shift, label: "⇧⇥")
    static let optionTab = CompletionShortcut(keyCode: 48, modifiers: option, label: "⌥⇥")
    static let rightArrow = CompletionShortcut(keyCode: 124, modifiers: option, label: "⌥→")
    static let backtick = CompletionShortcut(keyCode: 50, label: "`")

    /// Plain typing keys make poor shortcuts: they could no longer be typed.
    var isTypingKey: Bool {
        modifiers & (Self.command | Self.control | Self.option) == 0 && ![48, 53, 36, 50].contains(keyCode) && !(96...126).contains(keyCode)
    }
}

enum CompletionEscape: String, Codable, CaseIterable, Identifiable {
    /// Hide the suggestion only.
    case dismiss
    /// Also pause for ten seconds.
    case pauseBriefly
    /// Also stop in this app until you switch apps.
    case offUntilAppSwitch

    var id: String { rawValue }
}

enum CompletionTriState: String, Codable, CaseIterable, Identifiable {
    case inherit, on, off

    var id: String { rawValue }

    func resolved(_ fallback: Bool) -> Bool {
        switch self {
        case .inherit: return fallback
        case .on: return true
        case .off: return false
        }
    }
}

/// Settings for one app, by bundle id.
struct CompletionAppRule: Codable, Equatable {
    var enabled = CompletionTriState.inherit
    var midLine = CompletionTriState.inherit
    /// Leave Tab to the app (indenting, moving between fields).
    var leaveTab = false
    var instructions = ""
    /// For apps whose cursor height misleads.
    var fontScale = 1.0
    var verticalOffset = 0.0
    var learn = true
}

/// Settings for one website, by host name.
struct CompletionSiteRule: Codable, Equatable {
    var enabled = CompletionTriState.inherit
    var instructions = ""
}

/// All of autocomplete's settings as one value, stored as JSON. Decoding fills in the defaults of fields added later, so
/// settings survive updates.
struct CompletionPreferences: Codable, Equatable {
    // General
    var enabled = false
    /// Off: only in apps turned on one by one.
    var enabledByDefault = true
    var maxWords = 8
    var midLine = false
    /// Also in narrow fields (search boxes, address bars).
    var smallFields = false
    /// 0 only very sure suggestions … 1 eager.
    var eagerness = 0.5
    var trailingSpace = false
    var attachedPunctuation = true
    var escape = CompletionEscape.dismiss
    var pauseMinutes = 5
    /// Ghost text in the line or a small card below it.
    var inlineGhost = true
    /// Wait this long after the last key, in milliseconds.
    var delayMilliseconds = 120

    // Model: a GGUF path, "brain:<id>" for the brain's model, or empty for automatic (see CompletionSource.resolve).
    var modelPath = ""

    // Context
    var windowContext = true
    var screenContext = false
    var clipboardContext = false
    var memoryContext = true

    // Personal
    var instructions = ""
    var learn = false
    var personalStrength = 0.3

    // Per app and site
    var apps: [String: CompletionAppRule] = [:]
    var sites: [String: CompletionSiteRule] = [:]

    // Keys
    var acceptWord = CompletionShortcut.tab
    var acceptAll = CompletionShortcut.shiftTab
    var toggleAll: CompletionShortcut?
    var toggleApp: CompletionShortcut?
    var alternatives: CompletionShortcut?
    // The three above are off until a key is recorded; JSON leaves out nil, and the default is nil too, so off stays off.

    // Emoji
    var emoji = true
    /// 0 yellow, 1…5 light to dark.
    var skinTone = 0

    // Typos
    var typos = true
    var showTypoFixes = true

    // Battery
    var shorterOnBattery = true
    var pauseOnBattery = false

    // Labs
    var wordAlternatives = false
    var autoAlternatives = false

    /// Apps where suggestions are off unless turned on: terminals and code editors (they have their own completion) and
    /// password managers.
    static let offByDefault: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.jetbrains.intellij", "com.sublimetext.4", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"
    ]

    static func decode(_ data: Data) -> CompletionPreferences {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return CompletionPreferences() }
        var merged = object(CompletionPreferences()).merging(stored) { _, new in new }
        merged["apps"] = entries(stored["apps"], defaults: object(CompletionAppRule()))
        merged["sites"] = entries(stored["sites"], defaults: object(CompletionSiteRule()))
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let value = try? JSONDecoder().decode(CompletionPreferences.self, from: data) else { return CompletionPreferences() }
        return value
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    func app(_ bundleID: String?) -> CompletionAppRule { bundleID.flatMap { apps[$0] } ?? CompletionAppRule() }

    func isEnabled(inApp bundleID: String?) -> Bool {
        guard enabled else { return false }
        let fallback = enabledByDefault && !Self.offByDefault.contains(bundleID ?? "")
        return app(bundleID).enabled.resolved(fallback)
    }

    func isEnabled(onSite host: String?) -> Bool {
        host.flatMap { sites[$0] }?.enabled.resolved(true) ?? true
    }

    func midLine(inApp bundleID: String?) -> Bool { app(bundleID).midLine.resolved(midLine) }

    /// General, app and site instructions, in that order.
    func instructions(app bundleID: String?, site host: String?) -> [String] {
        [instructions, app(bundleID).instructions, host.flatMap { sites[$0]?.instructions } ?? ""]
    }

    private static func object<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func entries(_ stored: Any?, defaults: [String: Any]) -> [String: Any] {
        guard let entries = stored as? [String: Any] else { return [:] }
        return entries.compactMapValues { ($0 as? [String: Any]).map { defaults.merging($0) { _, new in new } } }
    }
}
