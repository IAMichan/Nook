import XCTest

final class TerminalLinksTests: XCTestCase {
    private func texts(_ line: String) -> [String] { TerminalLinks.extract(line).map(\.text) }

    func testURLsDropSentencePunctuationAndUnopenedBrackets() {
        XCTAssertEqual(texts("Local: http://localhost:5173/, ready."), ["http://localhost:5173/"])
        XCTAssertEqual(texts("(see https://example.com/a_(b))."), ["https://example.com/a_(b)"])
        XCTAssertEqual(TerminalLinks.extract("go https://x.dev now").first?.kind, .url)
    }

    func testCompilerPathsKeepTheirPosition() {
        let matches = TerminalLinks.extract("src/app/main.swift:12:5: error: boom")
        XCTAssertEqual(matches.map(\.text), ["src/app/main.swift:12:5"])
        XCTAssertEqual(matches.first?.kind, .path)
        XCTAssertEqual(matches.first?.start, 0)
        XCTAssertEqual(texts("at ./lib/x.js:3"), ["./lib/x.js:3"])
        XCTAssertEqual(texts("wrote ~/notes/today.md."), ["~/notes/today.md"])
    }

    func testQuotedPathsMayHoldSpaces() {
        XCTAssertEqual(texts(#"open "My Folder/read me.txt":4 please"#), ["My Folder/read me.txt:4"])
    }

    func testURLsAreNotAlsoPaths() {
        XCTAssertEqual(TerminalLinks.extract("https://example.com/a/b").map(\.kind), [.url])
    }

    func testRequestLinesWithAQueryAreNotPaths() {
        XCTAssertEqual(texts("GET /api/users?id=3 200 12ms"), [])
        XCTAssertEqual(texts("GET /api/users 200"), ["/api/users"])
    }

    func testPlainWordsAreNotLinks() {
        XCTAssertEqual(texts("Compiling 12 files and/or modules"), ["and/or"])
        XCTAssertEqual(texts("nothing to see here"), [])
    }

    func testLinkUnderColumnAndLocalAddresses() {
        let line = "ready on http://127.0.0.1:3000 ok"
        XCTAssertEqual(TerminalLinks.link(in: line, at: 12)?.text, "http://127.0.0.1:3000")
        XCTAssertNil(TerminalLinks.link(in: line, at: 2))
        XCTAssertTrue(TerminalLinks.isLocal(URL(string: "http://app.localhost:8080")!))
        XCTAssertFalse(TerminalLinks.isLocal(URL(string: "https://example.com")!))
    }
}
