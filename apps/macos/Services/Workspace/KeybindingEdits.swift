import Foundation

// The shortcut recorder in Settings › Shortcuts writes your keys into `~/.nook/keybindings.json` here. It edits the file
// as a JSON list and leaves every entry it does not own alone (also ones Nook cannot read), so a hand-written file keeps
// what it says. A recorded key replaces the command's default keys: the file then holds the new key and, for each
// default key, a rule that switches it off (`"command": "-<id>"`, see `Keybindings.effective`).

enum KeybindingEdits {
    enum Failure: Error, Equatable {
        /// The file is there but not a JSON list: Nook does not overwrite what it cannot read.
        case unreadable
    }

    /// The text of a rule's key for a pressed chord: `mod` for ⌘, so the file reads the same as the defaults.
    static func ruleKey(_ chord: KeyChord) -> String {
        var modifiers = chord.modifiers
        if modifiers.contains(.cmd) {
            modifiers.remove(.cmd)
            modifiers.insert(.mod)
        }
        // The plus key comes out as `mod++`, which `KeyChord.parse` reads back.
        return KeyChord(modifiers: modifiers, key: chord.key).formatted
    }

    /// A key that a recording takes: a named key or one with ⌘, ⌃ or ⌥ (a plain letter or ⇧-letter types text, and F-keys
    /// and the named keys stand alone). Escape is never recorded (it cancels).
    static func isRecordable(_ chord: KeyChord) -> Bool {
        if chord.key == "escape" && chord.modifiers.isEmpty { return false }
        let named = chord.key.count > 1
        return named || !chord.modifiers.intersection([.cmd, .mod, .ctrl, .alt]).isEmpty
    }

    /// The rules a recording of `chord` for `command` adds: the new key with the condition of the command's default (so
    /// ⌘↩ still only sends from a composer), and a rule that switches off each default key it replaces.
    static func recordedRules(_ chord: KeyChord, for command: String,
                              defaults: [KeybindingRule] = Keybindings.defaults) -> [KeybindingRule] {
        let own = defaults.filter { $0.command == command }
        let key = ruleKey(chord)
        var out: [KeybindingRule] = own.compactMap { rule in
            rule.chord?.resolved == chord.resolved ? nil : KeybindingRule(key: rule.key, command: "-" + command, when: rule.when)
        }
        out.append(KeybindingRule(key: key, command: command, when: own.first?.when))
        return out
    }

    /// Your file with `command`'s rules (its keys and the switched-off defaults) replaced by `rules`; an empty `rules`
    /// resets the command to its defaults. `data` nil or empty is no file yet.
    static func apply(_ data: Data?, command: String, rules: [KeybindingRule]) throws -> Data {
        var list: [Any] = []
        if let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw Failure.unreadable }
            list = parsed
        }
        list.removeAll { item in
            guard let object = item as? [String: Any], let name = object["command"] as? String else { return false }
            return name == command || name == "-" + command
        }
        for rule in rules {
            var object: [String: Any] = ["key": rule.key, "command": rule.command]
            if let when = rule.when, !when.isEmpty { object["when"] = when }
            list.append(object)
        }
        let out = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
        return out + Data("\n".utf8)
    }

    /// Whether your rules change `command`: a key of your own, or a default switched off.
    static func isCustomized(_ command: String, user: [KeybindingRule]) -> Bool {
        user.contains { $0.command == command || $0.command == "-" + command }
    }

    /// The commands that would claim `chord` together with `command` in the same place (see `Keybindings.conflicts`), by
    /// the rules as they would be after recording it.
    static func conflicts(recording chord: KeyChord, for command: String, user: [KeybindingRule]) -> [String] {
        let added = recordedRules(chord, for: command)
        let rules = Keybindings.effective(user: user.filter { $0.command != command && $0.command != "-" + command } + added)
        let target = chord.resolved
        var out: [String] = []
        for conflict in Keybindings.conflicts(rules) where conflict.chord == target {
            let pair = [rules[conflict.first].command, rules[conflict.winner].command]
            guard pair.contains(command) else { continue }
            for other in pair where other != command && !out.contains(other) { out.append(other) }
        }
        return out
    }
}
