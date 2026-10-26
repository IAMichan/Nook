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
}
