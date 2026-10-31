import AppKit
import Carbon.HIToolbox

/// The keys autocomplete takes from the app (accept, Escape, the picker's arrows and numbers, its own shortcuts) as system
/// hot keys, the way Cotypist takes Tab: registered only while they mean something (`CompletionKeyGate.hotKeys`), and gone
/// again the moment the suggestion is. macOS keeps a hot key from the app by itself, so no key ever waits for Nook, and
/// every other key goes straight to the app; the key tap (`AutocompleteKeyTap`) only listens.
@MainActor
final class AutocompleteHotKeys {
    private var registered: [CompletionKeyGate.HotKey: HotKey] = [:]
    /// What the controller wants registered, also while `passing` keeps them all away.
    private var wanted: Set<CompletionKeyGate.HotKey> = []
    /// Keys macOS would not register (it refuses some modifier sets, such as ⌥ alone): not tried again each time.
    private var refused: Set<CompletionKeyGate.HotKey> = []
    /// A key is on its way to the app (`pass`): no hot keys until it is through, or it would come back here.
    private var passing = false
    private let pressed: (CompletionKeyPress, CGEventFlags) -> Void

    /// Hot key ids of their own ("AC" in the top bits), apart from the app's shortcuts (`Shortcuts.hotKeyID`).
    private static let idBase: UInt32 = 0x4143_0000
    /// How long the hot keys stay away after a key was passed on: the posted key has to go through the WindowServer first.
    private static let passGap: TimeInterval = 0.05

    /// - Parameter pressed: called on the main queue with the key a hot key took, as the user pressed it.
    init(pressed: @escaping (CompletionKeyPress, CGEventFlags) -> Void) {
        self.pressed = pressed
    }

    var keys: Set<CompletionKeyGate.HotKey> { Set(registered.keys) }

    /// Registers exactly `keys`; only what changed goes to macOS.
    func set(_ keys: Set<CompletionKeyGate.HotKey>) {
        wanted = keys
        if !passing { apply(keys) }
    }

    func stop() {
        wanted = []
        apply([])
    }

    /// A key a hot key took that is not autocomplete's after all (the state changed on the way, a number key that types no
    /// number on this layout): on to the app, as pressed.
    func pass(_ key: CompletionKeyPress, flags: CGEventFlags) {
        passing = true
        apply([])
        AutocompleteTyper.press(keyCode: key.code, flags: flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passGap) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.passing = false
                self.apply(self.wanted)
            }
        }
    }

    private func apply(_ keys: Set<CompletionKeyGate.HotKey>) {
        for key in registered.keys where !keys.contains(key) { registered[key] = nil }
        for key in keys where registered[key] == nil && !refused.contains(key) {
            let hotKey = HotKey(id: Self.id(key), keyCode: key.code, modifiers: Self.carbonModifiers(key.modifiers)) { [weak self] in
                MainActor.assumeIsolated { self?.fired(key) }
            }
            if let hotKey {
                registered[key] = hotKey
            } else {
                refused.insert(key)
                Log.autocomplete.error("macOS refused hot key \(key.code) with modifiers \(key.modifiers)")
            }
        }
    }

    private func fired(_ key: CompletionKeyGate.HotKey) {
        // Unregistered meanwhile: the key went nowhere, so it goes on to the app.
        let flags = Self.flags(key.modifiers)
        let press = CompletionKeyPress(code: key.code, modifiers: key.modifiers, characters: Self.characters(key.code, flags: flags))
        guard registered[key] != nil else { return pass(press, flags: flags) }
        pressed(press, flags)
    }

    /// Unique per key and modifiers.
    private static func id(_ key: CompletionKeyGate.HotKey) -> UInt32 {
        idBase | UInt32(key.modifiers & 0xFF) << 8 | UInt32(key.code & 0xFF)
    }

    static func carbonModifiers(_ modifiers: Int) -> Int {
        var result = 0
        if modifiers & CompletionShortcut.command != 0 { result |= cmdKey }
        if modifiers & CompletionShortcut.option != 0 { result |= optionKey }
        if modifiers & CompletionShortcut.control != 0 { result |= controlKey }
        if modifiers & CompletionShortcut.shift != 0 { result |= shiftKey }
        return result
    }

    static func flags(_ modifiers: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & CompletionShortcut.command != 0 { flags.insert(.maskCommand) }
        if modifiers & CompletionShortcut.option != 0 { flags.insert(.maskAlternate) }
        if modifiers & CompletionShortcut.control != 0 { flags.insert(.maskControl) }
        if modifiers & CompletionShortcut.shift != 0 { flags.insert(.maskShift) }
        return flags
    }

    /// What the key types on the current layout with these modifiers (a hot key brings no characters of its own).
    private static func characters(_ code: Int, flags: CGEventFlags) -> String {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: true)
        else { return "" }
        event.flags = flags
        return AutocompleteKeyTap.press(event).characters
    }
}
