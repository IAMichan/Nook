import XCTest

/// The search index over every session's timeline: it names the sessions that mention a piece of text, the way "Find in
/// session" matches it (any three or more characters, case and diacritics ignored), and stays in step with each save.
final class RunSearchIndexTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func event(_ text: String, kind: RunEvent.Kind = .assistant, output: String? = nil) -> RunEvent {
        var event = RunEvent(kind: kind, text: text, date: Date(timeIntervalSince1970: 1_700_000_000))
        event.output = output
        return event
    }

    func testTheLogFindsSessionsByAnyPieceOfTheirText() throws {
        let log = try XCTUnwrap(RunEventLog(url: folder.appendingPathComponent("runs.sqlite")))
        try XCTSkipUnless(log.searchAvailable, "this SQLite has no FTS5 trigram tokenizer: search scans instead")
        let first = UUID(), second = UUID()
        log.reindex(first, TimelineSearchText.entries([event("Fixed the Café login"), event("npm test", kind: .tool, output: "42 passing")]))
        log.reindex(second, TimelineSearchText.entries([event("Nothing about it")]))
        XCTAssertEqual(log.sessions(mentioning: "ogin"), [first], "a piece inside a word, as Find in session matches")
        XCTAssertEqual(log.sessions(mentioning: "CAFE"), [first], "case and accents are ignored")
        XCTAssertEqual(log.sessions(mentioning: "passing"), [first], "tool output counts")
        XCTAssertEqual(log.sessions(mentioning: "about it"), [second])
        XCTAssertEqual(log.sessions(mentioning: "missing words"), [])
        XCTAssertNil(log.sessions(mentioning: "it"), "under three characters the index cannot answer")
        XCTAssertEqual(log.sessions(mentioning: #"say "hi" OR x"#), [], "the query is literal text, never FTS syntax")
    }

    func testAnUpdatedEventReplacesItsTextAndThinkingIsLeftOut() throws {
        let log = try XCTUnwrap(RunEventLog(url: folder.appendingPathComponent("runs.sqlite")))
        try XCTSkipUnless(log.searchAvailable)
        let id = UUID()
        var answer = event("Working on the parser")
        log.index(id, TimelineSearchText.entries([answer, event("secret plan", kind: .thinking)]))
        XCTAssertEqual(log.sessions(mentioning: "parser"), [id])
        XCTAssertEqual(log.sessions(mentioning: "secret plan"), [], "thinking is not searched, as in Find in session")
        answer.text = "Done with the lexer"
        log.index(id, TimelineSearchText.entries([answer]))
        XCTAssertEqual(log.sessions(mentioning: "parser"), [], "the old text of an updated event is gone")
        XCTAssertEqual(log.sessions(mentioning: "lexer"), [id])
        log.removeIndex(id)
        XCTAssertEqual(log.sessions(mentioning: "lexer"), [])
    }

    func testTheStoreIndexesWhatItSavesAndForgetsWhatItDeletes() throws {
        let store = RunStore(directory: folder)
        _ = store.loadRuns()
        store.flush()
        let id = UUID()
        try store.saveEvents(id, [event("Refactor the tokenizer")])
        store.appendEvent(id, event("Then ship it"))
        guard let found = store.sessions(mentioning: "tokenizer") else {
            throw XCTSkip("no FTS5 trigram tokenizer in this SQLite")
        }
        XCTAssertEqual(found, [id])
        XCTAssertEqual(store.sessions(mentioning: "ship it"), [id])
        store.deleteEvents(id)
        XCTAssertEqual(store.sessions(mentioning: "tokenizer"), [])
    }
}
