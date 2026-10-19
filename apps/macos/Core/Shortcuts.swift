import Foundation

/// Nook's global shortcuts, which you can change in Settings › Overview. Key codes and modifier bits are the Carbon
/// ones (kVK_*, cmdKey…), written out so this file needs nothing from AppKit (tested in ShortcutsTests).
enum ShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case talk, ask, lookAtScreen, screenPart, recordCall

    var id: String { rawValue }

    /// The hot key id Carbon reports back; stable per action.
    var hotKeyID: UInt32 {
        switch self {
        case .talk: return 1
        case .lookAtScreen: return 2
        case .ask: return 3
        case .screenPart: return 4
        case .recordCall: return 5
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .talk: return Shortcut(keyCode: Shortcut.space, modifiers: Shortcut.option)
        case .ask: return Shortcut(keyCode: Shortcut.space, modifiers: Shortcut.option | Shortcut.command)
        case .lookAtScreen: return Shortcut(keyCode: 0x2D, modifiers: Shortcut.option | Shortcut.command)   // N
        case .screenPart: return Shortcut(keyCode: 0x15, modifiers: Shortcut.option | Shortcut.command)     // 4
        case .recordCall: return Shortcut(keyCode: 0x0F, modifiers: Shortcut.option | Shortcut.command)     // R
        }
    }
}

struct Shortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags.
    var modifiers: UInt32

    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000
    static let space: UInt32 = 0x31

    /// A global shortcut needs a modifier, so typing a letter never triggers Nook (F-keys may stand alone).
    var isValid: Bool {
        modifiers & (Self.command | Self.option | Self.control) != 0 || Self.functionKeys[keyCode] != nil
    }

    /// "⌥⌘N", in the order macOS shows modifiers.
    var display: String {
        var out = ""
        if modifiers & Self.control != 0 { out += "⌃" }
        if modifiers & Self.option != 0 { out += "⌥" }
        if modifiers & Self.shift != 0 { out += "⇧" }
        if modifiers & Self.command != 0 { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    /// The key as an `NSMenuItem.keyEquivalent`, so a menu can show the shortcut aligned like every other one. Nil for keys a
    /// menu cannot show (arrows, return …).
    var menuKey: String? {
        if keyCode == Self.space { return " " }
        if let name = Self.functionKeys[keyCode], let number = Int(name.dropFirst()),
           let scalar = Unicode.Scalar(0xF704 + number - 1) {
            return String(Character(scalar))   // NSF1FunctionKey …
        }
        guard let name = Self.names[keyCode], name.count == 1, name.first?.isASCII == true else { return nil }
        return name.lowercased()
    }

    /// The key's name on a US layout (the key codes are positions, not letters).
    static func keyName(_ code: UInt32) -> String {
        if let name = names[code] { return name }
        if let name = functionKeys[code] { return name }
        return "#\(code)"
    }

    private static let names: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J",
        0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T",
        0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x29: ";", 0x27: "'", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x1B: "-", 0x18: "=", 0x32: "`"
    ]

    private static let functionKeys: [UInt32: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
    ]
}

/// Where the shortcuts are kept: only the ones you changed (or turned off), the rest are the defaults.
struct ShortcutSet: Equatable, Sendable {
    /// Action → its shortcut; nil means turned off.
    var custom: [ShortcutAction: Shortcut?] = [:]

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        if let set = custom[action] { return set }
        return action.defaultShortcut
    }

    /// Sets a shortcut. Another action that had the same one gives it up (turned off), so one key never does two things.
    /// Returns that action, if any.
    @discardableResult
    mutating func set(_ shortcut: Shortcut?, for action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        if let shortcut {
            for other in ShortcutAction.allCases where other != action && self.shortcut(for: other) == shortcut {
                custom[other] = .some(nil)
                displaced = other
            }
        }
        if shortcut == action.defaultShortcut {
            custom.removeValue(forKey: action)
        } else {
            custom[action] = .some(shortcut)
        }
        return displaced
    }

    static let defaultsKey = "shortcuts"

    static func load(from defaults: UserDefaults = .standard) -> ShortcutSet {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: Shortcut?].self, from: data) else { return ShortcutSet() }
        var set = ShortcutSet()
        for (key, value) in stored { if let action = ShortcutAction(rawValue: key) { set.custom[action] = .some(value) } }
        return set
    }

    func save(to defaults: UserDefaults = .standard) {
        var stored: [String: Shortcut?] = [:]
        for (action, value) in custom { stored[action.rawValue] = .some(value) }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
