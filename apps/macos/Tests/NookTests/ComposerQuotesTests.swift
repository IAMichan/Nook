import XCTest

final class ComposerQuotesTests: XCTestCase {
    func testQuotesGoInFrontOfTheMessageInOrder() {
        var quotes = ComposerQuotes()
        XCTAssertEqual(quotes.message("Why?"), "Why?")
        quotes.add("First passage\nsecond line")
        quotes.add("  Another one  ")
        XCTAssertEqual(quotes.message(" Why? "), "> First passage\n> second line\n\n> Another one\n\nWhy?")
        XCTAssertEqual(quotes.message(""), "> First passage\n> second line\n\n> Another one")
    }

    func testRefusalsAndDuplicates() {
        var quotes = ComposerQuotes()
        XCTAssertEqual(quotes.add("  \n"), .empty)
        XCTAssertEqual(quotes.add(String(repeating: "a", count: ComposerQuotes.characterLimit + 1)), .tooLong)
        XCTAssertEqual(quotes.add("same"), nil)
        XCTAssertEqual(quotes.add(" same "), nil)
        XCTAssertEqual(quotes.items.count, 1, "the same words are kept once")
        for index in 1..<ComposerQuotes.countLimit { quotes.add("q\(index)") }
        XCTAssertEqual(quotes.add("one too many"), .full)
    }

    func testRemove() {
        var quotes = ComposerQuotes()
        let id = UUID()
        quotes.add("keep")
        quotes.add("drop", id: id)
        quotes.remove(id)
        XCTAssertEqual(quotes.items.map(\.text), ["keep"])
        quotes.removeAll()
        XCTAssertTrue(quotes.isEmpty)
    }

    func testSelectionTextIsNormalizedAndTitled() {
        XCTAssertEqual(ComposerQuotes.normalize("\ta\u{2028}b\r\nc \n"), "a\nb\nc")
        XCTAssertEqual(ComposerQuotes.title("Short   words\nmore"), "Short words")
        let long = ComposerQuotes.title(String(repeating: "word ", count: 30))
        XCTAssertEqual(long.count, ComposerQuotes.titleLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: Reply to an answer

    func testReplyQuotesEveryLineAndKeepsOneEmptyLine() {
        XCTAssertEqual(AnswerReply.quote("  First line  \nsecond\n\n\n\nthird\n"), "> First line\n> second\n>\n> third")
        XCTAssertEqual(AnswerReply.quote(" \n "), "")
    }

    func testAReplyToALongAnswerIsCutOnAWordWithAnEllipsis() {
        let answer = String(repeating: "word ", count: 200)
        let quote = AnswerReply.quote(answer)
        XCTAssertTrue(quote.hasPrefix("> word word"))
        XCTAssertTrue(quote.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(quote.count, AnswerReply.characterLimit + 3)
        // One long word has no space to cut on: it is cut where the limit is.
        XCTAssertEqual(AnswerReply.quote(String(repeating: "a", count: 50), limit: 10), "> aaaaaaaaaa…")
    }

    func testReplyUsesTheSelectionOnlyWhenItIsPartOfTheAnswer() {
        let answer = "The **cache** is warm.\n\nRun `make` again."
        XCTAssertEqual(AnswerReply.source(answer: answer, selection: "cache is warm"), "cache is warm")
        XCTAssertEqual(AnswerReply.source(answer: answer, selection: "something else entirely"), answer)
        XCTAssertEqual(AnswerReply.source(answer: answer, selection: nil), answer)
        XCTAssertEqual(AnswerReply.source(answer: answer, selection: "  "), answer)
    }

    func testReplyGoesAboveTheDraftWithTheCaretUnderIt() {
        let empty = AnswerReply.inserting("> Done.", into: "")
        XCTAssertEqual(empty.text, "> Done.\n\n")
        XCTAssertEqual(empty.caret, empty.text.utf16.count)

        let typed = AnswerReply.inserting("> Done ✓", into: "\n  why?")
        XCTAssertEqual(typed.text, "> Done ✓\n\nwhy?")
        XCTAssertEqual(typed.caret, "> Done ✓\n\n".utf16.count)
        XCTAssertEqual(AnswerReply.inserting("", into: "draft").text, "draft")
    }

    func testAMessageThatStartsWithAQuoteSplitsIntoTheQuoteAndTheRest() throws {
        let split = try XCTUnwrap(AnswerReply.leadingQuote("> The cache is warm.\n>\n> Run it again.\n\nWhy is that?"))
        XCTAssertEqual(split.quote, "The cache is warm.\n\nRun it again.")
        XCTAssertEqual(split.rest, "Why is that?")
        XCTAssertEqual(AnswerReply.leadingQuote(">only quote")?.rest, "")
        XCTAssertNil(AnswerReply.leadingQuote("Plain words\n> a quote later"))
        XCTAssertNil(AnswerReply.leadingQuote(">\n>"))
        // What Reply puts in the composer reads back as the same quote.
        let quote = AnswerReply.quote("Line one\nLine two")
        XCTAssertEqual(AnswerReply.leadingQuote(AnswerReply.inserting(quote, into: "ok").text)?.quote, "Line one\nLine two")
    }
}
