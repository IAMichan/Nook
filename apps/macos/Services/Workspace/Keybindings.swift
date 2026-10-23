import Foundation

// Configurable shortcuts: rules `{key, command, when}`, the LAST matching rule wins, invalid
// rules are skipped. `mod` is Command on macOS. The panel's key monitor (`KeyCommandCenter`) builds the context, matches
// the pressed chord here and runs the handler a view registered for the command; the user's rules come from
// `~/.nook/keybindings.json` (see docs/KEYBINDINGS.md).

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

    /// Virtual key codes of the named keys (Carbon's `kVK_…`), which have no printable character of their own.
    private static let namedKeyCodes: [UInt16: String] = [
        36: "enter", 76: "enter", 53: "escape", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    /// A key as it was pressed. `characters` is what the key types without any modifier applied (so ⇧[ is `[`, not
    /// `{`); named keys are recognised by their key code. Nil for a key no rule can name (a dead key, a bare modifier).
    static func pressed(characters: String?, keyCode: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool) -> KeyChord? {
        var mods: Modifiers = []
        if command { mods.insert(.cmd) }
        if control { mods.insert(.ctrl) }
        if option { mods.insert(.alt) }
        if shift { mods.insert(.shift) }
        if let name = namedKeyCodes[keyCode] { return KeyChord(modifiers: mods, key: name) }
        guard let characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 || scalar.value > 0xF8FF else { return nil }
        return KeyChord(modifiers: mods, key: characters)
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
        /// `missing`: there is no file, which is the normal case (only the defaults apply).
        enum FileState: Sendable { case ok, empty, unparseable, missing }
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

    /// Reads the user's file. No file is no rules and no problem; a file that cannot be read counts as unparseable.
    static func read(_ url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return LoadResult(rules: [], problems: [], state: .missing) }
        guard let data = try? Data(contentsOf: url) else { return LoadResult(rules: [], problems: [], state: .unparseable) }
        return load(data)
    }

    /// Where the user's rules live: `~/.nook/keybindings.json`, next to Nook's other files for the command line.
    static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/keybindings.json")
    }

    /// Rules naming a command Nook does not know (a typo, or a command from another app): they load but never run.
    static func unknownCommands(_ rules: [KeybindingRule]) -> [KeybindingRule] {
        rules.filter { !commandIDs.contains($0.command) }
    }

    /// Every key a command answers to, in rule order without repeats (a user's rule adds a key, it does not take the
    /// default away).
    static func chords(for command: String, rules: [KeybindingRule]) -> [KeyChord] {
        var out: [KeyChord] = []
        for rule in rules where rule.command == command {
            if let chord = rule.chord?.resolved, !out.contains(chord) { out.append(chord) }
        }
        return out
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

    /// Context keys the app provides. `composerFocus`, `composerDraft` (the focused composer holds text) and
    /// `turnRunning` come from the focused composer; `editableFocus` and `terminalFocus` from the key window's first
    /// responder; `paletteOpen`, `modelPickerOpen` and `diffOpen` from the views that show them.
    static let contextKeys = ["composerFocus", "composerDraft", "turnRunning", "editableFocus", "terminalFocus",
                              "modelPickerOpen", "paletteOpen", "diffOpen"]

    /// Everything a rule can name, including commands without a default key (interrupt).
    static let commandIDs = [
        "composer.send", "composer.sendAlternate", "composer.newline", "composer.stash", "composer.historyPrevious",
        "composer.historyNext", "composer.access", "queue.steerFirst", "chat.find", "search.toggle", "commandPalette.toggle", "session.new",
        "session.previous", "session.next", "diff.toggle", "modelPicker.toggle", "session.settle", "session.pin",
        "session.undo", "session.interrupt",
    ]

    /// Default chat and workspace keybindings. `session.interrupt` stays unbound on purpose. ⌘S also brings a stashed
    /// draft back into an empty composer, so the stash rule does not ask for `composerDraft`.
    static let defaults: [KeybindingRule] = [
        KeybindingRule(key: "mod+enter", command: "composer.send", when: "composerFocus && !turnRunning"),
        KeybindingRule(key: "mod+enter", command: "composer.sendAlternate", when: "composerFocus && turnRunning"),
        KeybindingRule(key: "shift+enter", command: "composer.newline", when: "composerFocus"),
        KeybindingRule(key: "mod+s", command: "composer.stash", when: "composerFocus"),
        KeybindingRule(key: "alt+up", command: "composer.historyPrevious", when: "composerFocus"),
        KeybindingRule(key: "alt+down", command: "composer.historyNext", when: "composerFocus"),
        KeybindingRule(key: "shift+tab", command: "composer.access", when: "composerFocus"),
        KeybindingRule(key: "mod+shift+enter", command: "queue.steerFirst", when: "composerFocus && turnRunning"),
        KeybindingRule(key: "mod+f", command: "chat.find", when: "!terminalFocus"),
        KeybindingRule(key: "mod+k", command: "search.toggle", when: "!terminalFocus"),
        KeybindingRule(key: "mod+shift+k", command: "commandPalette.toggle", when: "!terminalFocus"),
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
