import Foundation

// Configurable shortcuts: rules `{key, command, when}`, the LAST matching rule wins, invalid
// rules are skipped. `mod` is Command on macOS.

struct KeyChord: Equatable, Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let mod = Modifiers(rawValue: 1)
        static let cmd = Modifiers(rawValue: 2)
        static let ctrl = Modifiers(rawValue: 4)
        static let alt = Modifiers(rawValue: 8)
        static let shift = Modifiers(rawValue: 16)
    }

    var modifiers: Modifiers
    /// Lowercase; named keys are normalised (`arrowup` -> `up`, `return` -> `enter`).
    var key: String

    private static let aliases: [String: String] = [
        "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
        "return": "enter", "esc": "escape", "del": "delete", " ": "space",
    ]
    private static let named: Set<String> = ["up", "down", "left", "right", "enter", "escape", "tab", "space", "backspace",
                                             "delete", "home", "end", "pageup", "pagedown"]

    private static func normalizedKey(_ raw: String) -> String? {
        let k = raw.lowercased()
        let name = aliases[k] ?? k
        if named.contains(name) { return name }
        if name.count == 1 { return name }
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...20).contains(n) { return name }
        return nil
    }

    init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = Self.normalizedKey(key) ?? key.lowercased()
    }

    /// `mod+shift+k`, `mod+enter`, `alt+up`, `mod++`. Nil for no key, an unknown modifier or an unknown key name.
    static func parse(_ text: String) -> KeyChord? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        var rest = s
        var key: String
        if s == "+" { return KeyChord(modifiers: [], key: "+") }
        if s.hasSuffix("++") { key = "+"; rest = String(s.dropLast(2)) }
        else {
            var tokens = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard let last = tokens.popLast(), !last.isEmpty else { return nil }
            key = last
            rest = tokens.joined(separator: "+")
        }
        guard let normalized = normalizedKey(key) else { return nil }
        var mods: Modifiers = []
        if !rest.isEmpty {
            for token in rest.split(separator: "+", omittingEmptySubsequences: false) {
                switch token {
                case "mod": mods.insert(.mod)
                case "cmd", "meta", "command": mods.insert(.cmd)
                case "ctrl", "control": mods.insert(.ctrl)
                case "alt", "option": mods.insert(.alt)
                case "shift": mods.insert(.shift)
                default: return nil
                }
            }
        }
        return KeyChord(modifiers: mods, key: normalized)
    }

    /// Canonical text, modifiers in a fixed order.
    var formatted: String {
        var parts: [String] = []
        if modifiers.contains(.mod) { parts.append("mod") }
        if modifiers.contains(.cmd) { parts.append("cmd") }
        if modifiers.contains(.ctrl) { parts.append("ctrl") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// `mod` made concrete (this app is macOS-only: Command), so a pressed chord and a rule compare equal.
    var resolved: KeyChord {
        guard modifiers.contains(.mod) else { return self }
        var m = modifiers
        m.remove(.mod)
        m.insert(.cmd)
        return KeyChord(modifiers: m, key: key)
    }

    /// Menu-style glyphs, e.g. `⇧⌘K`.
    var symbols: String {
        let r = resolved
        var out = ""
        if r.modifiers.contains(.ctrl) { out += "⌃" }
        if r.modifiers.contains(.alt) { out += "⌥" }
        if r.modifiers.contains(.shift) { out += "⇧" }
        if r.modifiers.contains(.cmd) { out += "⌘" }
        let glyphs = ["up": "↑", "down": "↓", "left": "←", "right": "→", "enter": "↩", "escape": "⎋", "tab": "⇥",
                      "space": "␣", "backspace": "⌫", "delete": "⌦"]
        return out + (glyphs[key] ?? key.uppercased())
    }
}

/// `a && !b || (c)`; identifiers come from a context, unknown ones are false.
indirect enum WhenExpression: Equatable, Sendable {
    case ident(String)
    case not(WhenExpression)
    case and(WhenExpression, WhenExpression)
    case or(WhenExpression, WhenExpression)

    func evaluate(_ context: [String: Bool]) -> Bool {
        switch self {
        case .ident(let n): return context[n] ?? false
        case .not(let e): return !e.evaluate(context)
        case .and(let a, let b): return a.evaluate(context) && b.evaluate(context)
        case .or(let a, let b): return a.evaluate(context) || b.evaluate(context)
        }
    }

    var identifiers: Set<String> {
        switch self {
        case .ident(let n): return [n]
        case .not(let e): return e.identifiers
        case .and(let a, let b), .or(let a, let b): return a.identifiers.union(b.identifiers)
        }
    }

    static func parse(_ text: String) -> WhenExpression? {
        var tokens: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "(" || c == ")" || c == "!" { tokens.append(String(c)); i += 1; continue }
            if (c == "&" || c == "|"), i + 1 < chars.count, chars[i + 1] == c { tokens.append(String([c, c])); i += 2; continue }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                tokens.append(String(chars[i..<j])); i = j; continue
            }
            return nil
        }
        var pos = 0
        func parseOr() -> WhenExpression? {
            guard var left = parseAnd() else { return nil }
            while pos < tokens.count, tokens[pos] == "||" {
                pos += 1
                guard let right = parseAnd() else { return nil }
                left = .or(left, right)
            }
            return left
        }
        func parseAnd() -> WhenExpression? {
            guard var left = parseNot() else { return nil }
            while pos < tokens.count, tokens[pos] == "&&" {
                pos += 1
                guard let right = parseNot() else { return nil }
                left = .and(left, right)
            }
            return left
        }
        func parseNot() -> WhenExpression? {
            guard pos < tokens.count else { return nil }
            if tokens[pos] == "!" { pos += 1; return parseNot().map { .not($0) } }
            if tokens[pos] == "(" {
                pos += 1
                guard let inner = parseOr(), pos < tokens.count, tokens[pos] == ")" else { return nil }
                pos += 1
                return inner
            }
            let t = tokens[pos]
            guard let f = t.first, f.isLetter || f == "_" else { return nil }
            pos += 1
            return .ident(t)
        }
        guard let result = parseOr(), pos == tokens.count else { return nil }
        return result
    }
}

