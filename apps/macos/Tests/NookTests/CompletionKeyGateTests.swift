import XCTest

/// The key tap's decision on its own thread (`CompletionKeyGate`) must match what the controller does with a key.
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

    func testNothingShowingHoldsAcceptKeyOnlyWhenASuggestionIsComing() {
        var gate = makeGate(.nothing)
        XCTAssertFalse(gate.swallows(key(tab, 0, "\t")))
        XCTAssertTrue(gate.mayHold(key(tab, 0, "\t")))
        gate.canHold = true
        XCTAssertTrue(gate.swallows(key(tab, 0, "\t")))
        XCTAssertFalse(gate.swallows(key(escape, 0, "\u{1b}")))
        XCTAssertFalse(gate.swallows(key(aKey, 0, "a")))
    }

    func testInactiveOrNooksOwnKeysAreNeverSwallowed() {
        XCTAssertFalse(makeGate(.completion, active: false).swallows(key(tab, 0, "\t")))
        XCTAssertFalse(makeGate(.nothing, active: false).mayHold(key(tab, 0, "\t")))
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
