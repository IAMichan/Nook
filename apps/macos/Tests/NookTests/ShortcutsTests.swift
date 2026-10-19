import XCTest

/// Nook's global shortcuts: defaults, names, one key for one thing, and keeping them.
final class ShortcutsTests: XCTestCase {
    func testDefaultsAndNames() {
        let set = ShortcutSet()
        XCTAssertEqual(set.shortcut(for: .lookAtScreen)?.display, "⌥⌘N")
        XCTAssertEqual(set.shortcut(for: .talk)?.display, "⌥Space")
        XCTAssertEqual(Shortcut(keyCode: 0x15, modifiers: Shortcut.control | Shortcut.shift).display, "⌃⇧4")
        XCTAssertFalse(Shortcut(keyCode: 0x00, modifiers: Shortcut.shift).isValid, "⇧A would fire while typing")
        XCTAssertTrue(Shortcut(keyCode: 0x7A, modifiers: 0).isValid, "F1 alone is fine")
    }

    func testOneKeyDoesOneThing() {
        var set = ShortcutSet()
        let taken = set.shortcut(for: .lookAtScreen)
        XCTAssertEqual(set.set(taken, for: .recordCall), .lookAtScreen)
        XCTAssertNil(set.shortcut(for: .lookAtScreen), "the other action gives it up")
        XCTAssertEqual(set.shortcut(for: .recordCall), taken)
        set.set(nil, for: .talk)
        XCTAssertNil(set.shortcut(for: .talk))
        set.set(ShortcutAction.talk.defaultShortcut, for: .talk)
        XCTAssertEqual(set.shortcut(for: .talk), ShortcutAction.talk.defaultShortcut)
    }

    func testKept() {
        let defaults = UserDefaults(suiteName: "nook.shortcuts.test")!
        defaults.removePersistentDomain(forName: "nook.shortcuts.test")
        var set = ShortcutSet()
        set.set(Shortcut(keyCode: 0x0D, modifiers: Shortcut.control | Shortcut.option), for: .ask)
        set.set(nil, for: .screenPart)
        set.save(to: defaults)
        let loaded = ShortcutSet.load(from: defaults)
        XCTAssertEqual(loaded.shortcut(for: .ask)?.display, "⌃⌥W")
        XCTAssertNil(loaded.shortcut(for: .screenPart))
        XCTAssertEqual(loaded.shortcut(for: .talk), ShortcutAction.talk.defaultShortcut)
    }
}