struct KeybindingRule: Codable, Equatable, Sendable {
    var key: String
    var command: String
    var when: String?

    var chord: KeyChord? { KeyChord.parse(key) }
    var condition: WhenExpression? { (when?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : WhenExpression.parse($0) } }

    /// Empty or missing `when` means "always".
    var isValid: Bool {
        guard chord != nil, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let w = when?.trimmingCharacters(in: .whitespaces), !w.isEmpty { return WhenExpression.parse(w) != nil }
        return true
    }

    func isActive(_ context: [String: Bool]) -> Bool {
        if let w = when?.trimmingCharacters(in: .whitespaces), !w.isEmpty {
            return WhenExpression.parse(w)?.evaluate(context) ?? false
        }
        return true
    }
}

enum Keybindings {
    struct Problem: Equatable, Sendable {
        enum Reason: String, Sendable { case notAnObject, missingKey, missingCommand, badKey, badWhen }
        var index: Int
        var reason: Reason
    }

    struct LoadResult: Equatable, Sendable {
        enum FileState: Sendable { case ok, empty, unparseable }
        var rules: [KeybindingRule]
        var problems: [Problem]
        var state: FileState
    }

    struct Conflict: Equatable, Sendable {
        var chord: KeyChord
        /// Indexes into the rules; `winner` (the later one) runs when both conditions hold.
        var first: Int
        var winner: Int
    }

