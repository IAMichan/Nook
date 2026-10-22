import XCTest

/// Double Tap: the gesture, which fields may be filled, the prompt and how the brain's answer is read.
final class DoubleTapTests: XCTestCase {
    // MARK: Gesture

    func testTwoQuickTapsAreADoubleTap() {
        var gesture = DoubleTapGesture()
        XCTAssertFalse(gesture.update(down: true, alone: true, at: 10.00, lastKeyDown: 0))
        XCTAssertFalse(gesture.update(down: false, alone: true, at: 10.08, lastKeyDown: 0))
        XCTAssertFalse(gesture.update(down: true, alone: true, at: 10.25, lastKeyDown: 0))
        XCTAssertTrue(gesture.update(down: false, alone: true, at: 10.32, lastKeyDown: 0))
        // A third tap starts a new pair instead of firing again.
        XCTAssertFalse(gesture.update(down: true, alone: true, at: 10.5, lastKeyDown: 0))
        XCTAssertFalse(gesture.update(down: false, alone: true, at: 10.55, lastKeyDown: 0))
    }

    func testSlowTapsHoldsAndShortcutsAreNot() {
        var slow = DoubleTapGesture()
        _ = slow.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = slow.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = slow.update(down: true, alone: true, at: 0.9, lastKeyDown: -10)
        XCTAssertFalse(slow.update(down: false, alone: true, at: 1.0, lastKeyDown: -10), "too far apart")

        var hold = DoubleTapGesture()
        _ = hold.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = hold.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = hold.update(down: true, alone: true, at: 0.3, lastKeyDown: -10)
        XCTAssertFalse(hold.update(down: false, alone: true, at: 1.5, lastKeyDown: -10), "a hold is Flow's, not a tap")

        var shortcut = DoubleTapGesture()
        _ = shortcut.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = shortcut.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = shortcut.update(down: true, alone: true, at: 0.3, lastKeyDown: -10)
        XCTAssertFalse(shortcut.update(down: false, alone: true, at: 0.4, lastKeyDown: 0.35), "⌘C typed in between")

        var chord = DoubleTapGesture()
        _ = chord.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = chord.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        _ = chord.update(down: true, alone: false, at: 0.3, lastKeyDown: -10)
        XCTAssertFalse(chord.update(down: false, alone: true, at: 0.4, lastKeyDown: -10), "another modifier held")

        var interrupted = DoubleTapGesture()
        _ = interrupted.update(down: true, alone: true, at: 0, lastKeyDown: -10)
        _ = interrupted.update(down: false, alone: true, at: 0.1, lastKeyDown: -10)
        interrupted.interrupt()
        _ = interrupted.update(down: true, alone: true, at: 0.2, lastKeyDown: -10)
        XCTAssertFalse(interrupted.update(down: false, alone: true, at: 0.3, lastKeyDown: -10))
    }

    // MARK: Fields

    private func field(_ role: String, _ label: String, value: String = "", focused: Bool = false, secure: Bool = false,
                       source: Int = 0) -> DoubleTapField {
        DoubleTapField(id: 0, role: role, label: label, value: value, focused: focused, secure: secure, settable: true, source: source)
    }

    func testCandidatesSkipSecretsAndPutTheFocusFirst() {
        let fields = [
            field("field", "First name", source: 0),
            field("password", "Password", source: 1),
            field("field", "Card number", source: 2),
            field("field", "PIN", source: 3),
            field("field", "Spinach preference", source: 4),
            field("search", "Search", source: 5),
            field("textarea", "Message", focused: true, source: 6),
            field("field", "Login", secure: true, source: 7),
            field("field", "IBAN", source: 8)
        ]
        let candidates = DoubleTapLogic.candidates(fields)
        XCTAssertEqual(candidates.map(\.label), ["Message", "First name", "Spinach preference"])
        XCTAssertEqual(candidates.map(\.id), [1, 2, 3])
        XCTAssertEqual(candidates.map(\.source), [6, 0, 4], "the original place is kept for writing")
    }

    func testRoomOnlyWhenAFieldIsEmpty() {
        XCTAssertFalse(DoubleTapLogic.hasRoom([field("field", "Name", value: "Michan")]))
        XCTAssertTrue(DoubleTapLogic.hasRoom([field("field", "Name", value: "Michan"), field("field", "City", value: "  ")]))
    }

    func testPromptNamesFieldsFactsAndScreen() {
        let fields = DoubleTapLogic.candidates([field("field", "Email", focused: true), field("field", "Name", value: "Michan")])
        let prompt = DoubleTapLogic.prompt(app: "Safari", window: "Sign up", fields: fields, facts: ["Lives in Utrecht"],
                                           screen: "Create your account")
        XCTAssertTrue(prompt.contains("App: Safari — window: Sign up"))
        XCTAssertTrue(prompt.contains("[1] field \"Email\", empty ← cursor is here"))
        XCTAssertTrue(prompt.contains("[2] field \"Name\", contains \"Michan\""))
        XCTAssertTrue(prompt.contains("- Lives in Utrecht"))
        XCTAssertTrue(prompt.contains("Text on screen:\nCreate your account"))
    }

    // MARK: Answer

    func testValuesAreReadFailClosed() {
        let fields = DoubleTapLogic.candidates([
            field("field", "City", focused: true),
            field("field", "Name", value: "Michan"),
            field("textarea", "Motivation"),
            field("field", "Phone")
        ])
        let reply = """
        Sure! ```json
        {"fields": {"1": "Utrecht\\nNL", "2": "Someone else", "3": "I like building tools.\\nEvery day.", "4": 612345678, "9": "x"}}
        ```
        """
        let values = DoubleTapLogic.values(from: reply, fields: fields)
        XCTAssertEqual(values[1], "Utrecht NL", "a one-line field gets one line")
        XCTAssertNil(values[2], "never overwrite what is typed")
        XCTAssertEqual(values[3], "I like building tools.\nEvery day.")
        XCTAssertEqual(values[4], "612345678")
        XCTAssertNil(values[9], "a field that was not offered")

        XCTAssertEqual(DoubleTapLogic.values(from: "I can't help with that.", fields: fields), [:])
        XCTAssertEqual(DoubleTapLogic.values(from: "{\"fields\": {}}", fields: fields), [:])
        XCTAssertEqual(DoubleTapLogic.values(from: "{\"[1]\": \"Utrecht\"}", fields: fields), [1: "Utrecht"])
    }

    func testCardAndSocialSecurityNumbersAreDropped() {
        XCTAssertTrue(DoubleTapLogic.containsHighRiskNumber("4111 1111 1111 1111"))
        XCTAssertTrue(DoubleTapLogic.containsHighRiskNumber("card 4111-1111-1111-1111 ok"))
        XCTAssertTrue(DoubleTapLogic.containsHighRiskNumber("SSN 123-45-6789"))
        XCTAssertFalse(DoubleTapLogic.containsHighRiskNumber("06 1234 5678"))
        XCTAssertFalse(DoubleTapLogic.containsHighRiskNumber("4111 1111 1111 1112"), "not Luhn-valid")
        XCTAssertFalse(DoubleTapLogic.containsHighRiskNumber("Utrecht, 3511 AB"))

        let fields = DoubleTapLogic.candidates([field("field", "Notes", focused: true)])
        XCTAssertEqual(DoubleTapLogic.values(from: "{\"fields\": {\"1\": \"use 4111111111111111\"}}", fields: fields), [:])
    }
}
