import XCTest

final class TextKitTests: XCTestCase {
    func testFoldDropsCaseAndAccents() {
        XCTAssertEqual(TextKit.fold("Café ÜBERWEISUNG"), "cafe uberweisung")
    }

    func testTokensKeepContentWords() {
        let words = TextKit.tokens("The meeting about Café-plans, 42 and 7", stopwords: TextKit.stopwords)
        XCTAssertEqual(words, ["meeting", "cafe", "plans"])
        XCTAssertEqual(TextKit.tokens("about 42 and 7", stopwords: TextKit.stopwords, minNumberLength: 2), ["42"])
    }

    func testTokensStem() {
        XCTAssertEqual(TextKit.tokens("afspraken meetings", stem: true), ["afsprak", "meeting"])
        XCTAssertEqual(TextKit.stem("meetings"), "meeting")
        XCTAssertEqual(TextKit.stem("mail"), "mail")
    }

    func testSimilarity() {
        XCTAssertEqual(TextKit.similarity("Add the dentist appointment to your calendar", "Add dentist appointment to calendar", stopwords: TextKit.stopwords), 1)
        XCTAssertLessThan(TextKit.similarity("Reply to Lisa about dinner", "Merge the pull request"), 0.2)
        // Without content words, only the same text is alike.
        XCTAssertEqual(TextKit.similarity("ok", "OK"), 1)
        XCTAssertEqual(TextKit.similarity("ok", "no"), 0)
    }

    func testAsksQuestion() {
        XCTAssertTrue(TextKit.asksQuestion("Kom je morgen?"))
        XCTAssertTrue(TextKit.asksQuestion("¿Vienes mañana"))
        XCTAssertTrue(TextKit.asksQuestion("明天来吗？"))
        XCTAssertFalse(TextKit.asksQuestion("See you tomorrow."))
    }

    func testClip() {
        XCTAssertEqual(TextKit.clip("short", to: 10), "short")
        XCTAssertEqual(TextKit.clip("abcdefghij", to: 5), "abcd…")
        XCTAssertEqual(TextKit.clip("Fix the login bug, please", to: 12, wordBoundary: true), "Fix the…")
        XCTAssertLessThanOrEqual(TextKit.clip("Fix the login bug, please", to: 12, wordBoundary: true).count, 12)
        // No space in reach: cut where it is.
        XCTAssertEqual(TextKit.clip("Supercalifragilistic", to: 6, wordBoundary: true), "Super…")
        XCTAssertEqual(TextKit.clip("anything", to: 0), "")
    }
}
