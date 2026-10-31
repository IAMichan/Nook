import XCTest

/// Which keys autocomplete takes (`CompletionKeyGate`) must match what the controller does with a key, and the hot keys it
/// registers must be exactly those keys.
final class CompletionKeyGateTests: XCTestCase {
    private let tab = 48, escape = 53, returnKey = 36, leftArrow = 123, aKey = 0, digitOne = 18

    private func key(_ code: Int, _ modifiers: Int = 0, _ characters: String = "") -> CompletionKeyPress {
        CompletionKeyPress(code: code, modifiers: modifiers, characters: characters)
    }

    private func makeGate(_ showing: CompletionKeyGate.Showing, active: Bool = true) -> CompletionKeyGate {
        var gate = CompletionKeyGate()
        gate.active = active
        gate.appKnown = true
        gate.showing = showing
        return gate
    }

    func testCompletionTakesTabAndShiftTabAndEscape() {
        let gate = makeGate(.completion)
        XCTAssertTrue(gate.swallows(key(tab, 0, "\t")))
        XCTAssertTrue(gate.swallows(key(tab, CompletionShortcut.shift, "\t")))
        XCTAssertTrue(gate.swallows(key(escape, 0, "\u{1b}")))
        XCTAssertFalse(gate.swallows(key(aKey, 0, "a")))
        XCTAssertFalse(gate.swallows(key(tab, CompletionShortcut.command, "\t")))
    }

    func testTabStaysWithAppsThatKeepIt() {
        var gate = makeGate(.completion)
        gate.leaveTab = true
        XCTAssertFalse(gate.swallows(key(tab, 0, "\t")))
        XCTAssertTrue(gate.swallows(key(escape, 0, "\u{1b}")))
    }

    /// As Cotypist: with nothing on screen Tab is the app's, and no hot key is registered for it.
    func testNothingShowingLeavesEveryKeyToTheApp() {
        let gate = makeGate(.nothing)
        XCTAssertFalse(gate.swallows(key(tab, 0, "\t")))
        XCTAssertFalse(gate.swallows(key(escape, 0, "\u{1b}")))
        XCTAssertFalse(gate.swallows(key(aKey, 0, "a")))
        XCTAssertEqual(gate.hotKeys(), [])
    }

    func testHotKeysAreTheKeysTakenWhileASuggestionShows() {
        let hot = makeGate(.completion).hotKeys()
        XCTAssertEqual(hot, [.init(code: tab, modifiers: 0), .init(code: tab, modifiers: CompletionShortcut.shift),
                             .init(code: escape, modifiers: 0)])
        var leaving = makeGate(.completion)
        leaving.leaveTab = true
        XCTAssertEqual(leaving.hotKeys(), [.init(code: escape, modifiers: 0)])
        XCTAssertEqual(makeGate(.completion, active: false).hotKeys(), [])
    }

    /// Every hot key, pressed as it types on a US layout, is a key the controller takes in that state.
    func testEveryHotKeyIsSwallowed() {
        let digits = Dictionary(uniqueKeysWithValues: CompletionKeyGate.digitKeys.enumerated().map { ($1, "\($0 + 1)") })
        let characters: [Int: String] = [tab: "\t", escape: "\u{1b}", returnKey: "\r"].merging(digits) { a, _ in a }
        let cells = [CGRect(x: 0, y: 0, width: 36, height: 36)]
        for showing in [CompletionKeyGate.Showing.completion, .replacement, .alternatives(count: 3), .emoji(nameLength: 2, cells: cells)] {
            let gate = makeGate(showing)
            XCTAssertFalse(gate.hotKeys().isEmpty)
            for hot in gate.hotKeys() {
                XCTAssertTrue(gate.swallows(key(hot.code, hot.modifiers, characters[hot.code] ?? "")), "\(showing) \(hot)")
            }
        }
        XCTAssertEqual(makeGate(.alternatives(count: 2)).hotKeys().filter { digits[$0.code] != nil }.count, 4)
    }

    func testShortcutsAreHotKeysWhileInactive() {
        var gate = makeGate(.nothing, active: false)
        let shortcut = CompletionShortcut(keyCode: aKey, modifiers: CompletionShortcut.command | CompletionShortcut.option, label: "⌘⌥A")
        gate.toggleAll = shortcut
        XCTAssertEqual(gate.hotKeys(), [.init(code: aKey, modifiers: shortcut.modifiers)])
        gate.keysStayWithNook = true
        XCTAssertEqual(gate.hotKeys(), [])
    }

    func testInactiveOrNooksOwnKeysAreNeverSwallowed() {
        XCTAssertFalse(makeGate(.completion, active: false).swallows(key(tab, 0, "\t")))
        var gate = makeGate(.completion)
        gate.toggleAll = CompletionShortcut(keyCode: aKey, modifiers: CompletionShortcut.command | CompletionShortcut.option, label: "⌘⌥A")
        gate.keysStayWithNook = true
        XCTAssertFalse(gate.swallows(key(tab, 0, "\t")))
        XCTAssertFalse(gate.swallows(key(aKey, CompletionShortcut.command | CompletionShortcut.option, "a")))
    }

    func testShortcutsWorkEvenWhenInactive() {
        var gate = makeGate(.nothing, active: false)
        let shortcut = CompletionShortcut(keyCode: aKey, modifiers: CompletionShortcut.command | CompletionShortcut.option, label: "⌘⌥A")
        let press = key(aKey, CompletionShortcut.command | CompletionShortcut.option, "a")
        gate.toggleApp = shortcut
        XCTAssertTrue(gate.swallows(press))
        gate.appKnown = false
        XCTAssertFalse(gate.swallows(press))
        gate.alternatives = shortcut
        XCTAssertTrue(gate.swallows(press))
    }

    func testAlternativesTakeTheirNumbersAndEscape() {
        let gate = makeGate(.alternatives(count: 3))
        XCTAssertTrue(gate.swallows(key(digitOne, 0, "1")))
        XCTAssertFalse(gate.swallows(key(25, 0, "9")))
        XCTAssertTrue(gate.swallows(key(escape, 0, "\u{1b}")))
        XCTAssertFalse(gate.swallows(key(tab, 0, "\t")))
    }

    func testEmojiPicker() {
        let cells = [CGRect(x: 100, y: 200, width: 36, height: 36), CGRect(x: 136, y: 200, width: 36, height: 36)]
        let short = makeGate(.emoji(nameLength: 1, cells: cells))
        let named = makeGate(.emoji(nameLength: 2, cells: cells))
        XCTAssertTrue(short.swallows(key(leftArrow)))
        XCTAssertTrue(short.swallows(key(tab, 0, "\t")))
        XCTAssertTrue(short.swallows(key(digitOne, 0, "1")))
        XCTAssertTrue(short.swallows(key(digitOne, CompletionShortcut.shift, "1")))
        XCTAssertFalse(short.swallows(key(digitOne, CompletionShortcut.option, "1")))
        XCTAssertFalse(short.swallows(key(returnKey, 0, "\r")))
        XCTAssertTrue(named.swallows(key(returnKey, 0, "\r")))
        XCTAssertFalse(named.swallows(key(aKey, 0, "a")))
        XCTAssertEqual(named.emojiCell(at: CGPoint(x: 140, y: 210)), 1)
        XCTAssertNil(named.emojiCell(at: CGPoint(x: 20, y: 210)))
        XCTAssertNil(makeGate(.completion).emojiCell(at: CGPoint(x: 110, y: 210)))
    }
}
