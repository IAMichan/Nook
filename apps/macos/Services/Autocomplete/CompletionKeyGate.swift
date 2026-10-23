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

/// What the autocomplete key tap needs to know to decide, on its own thread and without asking the main thread, whether a
/// key or a click must not reach the app: what is on screen, the accept keys, the shortcuts. The controller keeps a copy of
/// it up to date (see `AutocompleteController.publishTapState`); `swallows` gives the same answer as the controller's own key
/// handling for the same state.
struct CompletionKeyGate: Equatable {
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
    var showing = Showing.nothing
    /// An accept key pressed now would be held until the suggestion on its way shows (see `holdAcceptKey`).
    var canHold = false
    /// An accept key is held: the next key goes to the app after it, in order.
    var holding = false

    /// Emoji per row in the picker.
    static let emojiColumns = 9

    private static let tab = 48, returnKey = 36, escape = 53
    private static let arrows: Set<Int> = [123, 124, 125, 126]

    /// True when `key` must not reach the app. Mirrors `AutocompleteController.handle(_:)`.
    func swallows(_ key: CompletionKeyPress) -> Bool {
        if keysStayWithNook { return false }
        if key.matches(toggleAll) { return true }
        if appKnown, key.matches(toggleApp) { return true }
        if key.matches(alternatives) { return true }
        guard active else { return false }

        let plainEscape = key.code == Self.escape && key.modifiers == 0
        let tabLeftToApp = leaveTab && key.code == Self.tab
        let accept = (key.matches(acceptWord) || key.matches(acceptAll)) && !tabLeftToApp
        switch showing {
        case .alternatives(let count):
            if !key.commandLike, let number = Int(key.characters), number >= 1, number <= count { return true }
            return plainEscape
        case .nothing:
            return !key.commandLike && accept && canHold
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

    /// An accept key while a key the main thread has not handled yet may have changed what is on screen: when nothing shows
    /// and the key could start a wait for a suggestion, the tap holds it and leaves the choice to the main thread, which
    /// passes it on to the app when nothing is coming. Keys are never let through and then taken back.
    func mayHold(_ key: CompletionKeyPress) -> Bool {
        guard !keysStayWithNook, active, showing == .nothing, !key.commandLike else { return false }
        let tabLeftToApp = leaveTab && key.code == Self.tab
        return (key.matches(acceptWord) || key.matches(acceptAll)) && !tabLeftToApp
    }

    /// The emoji under `point` (global display coordinates), when the picker shows.
    func emojiCell(at point: CGPoint) -> Int? {
        guard case .emoji(_, let cells) = showing else { return nil }
        return cells.firstIndex { $0.contains(point) }
    }
}
