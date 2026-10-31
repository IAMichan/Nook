import Foundation

/// A key as the autocomplete key tap sees it: its virtual key code, the modifiers held (`CompletionShortcut` bits) and the
/// characters it types.
struct CompletionKeyPress: Equatable {
    var code: Int
    var modifiers: Int
    var characters: String

    func matches(_ shortcut: CompletionShortcut?) -> Bool { shortcut?.matches(keyCode: code, modifiers: modifiers) ?? false }

    /// With ⌘ or ⌃: a shortcut, not typing.
    var commandLike: Bool { modifiers & (CompletionShortcut.command | CompletionShortcut.control) != 0 }
}

/// Which keys autocomplete takes from the app in the state it is in: what is on screen, the accept keys, the shortcuts.
/// `hotKeys` are the keys the controller registers as system hot keys for that state (see `AutocompleteHotKeys`), so macOS
/// keeps them from the app without any key waiting for Nook; `swallows` gives the same answer for one key press as the
/// controller's own key handling (`AutocompleteController.handle`).
struct CompletionKeyGate: Equatable {
    /// A key code with `CompletionShortcut` modifier bits, as a hot key is registered.
    struct HotKey: Hashable {
        var code: Int
        var modifiers: Int
    }

    enum Showing: Equatable {
        case nothing
        /// Other words to pick by number.
        case alternatives(count: Int)
        case completion
        /// A typo fix.
        case replacement
        /// The emoji picker: the length of the name typed after the colon, and where a click takes each emoji (global display
        /// coordinates, top left origin, like `CGEvent.location`).
        case emoji(nameLength: Int, cells: [CGRect])
    }

    /// Nook is in front and none of its text views has the focus (a shortcut recorder in Settings): every key is Nook's own.
    var keysStayWithNook = false
    /// Autocomplete works in the front app (see `AutocompleteController.isActive`). Secure Input is checked by the tap itself.
    var active = false
    /// The front app has a bundle id (the per-app pause shortcut needs one).
    var appKnown = false
    /// The front app keeps Tab for itself (see `CompletionAppRule.leaveTab`).
    var leaveTab = false
    var acceptWord = CompletionShortcut.tab
    var acceptAll = CompletionShortcut.shiftTab
    var toggleAll: CompletionShortcut?
    var toggleApp: CompletionShortcut?
    /// Nil while other words are turned off.
    var alternatives: CompletionShortcut?
    var suggestNow: CompletionShortcut?
    /// Suggestions are off here, but the `suggestNow` key would turn them on for the focused field (see
    /// `AutocompleteController.forcedApp`).
    var canForce = false
    var showing = Showing.nothing

    /// Emoji per row in the picker.
    static let emojiColumns = 9

    private static let tab = 48, returnKey = 36, escape = 53
    private static let arrows: Set<Int> = [123, 124, 125, 126]
    /// The keys 1 to 9 on the row above the letters, by position (ANSI): the number they type is checked when one is pressed.
    static let digitKeys = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// True when `key` must not reach the app. Mirrors `AutocompleteController.handle(_:)`.
    func swallows(_ key: CompletionKeyPress) -> Bool {
        if keysStayWithNook { return false }
        if key.matches(toggleAll) { return true }
        if appKnown, key.matches(toggleApp) { return true }
        if key.matches(alternatives) { return true }
        if key.matches(suggestNow), active || canForce { return true }
        guard active else { return false }

        let plainEscape = key.code == Self.escape && key.modifiers == 0
        let tabLeftToApp = leaveTab && key.code == Self.tab
        let accept = (key.matches(acceptWord) || key.matches(acceptAll)) && !tabLeftToApp
        switch showing {
        case .alternatives(let count):
            if !key.commandLike, let number = Int(key.characters), number >= 1, number <= count { return true }
            return plainEscape
        case .nothing:
            return false
        case .completion, .replacement:
            return accept || plainEscape
        case .emoji(let nameLength, _):
            if plainEscape { return true }
            if key.modifiers == 0, Self.arrows.contains(key.code) { return true }
            if accept || (key.code == Self.returnKey && key.modifiers == 0 && nameLength >= 2) { return true }
            if !key.commandLike, key.modifiers & CompletionShortcut.option == 0, let number = Int(key.characters),
               (1...Self.emojiColumns).contains(number) { return true }
            return false
        }
    }

    /// The keys to register as hot keys now: the shortcuts that are set, and while something shows the keys that act on it
    /// (as Cotypist does: Tab is the app's again as soon as no suggestion is on screen). A number key is registered with and
    /// without Shift, since some layouts need Shift for digits; whether it typed a number is checked when it is pressed.
    func hotKeys() -> Set<HotKey> {
        guard !keysStayWithNook else { return [] }
        var keys = Set<HotKey>()
        func add(_ shortcut: CompletionShortcut?) {
            if let shortcut { keys.insert(HotKey(code: shortcut.keyCode, modifiers: shortcut.modifiers)) }
        }
        func addDigits(_ count: Int) {
            for code in Self.digitKeys.prefix(count) {
                keys.insert(HotKey(code: code, modifiers: 0))
                keys.insert(HotKey(code: code, modifiers: CompletionShortcut.shift))
            }
        }
        add(toggleAll)
        if appKnown { add(toggleApp) }
        add(alternatives)
        if active || canForce { add(suggestNow) }
        guard active else { return keys }

        let escape = HotKey(code: Self.escape, modifiers: 0)
        func addAccept() {
            for shortcut in [acceptWord, acceptAll] where !(leaveTab && shortcut.keyCode == Self.tab) {
                add(shortcut)
            }
        }
        switch showing {
        case .nothing:
            break
        case .alternatives(let count):
            addDigits(count)
            keys.insert(escape)
        case .completion, .replacement:
            addAccept()
            keys.insert(escape)
        case .emoji(let nameLength, _):
            addAccept()
            keys.insert(escape)
            for code in Self.arrows { keys.insert(HotKey(code: code, modifiers: 0)) }
            if nameLength >= 2 { keys.insert(HotKey(code: Self.returnKey, modifiers: 0)) }
            addDigits(Self.emojiColumns)
        }
        return keys
    }

    /// The emoji under `point` (global display coordinates), when the picker shows.
    func emojiCell(at point: CGPoint) -> Int? {
        guard case .emoji(_, let cells) = showing else { return nil }
        return cells.firstIndex { $0.contains(point) }
    }
}
