import XCTest

/// The phone's Foundation-only logic (`apps/ios/Core`): dictation languages and text, diagrams and math in messages, and
/// where a comment on a line of a pull request's diff lands.
final class PhoneCoreTests: XCTestCase {
    // MARK: Dictation

    func testOfferedLanguagesFollowYourOrderAndMatchTheRecognizer() {
        let offered = DictationLanguages.offered(preferred: ["nl_NL", "en-GB", "nl"], supported: ["en-US", "nl-NL", "de-DE"])
        XCTAssertEqual(offered, ["nl-NL", "en-US"])
    }

    func testPickKeepsTheSavedLanguageOnlyWhileOffered() {
        XCTAssertEqual(DictationLanguages.pick(saved: "en_us", offered: ["nl-NL", "en-US"]), "en-US")
        XCTAssertEqual(DictationLanguages.pick(saved: "fr-FR", offered: ["nl-NL", "en-US"]), "nl-NL")
        XCTAssertNil(DictationLanguages.pick(saved: nil, offered: []))
    }

    func testMergeJoinsWhatWasHeardToWhatWasTyped() {
        XCTAssertEqual(DictationText.merge(base: "", heard: " hello "), "hello")
        XCTAssertEqual(DictationText.merge(base: "Fix", heard: "the bug"), "Fix the bug")
        XCTAssertEqual(DictationText.merge(base: "Fix\n", heard: "the bug"), "Fix\nthe bug")
        XCTAssertEqual(DictationText.merge(base: "Fix", heard: ", then ship"), "Fix, then ship")
        XCTAssertEqual(DictationText.merge(base: "Fix", heard: "  "), "Fix")
    }

    // MARK: Diagrams and math

    func testPlainMessagesAreNotParsed() {
        XCTAssertFalse(MessageSegments.mayBeRich("Just words."))
        XCTAssertEqual(MessageSegments.split("Just words."), [.text("Just words.")])
    }

    func testMermaidAndMathFencesBecomeSegments() {
        let text = "Before\n```mermaid\ngraph TD\nA-->B\n```\nAfter\n$$\nx^2\n$$\n"
        let segments = MessageSegments.split(text)
        XCTAssertTrue(segments.contains(.mermaid("graph TD\nA-->B")))
        XCTAssertTrue(segments.contains(.math("x^2")))
        XCTAssertTrue(segments.contains(.text("Before")))
    }

    func testMoneyIsNotMath() {
        let pieces = MessageSegments.inlinePieces("It costs $5 and $10 today")
        XCTAssertFalse(pieces.contains { $0.math })
        let math = MessageSegments.inlinePieces("Energy is $E=mc^2$ here")
        XCTAssertEqual(math.filter(\.math).map(\.text), ["E=mc^2"])
    }

    func testRichPageEscapesAndStaysOffline() throws {
        let html = try XCTUnwrap(RichPage.html(.mermaid("A<b>\"")))
        XCTAssertTrue(html.contains("A&lt;b&gt;&quot;"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("http://") || html.contains("https://"))
        XCTAssertNil(RichPage.html(.text("plain")))
    }

    // MARK: Comment positions in a diff

    func testPositionsFollowTheHunkNumbers() {
        let lines = ["@@ -10,3 +20,3 @@ func", " keep", "-old", "+new", " tail", "\\ No newline at end of file"]
        let positions = PatchPositions.positions(lines)
        XCTAssertNil(positions[0])
        XCTAssertEqual(positions[1]?.line, 20)
        XCTAssertEqual(positions[2], .init(line: 11, side: "LEFT"))
        XCTAssertEqual(positions[3], .init(line: 21, side: "RIGHT"))
        XCTAssertEqual(positions[4], .init(line: 22, side: "RIGHT"))
        XCTAssertNil(positions[5])
    }

    func testCommentOnARangeStartsOnTheSameSide() throws {
        let lines = ["@@ -1,2 +1,3 @@", " a", "+b", "+c"]
        let positions = PatchPositions.positions(lines)
        let comment = try XCTUnwrap(PatchPositions.comment(path: "f.swift", picked: 2...3, positions: positions, body: "why"))
        XCTAssertEqual(comment.line, 3)
        XCTAssertEqual(comment.startLine, 2)
        XCTAssertEqual(comment.side, "RIGHT")
        XCTAssertNil(PatchPositions.comment(path: "f", picked: 0...0, positions: positions, body: "x"))
    }
}