    /// Skips bad rules and reports them; unknown fields are ignored. An empty or unparseable file gives no rules
    /// (the caller then uses `defaults`).
    static func load(_ data: Data) -> LoadResult {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return LoadResult(rules: [], problems: [], state: .empty)
        }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return LoadResult(rules: [], problems: [], state: .unparseable)
        }
        var rules: [KeybindingRule] = []
        var problems: [Problem] = []
        for (index, item) in array.enumerated() {
            guard let object = item as? [String: Any] else { problems.append(Problem(index: index, reason: .notAnObject)); continue }
            guard let key = object["key"] as? String else { problems.append(Problem(index: index, reason: .missingKey)); continue }
            guard let command = object["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                problems.append(Problem(index: index, reason: .missingCommand)); continue
            }
            let rule = KeybindingRule(key: key, command: command, when: object["when"] as? String)
            if rule.chord == nil { problems.append(Problem(index: index, reason: .badKey)); continue }
            if !rule.isValid { problems.append(Problem(index: index, reason: .badWhen)); continue }
            rules.append(rule)
        }
        return LoadResult(rules: rules, problems: problems, state: .ok)
    }

    static func encode(_ rules: [KeybindingRule]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(rules)) ?? Data("[]".utf8)
    }

    /// Defaults first, user rules after: the user's win on a shared key.
    static func effective(user: [KeybindingRule]) -> [KeybindingRule] { defaults + user }

    /// The last rule whose chord and condition both match wins, even for a different command.
    static func match(_ chord: KeyChord, context: [String: Bool], rules: [KeybindingRule]) -> String? {
        let target = chord.resolved
        return rules.last { $0.chord?.resolved == target && $0.isActive(context) }?.command
    }

    /// Rules on the same chord, with different commands, whose conditions can hold together. Exclusive conditions
    /// (`terminalFocus` vs `!terminalFocus`) are by design and not reported.
    static func conflicts(_ rules: [KeybindingRule]) -> [Conflict] {
        var out: [Conflict] = []
        for j in rules.indices {
            for i in 0..<j {
                guard let a = rules[i].chord?.resolved, a == rules[j].chord?.resolved, rules[i].command != rules[j].command else { continue }
                if canOverlap(rules[i].condition, rules[j].condition) { out.append(Conflict(chord: a, first: i, winner: j)) }
            }
        }
        return out
    }

    private static func canOverlap(_ a: WhenExpression?, _ b: WhenExpression?) -> Bool {
        let both: WhenExpression
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, nil), (nil, let x?): both = x
        case (let x?, let y?): both = .and(x, y)
        }
        let names = Array(both.identifiers).sorted().prefix(16)
        for mask in 0..<(1 << names.count) {
            var context: [String: Bool] = [:]
            for (n, name) in names.enumerated() { context[name] = mask & (1 << n) != 0 }
            if both.evaluate(context) { return true }
        }
        return false
    }

    /// Context keys the app provides.
    static let contextKeys = ["composerFocus", "composerDraft", "turnRunning", "editableFocus", "terminalFocus",
                              "modelPickerOpen", "paletteOpen", "diffOpen"]

    /// Everything a rule can name, including commands without a default key (interrupt).
    static let commandIDs = [
        "composer.send", "composer.sendAlternate", "composer.newline", "composer.stash", "composer.historyPrevious",
        "composer.historyNext", "queue.steerFirst", "chat.find", "commandPalette.toggle", "session.new",
        "session.previous", "session.next", "diff.toggle", "modelPicker.toggle", "session.settle", "session.pin",
        "session.undo", "session.interrupt",
    ]

    /// Default chat and workspace keybindings. `session.interrupt` stays unbound on purpose.
    static let defaults: [KeybindingRule] = [
        KeybindingRule(key: "mod+enter", command: "composer.send", when: "composerFocus && !turnRunning"),
        KeybindingRule(key: "mod+enter", command: "composer.sendAlternate", when: "composerFocus && turnRunning"),
        KeybindingRule(key: "shift+enter", command: "composer.newline", when: "composerFocus"),
        KeybindingRule(key: "mod+s", command: "composer.stash", when: "composerFocus && composerDraft"),
        KeybindingRule(key: "alt+up", command: "composer.historyPrevious", when: "composerFocus"),
        KeybindingRule(key: "alt+down", command: "composer.historyNext", when: "composerFocus"),
        KeybindingRule(key: "mod+shift+enter", command: "queue.steerFirst", when: "composerFocus && turnRunning"),
        KeybindingRule(key: "mod+f", command: "chat.find", when: "!terminalFocus"),
        KeybindingRule(key: "mod+k", command: "commandPalette.toggle", when: "!terminalFocus"),
        KeybindingRule(key: "mod+n", command: "session.new", when: "!terminalFocus"),
        KeybindingRule(key: "mod+shift+[", command: "session.previous", when: nil),
        KeybindingRule(key: "mod+shift+]", command: "session.next", when: nil),
        KeybindingRule(key: "mod+d", command: "diff.toggle", when: "!terminalFocus"),
        KeybindingRule(key: "mod+shift+m", command: "modelPicker.toggle", when: "!terminalFocus"),
        KeybindingRule(key: "mod+shift+s", command: "session.settle", when: "!terminalFocus"),
        KeybindingRule(key: "mod+shift+p", command: "session.pin", when: "!terminalFocus"),
        KeybindingRule(key: "mod+z", command: "session.undo", when: "!terminalFocus && !editableFocus"),
    ]
}
