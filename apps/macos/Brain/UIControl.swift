import Foundation

/// Mouse and keyboard control of one app, the way a person would use it: click a button or a switch, type in a field,
/// press a key, scroll. This is the part without AppKit (what a step is, which steps are allowed, how an element the
/// brain names is found again), so it can be tested anywhere; `UIDriver` performs the steps on the Mac.
///
/// The brain reads an app's window with `read_ui` and proposes steps with `control_ui`. The user approves the exact
/// steps in the plan; they run in that one app only. Elements are named by their label, never by a number from an
/// earlier read, and are looked up again right before each step, so a window that changed since is not clicked blindly.
enum UIControl {
    enum Action: String, CaseIterable {
        case click, doubleClick = "double_click", rightClick = "right_click", type, key, scroll, open, wait
    }

    /// One step as the brain proposes it. Which fields matter depends on the action.
    struct Step: Equatable {
        var action: Action
        /// Label of an element as `read_ui` shows it ("Bluetooth", "Dark", "Search").
        var element: String?
        /// Role to tell elements with the same label apart: button, checkbox, switch, field, row…
        var role: String?
        /// Which of several elements with this label and role, counted from the top left (1 = first).
        var index: Int?
        /// A point on screen in points, top left of the main display is 0,0 (as `read_ui` reports it).
        var x: Double?
        var y: Double?
        /// What to type.
        var text: String?
        /// Select what is in the field first, so the typed text replaces it.
        var replace = false
        /// A key or shortcut: "return", "escape", "tab", "cmd+f", "cmd+shift+n".
        var keys: String?
        /// Scrolling: up, down, left or right, and how many lines.
        var direction: String?
        var amount: Int?
        /// For `open`: a System Settings pane (x-apple.systempreferences:…). Without it, the app itself is opened.
        var url: String?
        var seconds: Double?
    }

    static let maxSteps = 15
    static let maxText = 500
    static let maxWait = 5.0
    static let maxScroll = 30

    // MARK: Reading the proposal

