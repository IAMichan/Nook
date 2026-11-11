import SQLite3
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

    func testAnIndexThatKeptTheTextIsBuiltAgainWithoutIt() throws {
        let url = folder.appendingPathComponent("runs.sqlite")
        try XCTSkipUnless(sqlite3_libversion_number() >= 3_043_000, "older SQLite keeps the index it has")
        // As written before 2026-11-10: FTS5 kept its own copy of every event's text.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE VIRTUAL TABLE run_search USING fts5(body, tokenize = 'trigram');
            CREATE TABLE run_search_keys (id INTEGER PRIMARY KEY, run_id TEXT NOT NULL, event_id TEXT NOT NULL, UNIQUE (run_id, event_id));
            INSERT INTO run_search_keys (id, run_id, event_id) VALUES (1, 'old', 'old');
            INSERT INTO run_search (rowid, body) VALUES (1, 'stale text');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let log = try XCTUnwrap(RunEventLog(url: url))
        try XCTSkipUnless(log.searchAvailable)
        XCTAssertEqual(log.sessions(mentioning: "stale"), [], "the old index and its keys are gone, to be built anew")
        let id = UUID()
        log.reindex(id, TimelineSearchText.entries([event("Fixed the parser"), event("Then the lexer")]))
        XCTAssertEqual(log.sessions(mentioning: "parser"), [id])
        log.index(id, TimelineSearchText.entries([event("Fixed the parser")]))
        log.removeIndex(id)
        XCTAssertEqual(log.sessions(mentioning: "lexer"), [], "rows are removed from the contentless index too")

        // Reopened, the new index stays: it is not dropped and built again on every launch.
        log.reindex(id, TimelineSearchText.entries([event("Kept across launches")]))
        let reopened = try XCTUnwrap(RunEventLog(url: url))
        XCTAssertEqual(reopened.sessions(mentioning: "across"), [id])
        XCTAssertFalse(reopened.compact(), "a little free room is left alone")
        XCTAssertTrue(reopened.compact(over: -1))
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

    func testReplacingOneEventStaysCheapInALargeIndex() throws {
        let log = try XCTUnwrap(RunEventLog(url: folder.appendingPathComponent("runs.sqlite")))
        try XCTSkipUnless(log.searchAvailable)
        // Hundreds of sessions, as on a Mac that used Nook for months.
        var last = UUID()
        for _ in 0..<200 {
            last = UUID()
            log.reindex(last, TimelineSearchText.entries((0..<50).map { event("Step \($0) of the long migration") }))
        }
        var answer = event("Streaming the first words")
        let started = Date()
        // A streamed answer saves the same event again and again.
        for count in 0..<300 {
            answer.text = "Streaming word \(count)"
            XCTAssertTrue(log.index(last, TimelineSearchText.entries([answer])))
        }
        // Looking an event up by scanning the whole index took seconds here; by its key it takes milliseconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(log.sessions(mentioning: "word 299"), [last])
        XCTAssertEqual(log.sessions(mentioning: "word 298"), [])
    }

    func testAnEventWhoseTextIsGoneLeavesTheIndex() throws {
        let log = try XCTUnwrap(RunEventLog(url: folder.appendingPathComponent("runs.sqlite")))
        try XCTSkipUnless(log.searchAvailable)
        let id = UUID()
        var answer = event("Temporary words")
        log.index(id, TimelineSearchText.entries([answer]))
        answer.text = ""
        log.index(id, TimelineSearchText.entries([answer]))
        XCTAssertEqual(log.sessions(mentioning: "Temporary"), [])
        answer.text = "Back again"
        log.index(id, TimelineSearchText.entries([answer]))
        XCTAssertEqual(log.sessions(mentioning: "back again"), [id])
    }

    func testTheFirstIndexIsDroppedAndSessionsAreIndexedAnew() throws {
        let url = folder.appendingPathComponent("runs.sqlite")
        let id = UUID()
        do {
            let log = try XCTUnwrap(RunEventLog(url: url))
            try XCTSkipUnless(log.searchAvailable)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(event("Written before the new index"))
            XCTAssertNotNil(log.append(id, .event, payload))
            // The first index, marked as built by an earlier version.
            XCTAssertTrue(log.exec("CREATE VIRTUAL TABLE run_text USING fts5(run_id UNINDEXED, event_id UNINDEXED, body, tokenize = 'trigram');"))
            log.setMeta("search_index_built", "2026-11-01T00:00:00Z")
        }
        let store = RunStore(directory: folder)
        _ = store.loadRuns()
        store.flush()
        XCTAssertEqual(store.sessions(mentioning: "before the new"), [id], "the new index is built from the log")
        let log = try XCTUnwrap(RunEventLog(url: url))
        XCTAssertFalse(log.exec("SELECT 1 FROM run_text;"), "the first index is gone")
    }
}
