import XCTest

final class SelectionAskTests: XCTestCase {
    func testOnlyWordsAreOffered() {
        XCTAssertNil(SelectionAsk.offered("   \n"))
        XCTAssertNil(SelectionAsk.offered("a"), "a single character is a stray click")
        XCTAssertNil(SelectionAsk.offered(" — ? "), "punctuation alone is nothing to ask about")
        XCTAssertEqual(SelectionAsk.offered("  Hoe laat begint het?\u{2028}Morgen  "), "Hoe laat begint het?\nMorgen")
        XCTAssertEqual(SelectionAsk.offered("42"), "42")
    }

    func testLongSelectionsAreCut() throws {
        let long = String(repeating: "word ", count: SelectionAsk.characterLimit)
        let offered = try XCTUnwrap(SelectionAsk.offered(long))
        XCTAssertLessThanOrEqual(offered.count, SelectionAsk.characterLimit)
        XCTAssertTrue(offered.hasSuffix("…"))
    }

    func testMessageQuotesTheSelectionAboveTheRequest() {
        let message = SelectionAsk.message("Can you send the slides?\nBefore Friday", mode: .answer)
        XCTAssertTrue(message.hasPrefix("> Can you send the slides?\n> Before Friday\n\n"))
        XCTAssertTrue(message.hasSuffix(SelectionAsk.Mode.answer.instruction))
        XCTAssertNotEqual(SelectionAsk.Mode.explain.instruction, SelectionAsk.Mode.translate.instruction)
    }

    func testADragPicksTheMessagesFromItsStartToThePointer() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(SelectionAsk.picked(from: "c", to: "a", in: order), ["a", "b", "c"], "dragged up")
        XCTAssertEqual(SelectionAsk.picked(from: "b", to: "c", in: order), ["b", "c"], "dragged down")
        XCTAssertEqual(SelectionAsk.picked(from: "b", to: "b", in: order), [], "still on its first message: its own text")
        XCTAssertEqual(SelectionAsk.picked(from: "x", to: "b", in: order), [])
    }

    func testThePointerFindsTheNearestMessage() {
        let frames: [(id: String, frame: CGRect)] = [("a", CGRect(x: 0, y: 0, width: 300, height: 40)),
                                                      ("b", CGRect(x: 0, y: 50, width: 300, height: 40))]
        XCTAssertEqual(SelectionAsk.nearest(to: 20, in: frames), "a")
        XCTAssertEqual(SelectionAsk.nearest(to: 47, in: frames), "b", "in the gap: the closer one")
        XCTAssertEqual(SelectionAsk.nearest(to: -30, in: frames), "a", "above the chat: its first message")
        XCTAssertEqual(SelectionAsk.nearest(to: 500, in: frames), "b")
        XCTAssertNil(SelectionAsk.nearest(to: 0, in: []))
    }

    func testTheChatAroundASelectionGoesWithIt() {
        XCTAssertEqual(SelectionAsk.contextRange(first: 30, last: 30, count: 40), 10...33)
        XCTAssertEqual(SelectionAsk.contextRange(first: 2, last: 5, count: 6), 0...5, "kept inside the chat")
        let note = SelectionAsk.chatNote(contact: "Anna", transcript: "[09:54] You: Is analytics easy in AWS?", you: "You")
        XCTAssertTrue(note.contains("chat with Anna"))
        XCTAssertTrue(note.hasSuffix("[09:54] You: Is analytics easy in AWS?"))
    }

    func testOnlyDeliberateSelectionsBringTheBar() {
        XCTAssertFalse(SelectionAsk.isDeliberate(down: .zero, up: CGPoint(x: 1, y: 2), clicks: 1), "a plain click")
        XCTAssertTrue(SelectionAsk.isDeliberate(down: .zero, up: CGPoint(x: 40, y: 0), clicks: 1), "a drag")
        XCTAssertTrue(SelectionAsk.isDeliberate(down: .zero, up: .zero, clicks: 2), "a double click selects a word")
    }

    func testBarSitsAboveTheSelectionInsideTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 36)
        let above = SelectionAsk.origin(for: size, anchor: CGRect(x: 400, y: 300, width: 100, height: 20), visible: screen)
        XCTAssertEqual(above, CGPoint(x: 350, y: 328))
        // No room above: below the selection.
        let below = SelectionAsk.origin(for: size, anchor: CGRect(x: 400, y: 770, width: 100, height: 20), visible: screen)
        XCTAssertEqual(below.y, 770 - 8 - 36)
        // At the edge: kept on the screen.
        let edge = SelectionAsk.origin(for: size, anchor: CGRect(x: 990, y: 300, width: 4, height: 20), visible: screen)
        XCTAssertEqual(edge.x, 1000 - 200 - 8)
        // The card goes under the selection, above it when the screen ends there.
        let card = CGSize(width: 400, height: 300)
        XCTAssertEqual(SelectionAsk.origin(for: card, anchor: CGRect(x: 400, y: 500, width: 100, height: 20), visible: screen,
                                           below: true).y, 500 - 8 - 300)
        XCTAssertEqual(SelectionAsk.origin(for: card, anchor: CGRect(x: 400, y: 100, width: 100, height: 20), visible: screen,
                                           below: true).y, 128)
    }
}