    /// The steps in a `control_ui` call; entries that are not a step at all are dropped (and reported by `problems`).
    static func steps(_ raw: Any?) -> [Step] {
        let list: [Any]
        if let array = raw as? [Any] {
            list = array
        } else if let text = raw as? String, let data = text.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            // Some models send the list as a JSON string.
            list = array
        } else {
            return []
        }
        return list.compactMap { entry in
            guard let object = entry as? [String: Any],
                  let name = (object["action"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_"),
                  let action = Action(rawValue: name) else { return nil }
            func text(_ key: String) -> String? {
                let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (value?.isEmpty ?? true) ? nil : value
            }
            func number(_ key: String) -> Double? {
                if let value = object[key] as? Double { return value }
                if let value = object[key] as? Int { return Double(value) }
                if let value = object[key] as? NSNumber { return value.doubleValue }
                if let value = object[key] as? String { return Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
                return nil
            }
            var step = Step(action: action)
            step.element = text("element")
            step.role = text("role")?.lowercased()
            step.index = number("index").flatMap { Int(exactly: $0.rounded()) }
            step.x = number("x")
            step.y = number("y")
            // Typed text keeps its spaces: "  " can be what the user wants.
            step.text = (object["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            step.replace = (object["replace"] as? Bool) ?? ((object["replace"] as? String)?.lowercased() == "true")
            step.keys = text("keys") ?? text("key")
            step.direction = text("direction")?.lowercased()
            step.amount = number("amount").flatMap { Int(exactly: $0.rounded()) }
            step.url = text("url")
            step.seconds = number("seconds")
            return step
        }
    }

    /// Everything wrong with a proposal, in plain language for the model and the plan (empty = fine).
    static func problems(app: String, steps raw: Any?, bundleID: String? = nil) -> [String] {
        var problems: [String] = []
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { problems.append("The app is missing.") }
        if isBlocked(app: name, bundleID: bundleID) {
            problems.append("Nook does not control \(name) with mouse and keyboard: it holds passwords, runs commands or is Nook itself.")
        }
        let count = (raw as? [Any])?.count ?? (raw as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any] }?.count ?? 0
        let parsed = steps(raw)
        if parsed.isEmpty { problems.append("There are no steps.") }
        if parsed.count < count { problems.append("\(count - parsed.count) step(s) have no valid action (use one of: \(Action.allCases.map(\.rawValue).joined(separator: ", "))).") }
        if parsed.count > maxSteps { problems.append("At most \(maxSteps) steps at a time.") }
        for (offset, step) in parsed.enumerated() {
            problems += self.problems(step).map { "Step \(offset + 1): \($0)" }
        }
        return problems
    }

    static func problems(_ step: Step) -> [String] {
        var problems: [String] = []
        let hasPoint = step.x != nil && step.y != nil
        if (step.x == nil) != (step.y == nil) { problems.append("give both x and y") }
        if let x = step.x, let y = step.y, !(x.isFinite && y.isFinite && x > -20_000 && x < 20_000 && y > -20_000 && y < 20_000) {
            problems.append("the point is not on a screen")
        }
        if let index = step.index, index < 1 { problems.append("index starts at 1") }
        switch step.action {
        case .click, .doubleClick, .rightClick:
            if step.element == nil && !hasPoint { problems.append("name the element (its label) or give x and y") }
        case .type:
            guard let text = step.text else { problems.append("the text to type is missing"); break }
            if text.count > maxText { problems.append("at most \(maxText) characters at a time") }
        case .key:
            guard let keys = step.keys else { problems.append("the key is missing, e.g. \"return\" or \"cmd+f\""); break }
            if let combo = parseKeys(keys) {
                if let reason = forbidden(combo) { problems.append(reason) }
            } else {
                problems.append("unknown key \"\(keys)\"")
            }
        case .scroll:
            if !["up", "down", "left", "right"].contains(step.direction ?? "") { problems.append("direction must be up, down, left or right") }
            if let amount = step.amount, amount < 1 || amount > maxScroll { problems.append("amount must be 1 to \(maxScroll)") }
        case .open:
            if let url = step.url, !isSettingsPane(url) { problems.append("only System Settings panes (x-apple.systempreferences:…) can be opened here; use open_url for web pages") }
        case .wait:
            if let seconds = step.seconds, !(seconds > 0 && seconds <= maxWait) { problems.append("wait at most \(Int(maxWait)) seconds") }
        }
        return problems
    }

    static func isSettingsPane(_ url: String) -> Bool {
        url.lowercased().hasPrefix("x-apple.systempreferences:") && !url.contains(" ")
    }

    /// How many times in a row the conversation was continued with `marker` (Nook's own "go on" after a batch of
    /// steps), counted back from the newest question until the user asked something else.
    static func rounds(in questions: [String], marker: String) -> Int {
        questions.reversed().prefix { $0 == marker }.count
    }

    // MARK: Apps Nook never drives

    /// Apps that hold passwords or run anything typed into them, and Nook itself (clicking its own Run button would approve
    /// its own plans). Matched by bundle id when known, and by name.
    static let blockedBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
        "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.SecurityAgent", "com.apple.loginwindow",
        "com.apple.systemevents"
    ]
    static let blockedNames: [String] = [
        "terminal", "iterm", "iterm2", "warp", "ghostty", "kitty", "alacritty", "hyper", "wezterm",
        "keychain access", "sleutelhangertoegang", "schlüsselbundverwaltung", "trousseaux d'accès", "acceso a llaveros",
        "passwords", "wachtwoorden", "passwörter", "mots de passe", "contraseñas",
        "1password", "bitwarden", "lastpass", "dashlane", "enpass",
        "script editor", "scripteditor", "automator", "securityagent", "loginwindow", "system events", "nook"
    ]

    static func isBlocked(app name: String, bundleID: String?) -> Bool {
        if let bundleID {
            if blockedBundles.contains(bundleID) { return true }
            if bundleID.lowercased().hasPrefix("nl.imdigital.nook") { return true }
        }
        let clean = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "")
        return blockedNames.contains(clean)
    }

    // MARK: Keys

    enum Modifier: String, CaseIterable {
        case command, shift, option, control, function
    }

    struct KeyCombo: Equatable {
        var modifiers: Set<Modifier>
        var key: String
        var code: UInt16
    }

    private static let modifierNames: [String: Modifier] = [
        "cmd": .command, "command": .command, "⌘": .command, "meta": .command, "super": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control,
        "fn": .function, "function": .function
    ]

    /// Virtual key codes of a US keyboard layout (kVK_…), by the names a model uses.
    static let keyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
            "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
            "f11": 103, "f12": 104
        ]
        // Other names models use for the same keys.
        for (alias, key) in ["arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
                             "leftarrow": "left", "rightarrow": "right", "uparrow": "up", "downarrow": "down",
                             "comma": ",", "period": ".", "slash": "/", "minus": "-", "equal": "=", "plus": "=",
                             "spacebar": "space", "del": "forwarddelete"] {
            codes[alias] = codes[key]
        }
        return codes
    }()

    /// "cmd+shift+n", "Command-F", "⌘,", "Return" → the combo, or nil when a part is unknown.
    static func parseKeys(_ raw: String) -> KeyCombo? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (spaced, joined) in [("page up", "pageup"), ("page down", "pagedown"), ("forward delete", "forwarddelete"), ("arrow ", "")] {
            text = text.replacingOccurrences(of: spaced, with: joined)
        }
        guard !text.isEmpty else { return nil }
        var modifiers = Set<Modifier>()
        // Symbols written without a separator: "⌘⇧n", "⌘,".
        for (symbol, modifier) in [("⌘", Modifier.command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)] where text.contains(symbol) {
            modifiers.insert(modifier)
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        // "+" can also be the key itself ("cmd++"), so split by hand.
        var parts: [String] = []
        var current = ""
        for character in text {
            if (character == "+" || character == "-" || character == " ") && !current.isEmpty {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard let last = parts.last else { return nil }
        for part in parts.dropLast() {
            guard let modifier = modifierNames[part] else { return nil }
            modifiers.insert(modifier)
        }
        let key = last == "+" ? "=" : last
        guard let code = keyCodes[key] else { return nil }
        return KeyCombo(modifiers: modifiers, key: key, code: code)
    }

    /// Shortcuts that end the session, lock the Mac, force quit apps or open a shell, whatever app has the keyboard.
    static func forbidden(_ combo: KeyCombo) -> String? {
        let mods = combo.modifiers
        if mods == [.command, .control] && combo.key == "q" { return "locking the screen is not something Nook does" }
        if mods.isSuperset(of: [.command, .shift]) && combo.key == "q" { return "logging out is not something Nook does" }
        if mods.isSuperset(of: [.command, .option]) && ["escape", "esc"].contains(combo.key) { return "force quitting apps is not something Nook does" }
        if mods.contains(.command) && combo.key == "space" { return "Spotlight is outside the approved app" }
        if mods.contains(.command) && combo.key == "tab" { return "switching apps is outside the approved app" }
        if mods.contains(.control) && ["up", "down", "left", "right"].contains(combo.key) { return "switching spaces is outside the approved app" }
        return nil
    }

    // MARK: Elements

    /// One element of a window, as read through the accessibility layer.
    struct Element: Equatable {
        /// Short role name: button, checkbox, switch, radio, popup, field, text, row, link, slider, tab, menuitem…
        var role: String
        var label: String
        var value: String?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var enabled = true
        var focused = false
        /// A password field: its value is never read, typing into it is refused.
        var secure = false

        var centerX: Double { x + width / 2 }
        var centerY: Double { y + height / 2 }

        func contains(x px: Double, y py: Double) -> Bool {
            px >= x && px <= x + width && py >= y && py <= y + height
        }
    }

    /// Short role names for AX roles and subroles.
    static func role(_ axRole: String, subrole: String?) -> String {
        switch subrole {
        case "AXSwitch": return "switch"
        case "AXSecureTextField": return "password"
        case "AXSearchField": return "search"
        case "AXTabButton": return "tab"
        case "AXToggle": return "toggle"
        default: break
        }
        switch axRole {
        case "AXButton": return "button"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "popup"
        case "AXMenuButton": return "menubutton"
        case "AXComboBox": return "combobox"
        case "AXTextField": return "field"
        case "AXTextArea": return "textarea"
        case "AXStaticText": return "text"
        case "AXSlider": return "slider"
        case "AXIncrementor", "AXStepper": return "stepper"
        case "AXLink": return "link"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXMenuItem": return "menuitem"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXTab": return "tab"
        case "AXColorWell": return "color"
        case "AXDateField": return "date"
        default:
            return axRole.hasPrefix("AX") ? String(axRole.dropFirst(2)).lowercased() : axRole.lowercased()
        }
    }

    /// Roles a person clicks, types in or reads to know where they are; the rest of the tree (groups, scroll areas,
    /// split views) only holds these.
    static let listedRoles: Set<String> = [
        "button", "checkbox", "switch", "toggle", "radio", "popup", "menubutton", "combobox", "field", "search", "password",
        "textarea", "text", "slider", "stepper", "link", "row", "cell", "menuitem", "disclosure", "tab", "color", "date"
    ]

    /// Roles that are written as a name for `role` in a step, with the other words models use for them.
    private static let roleAliases: [String: Set<String>] = [
        "button": ["button", "menubutton"], "checkbox": ["checkbox", "switch", "toggle"], "switch": ["switch", "checkbox", "toggle"],
        "toggle": ["toggle", "switch", "checkbox"], "radio": ["radio", "tab"], "popup": ["popup", "menubutton", "combobox"],
        "menu": ["popup", "menubutton", "menuitem"], "field": ["field", "search", "textarea", "combobox", "password"],
        "textfield": ["field", "search", "textarea", "combobox"], "search": ["search", "field"], "text": ["text"],
        "row": ["row", "cell"], "cell": ["cell", "row"], "item": ["row", "cell", "menuitem"], "menuitem": ["menuitem"],
        "link": ["link"], "slider": ["slider"], "tab": ["tab", "radio"], "stepper": ["stepper"]
    ]

    enum MatchError: Error, Equatable {
        case notFound(String)
        case ambiguous(String, Int)
    }

    /// The element a step names: an exact label first, then one that starts with it, then one that contains it. With
    /// several of the best kind, `index` picks one (in reading order); without it the step fails instead of guessing.
    static func match(_ label: String, role: String?, index: Int?, in elements: [Element]) -> Result<Element, MatchError> {
        let wanted = normalize(label)
        guard !wanted.isEmpty else { return .failure(.notFound(label)) }
        let roles = role.map { roleAliases[$0.lowercased()] ?? [$0.lowercased()] }
        // Text that is only a label is clicked only when asked for, or when nothing else has that name.
        let candidates = elements.filter { element in
            roles.map { $0.contains(element.role) } ?? true
        }
        let tiers: [(Element) -> Bool] = [
            { normalize($0.label) == wanted },
            { normalize($0.label).hasPrefix(wanted) },
            { normalize($0.label).contains(wanted) }
        ]
        for tier in tiers {
            var found = candidates.filter(tier)
            if found.isEmpty { continue }
            if role == nil, found.contains(where: { $0.role != "text" }) { found.removeAll { $0.role == "text" } }
            let ordered = found.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            if let index {
                guard index <= ordered.count else { return .failure(.notFound(label)) }
                return .success(ordered[index - 1])
            }
            if ordered.count == 1 { return .success(ordered[0]) }
            // The same control listed twice (a row and the text in it at the same spot) is one control.
            if Set(ordered.map { "\(Int($0.centerX)),\(Int($0.centerY))" }).count == 1 { return .success(ordered[0]) }
            return .failure(.ambiguous(label, ordered.count))
        }
        return .failure(.notFound(label))
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’:"))
    }

    /// The window as the brain reads it: one line per element, with the label to name it by and where it is.
    static func describe(app: String, window: String?, elements: [Element], limit: Int = 9_000) -> String {
        var lines = ["App: \(app)" + (window.map { $0.isEmpty ? "" : " — window \"\($0)\"" } ?? "")]
        lines.append("Elements (role \"label\" [value] @ x,y). Name an element by its label in control_ui; add role or index when labels repeat.")
        var used = lines.joined(separator: "\n").count
        var shown = 0
        for element in elements {
            var line = "- \(element.role) \"\(element.label)\""
            if element.secure {
                line += " [password field]"
            } else if let value = element.value, !value.isEmpty {
                line += " [\(String(value.prefix(80)))]"
            }
            if !element.enabled { line += " (disabled)" }
            if element.focused { line += " (focused)" }
            line += " @ \(Int(element.centerX.rounded())),\(Int(element.centerY.rounded()))"
            if used + line.count + 1 > limit { break }
            lines.append(line)
            used += line.count + 1
            shown += 1
        }
        if shown < elements.count { lines.append("… \(elements.count - shown) more elements not shown (scroll, or use a search field).") }
        if elements.isEmpty { lines.append("(no elements could be read; the window may still be loading)") }
        return lines.joined(separator: "\n")
    }

    /// Value text for a checkbox, switch or radio button: on or off reads better than 1 or 0.
    static func stateText(role: String, value: Any?) -> String? {
        if ["checkbox", "switch", "toggle", "radio"].contains(role) {
            if let number = value as? NSNumber { return number.intValue == 0 ? "off" : (number.intValue == 1 ? "on" : "mixed") }
            if let bool = value as? Bool { return bool ? "on" : "off" }
        }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
