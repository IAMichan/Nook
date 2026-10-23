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
    /// Also while editing a sentence, with words after the cursor (shown as a card, not over those words).
    var midLine = true
    /// Also in narrow fields (search boxes, address bars).
    var smallFields = false
    /// 0 only very sure suggestions … 1 eager.
    var eagerness = 0.5
    var trailingSpace = false
    /// Off: punctuation after a word ("there," or a closing period) waits for its own press of the accept key. A new name
    /// for the old `attachedPunctuation` (on by default and stored in every saved setting), so everyone starts with it off.
    var punctuationWithWord = false
    var escape = CompletionEscape.dismiss
    var pauseMinutes = 5
    /// Ghost text in the line or a small card below it.
    var inlineGhost = true
    /// Wait this long after the last key, in milliseconds. 0: the model starts on the key itself (see
    /// `AutocompleteController.speculate`).
    var delayMilliseconds = 0
    /// The words taken today, next to Nook's icon in the menu bar.
    var menuBarCount = false

    // Model: a GGUF path, "brain:<id>" for the brain's model, or empty for automatic (see CompletionSource.resolve).
    var modelPath = ""

    // Context
    var windowContext = true
    /// The text in the window being written in (Nook's screen reading, or read here through Accessibility).
    var screenContext = true
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
        "org.alacritty", "com.github.wez.wezterm", "com.apple.dt.Xcode", "dev.zed.Zed", "com.jetbrains.intellij", "com.sublimetext.4",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords"
    ]

    /// Code editors built on the web (VS Code and its forks): suggestions in their chat inputs and other prose fields (Claude
    /// Code, Copilot Chat), never in the code or the terminal, which have their own completion (see `CompletionFieldKind`).
    static let proseOnly: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"
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

/// Tells a code editor or terminal from a chat input inside the same app (see `CompletionPreferences.proseOnly`). Electron
/// editors are web pages: the field and the elements around it carry web classes (`AXDOMClassList`).
enum CompletionFieldKind {
    /// How far up from the field to look.
    static let depth = 12
    /// Classes of Monaco (VS Code's editor), xterm.js (its terminal), CodeMirror and Ace.
    static let codeClasses: Set<String> = [
        "monaco-editor", "inputarea", "xterm", "xterm-helper-textarea", "cm-editor", "cm-content", "ace_editor", "ace_text-input"
    ]
    /// Parts of class names around a chat input: Copilot Chat's input is a Monaco editor too, and is still prose.
    static let chatWords = ["chat", "interactive-input", "composer", "prompt"]

    /// - Parameters:
    ///   - classes: the field's web classes, then those of each element around it, nearest first.
    ///   - roleDescription: the field's (Monaco's is "editor").
    static func isCode(classes: [[String]], roleDescription: String?) -> Bool {
        let names = classes.joined().map { $0.lowercased() }
        if names.contains(where: { name in chatWords.contains { name.contains($0) } }) { return false }
        if names.contains(where: { codeClasses.contains($0) }) { return true }
        return ["editor", "terminal"].contains(roleDescription?.lowercased() ?? "")
    }

    /// What the accessibility tree says about the focused element, to tell a place where the user writes text from the other
    /// things that can hold the focus or take a value.
    struct Element: Equatable {
        var role: String?
        var subrole: String?
        var roleDescription: String?
        /// `AXIdentifier` and `AXDescription`: how the app names the field ("Address and search bar").
        var identifier: String?
        var label: String?
        /// The value can be set.
        var settable = false
        /// A web element inside something editable (`AXEditableAncestor`), or that says it is editable (`AXEditable`).
        var editable = false
        /// The value is text (a slider's or a checkbox's is a number).
        var textValue = false
    }

    /// Roles that take typed text.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea"]
    /// Controls that hold the focus or take a value but are never written in: a slider's or a stepper's value can be set
    /// too, and a focused list, table or web page is read, not typed into.
    static let controlRoles: Set<String> = [
        "AXSecureTextField", "AXSearchField", "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXButton", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXIncrementor", "AXStepper", "AXColorWell", "AXDateField", "AXTimeField", "AXLevelIndicator", "AXScrollBar",
        "AXDisclosureTriangle", "AXSplitter", "AXTabGroup", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXColumn",
        "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuBarItem", "AXImage", "AXWindow", "AXToolbar", "AXBrowser", "AXRuler",
    ]
    /// Subroles of fields that are not for prose: a search box, a password, a token field (the recipients of a mail).
    static let controlSubroles: Set<String> = ["AXSearchField", "AXSecureTextField", "AXTokenField"]
    /// Words in a field's name that mark a browser's address bar or a search box: a suggestion there opens a wrong page or
    /// searches for something else. English, Dutch, German, French and Spanish, as apps name them in the user's language.
    static let searchWords = [
        "address", "url", "omnibox", "location", "search", "adres", "zoek", "adresse", "such", "recherche", "dirección", "direccion",
        "buscar", "búsqueda", "busqueda",
    ]

    /// Whether the focused element is a place to write in: a text field or text area, a rich web editor, or a custom text view
    /// whose text can be set. Never a control, a search box, an address bar or a page that is only read.
    static func isWritable(_ element: Element) -> Bool {
        if let role = element.role, controlRoles.contains(role) { return false }
        if let subrole = element.subrole, controlSubroles.contains(subrole) { return false }
        if (element.roleDescription ?? "").lowercased().contains("token") { return false }
        let names = [element.identifier, element.label].compactMap { $0?.lowercased() }
        if names.contains(where: { name in searchWords.contains { name.contains($0) } }) { return false }
        if let role = element.role, textRoles.contains(role) { return true }
        // A web page is editable as a whole only in an editor (a mail being written); one that is only read is not.
        if element.editable { return true }
        return element.settable && element.textValue
    }
}
