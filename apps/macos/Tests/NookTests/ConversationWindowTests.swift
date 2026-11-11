import XCTest

final class ConversationWindowTests: XCTestCase {
    private let long = Array(repeating: "word", count: 200).joined(separator: " ")  // 999 characters

    private func conversation(_ count: Int, text: (Int) -> String) -> [ChatTurn] {
        (0..<count).map { ChatTurn(fromUser: $0 % 2 == 0, text: text($0)) }
    }

    func testAShortConversationGoesAsItIs() {
        let turns = conversation(4) { "turn \($0)" }
        let window = ConversationWindow.fit(turns)
        XCTAssertEqual(window.map(\.text), turns.map(\.text))
        XCTAssertEqual(window.map(\.fromUser), turns.map(\.fromUser))
    }

    func testEmptyTurnsAreLeftOut() {
        let window = ConversationWindow.fit([ChatTurn(fromUser: true, text: "  \n"), ChatTurn(fromUser: false, text: "hi")])
        XCTAssertEqual(window.map(\.text), ["hi"])
    }

    func testTheNewestTurnsStayWholeAndOlderOnesAreShortened() {
        let window = ConversationWindow.fit(conversation(10) { _ in long })
        XCTAssertEqual(window.count, 10)
        for turn in window.prefix(4) {
            XCTAssertLessThanOrEqual(turn.text.count, ConversationWindow.Limits.standard.shortLength)
            XCTAssertTrue(turn.text.hasSuffix("…"))
        }
        for turn in window.suffix(6) {
            XCTAssertEqual(turn.text, long, "the six newest turns are sent in full")
        }
    }

    func testTurnsBeyondTheWindowBecomeARecapOfWhatWasAsked() {
        let window = ConversationWindow.fit(conversation(30) { $0 % 2 == 0 ? "q\($0)" : "a\($0)" })
        XCTAssertEqual(window.count, ConversationWindow.Limits.standard.maxTurns)
        let first = window[0]
        XCTAssertTrue(first.fromUser)
        XCTAssertTrue(first.text.hasPrefix("[Earlier in this conversation"))
        XCTAssertTrue(first.text.contains("- q0"), "the question the conversation started with is kept")
        XCTAssertTrue(first.text.contains("- q8"))
        XCTAssertFalse(first.text.contains("a1"), "answers are not repeated in the recap")
        XCTAssertTrue(first.text.hasSuffix("q10"), "the recap joins the first user turn of the window")
        XCTAssertEqual(window.last?.text, "a29")
    }

    func testARecapOfManyQuestionsKeepsTheFirstAndTheLatest() throws {
        let dropped = (0..<20).map { ChatTurn(fromUser: true, text: "q\($0)") }
        let recap = try XCTUnwrap(ConversationWindow.recap(of: dropped))
        let lines = recap.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.dropFirst().dropLast()), ["- q0", "- q1", "- q2", "- … 14 more", "- q17", "- q18", "- q19"])
    }

    func testNoRecapWithoutEarlierQuestions() {
        XCTAssertNil(ConversationWindow.recap(of: [ChatTurn(fromUser: false, text: "answer")]))
    }

    func testTheWindowStaysWithinItsBudget() {
        var limits = ConversationWindow.Limits.standard
        limits.budget = 2_000
        let window = ConversationWindow.fit(conversation(10) { _ in long }, limits: limits)
        XCTAssertLessThanOrEqual(window.reduce(0) { $0 + $1.text.count }, limits.budget)
        XCTAssertEqual(window.count, 2, "the recap made room by folding the oldest kept turn into it")
        XCTAssertTrue(window[0].fromUser, "the window starts on the user's side")
        XCTAssertTrue(window[0].text.hasPrefix("[Earlier in this conversation"))
        XCTAssertEqual(window[1].text, long)
    }

    func testTheNewestTurnAlwaysComesAlongCutToTheBudget() {
        var limits = ConversationWindow.Limits.standard
        limits.budget = 500
        let window = ConversationWindow.fit([ChatTurn(fromUser: false, text: long)], limits: limits)
        XCTAssertEqual(window.count, 1)
        XCTAssertLessThanOrEqual(window[0].text.count, 500)
        XCTAssertTrue(window[0].text.hasSuffix("…"))
    }

    func testShortenedCutsAtAWord() {
        XCTAssertEqual(ConversationWindow.shortened("hello world", to: 20), "hello world")
        XCTAssertEqual(ConversationWindow.shortened("hello world", to: 9), "hello…")
        XCTAssertEqual(ConversationWindow.shortened("abcdefghij", to: 5), "abcd…")
    }
}
