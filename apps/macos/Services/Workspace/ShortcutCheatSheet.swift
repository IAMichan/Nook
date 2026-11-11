import Foundation

/// The shortcut cheat sheet (`?`): every command with the keys it answers to, grouped, from the same rules the key monitor
/// uses, so a key remapped in Settings › Shortcuts or in `keybindings.json` shows here the moment it works.
struct ShortcutCheatSheet: Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case composer, navigation, session, panels, other
    }

    struct Entry: Equatable, Identifiable, Sendable {
        var command: String
        var keys: [String]
        var group: Group
        var id: String { command }
    }

    var entries: [Entry]

    /// - Parameter rules: `Keybindings.effective(user:)`, as `KeyCommandCenter.rules` holds them.
    /// Commands without a key are left out: the sheet shows what can be pressed. The numbered jump and pick commands
    /// (⌘1–⌘9) are left out too: nine near-identical rows hide the rest.
    init(effective rules: [KeybindingRule], commands: [String] = Keybindings.commandIDs) {
        var entries: [Entry] = []
        for command in commands where !Self.numbered(command) {
            let keys = Self.unique(Keybindings.chords(for: command, rules: rules).map(\.symbols))
            guard !keys.isEmpty else { continue }
            entries.append(Entry(command: command, keys: keys, group: Self.group(of: command)))
        }
        self.entries = entries
    }

    func entries(in group: Group) -> [Entry] { entries.filter { $0.group == group } }

    /// What a typed filter keeps: the entries whose command id, name (given by the caller) or one of whose keys contains it.
    func filtered(_ query: String, name: (String) -> String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.command.lowercased().contains(q) || name(entry.command).lowercased().contains(q)
                || entry.keys.contains { $0.lowercased().contains(q) }
        }
    }

    static func group(of command: String) -> Group {
        switch command.split(separator: ".").first.map(String.init) ?? "" {
        case "composer", "queue", "selection", "effort", "effortPicker", "permissionPicker", "modelPicker": return .composer
        case "search", "commandPalette", "chat", "focus", "shortcuts": return .navigation
        case "session": return .session
        case "sidebar", "sidePanel", "sessionPanel", "terminal", "panel", "tab", "diff": return .panels
        default: return .other
        }
    }

    private static func numbered(_ command: String) -> Bool {
        (command.hasPrefix("session.jump") || command.hasPrefix("modelPicker.pick")) && command.last?.isNumber == true
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}
