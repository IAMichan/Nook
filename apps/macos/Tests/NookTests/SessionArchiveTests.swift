import XCTest

/// Every session's text on disk for Search everything (`SessionArchive`): what it finds for a query, what it brings back
/// of a session, and how a sync keeps it in step with the sessions and transcripts there are.
final class SessionArchiveTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func archive() throws -> SessionArchive {
        let archive = try XCTUnwrap(SessionArchive(url: folder.appendingPathComponent("session-search.sqlite")))
        try XCTSkipUnless(archive.searchAvailable, "this SQLite has no FTS5 trigram tokenizer")
        return archive
    }

    private func date(_ day: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(day) * 86_400) }

    private func passage(_ text: String, author: String = "me", day: Int = 1, anchor: String? = nil) -> SearchPassage {
        SearchPassage(text: text, author: author, date: date(day), anchor: anchor)
    }

    func testItFindsSessionsByAnyWordNewestFirst() throws {
        let archive = try archive()
        archive.save("past:old", stamp: 1, date: date(1), passages: [passage("We fixed the Café login form")])
        archive.save("past:new", stamp: 1, date: date(5), passages: [passage("The login page loads"), passage("Deploy it", author: "Claude Code")])
        archive.save("run:other", stamp: 1, date: date(3), passages: [passage("Nothing about that")])

        XCTAssertEqual(archive.candidates(SearchQuery.parse("login"), limit: 10), ["past:new", "past:old"])
        XCTAssertEqual(archive.candidates(SearchQuery.parse("cafe"), limit: 10), ["past:old"], "accents are folded")
        XCTAssertEqual(archive.candidates(SearchQuery.parse("ogi"), limit: 10), ["past:new", "past:old"], "a piece inside a word")
        XCTAssertEqual(archive.candidates(SearchQuery.parse("login deploy"), limit: 10), ["past:new"], "every word, anywhere in the session")
        XCTAssertEqual(archive.candidates(SearchQuery.parse("deploy OR nothing"), limit: 10), ["past:new", "run:other"])
        XCTAssertEqual(archive.candidates(SearchQuery.parse("login"), limit: 1), ["past:new"])
        XCTAssertNil(archive.candidates(SearchQuery.parse("in:chats login"), limit: 10), "a search without sessions asks nothing")
        XCTAssertNil(archive.candidates(SearchQuery.parse("is:settled"), limit: 10), "only filters: nothing to ask the index")
        XCTAssertNil(archive.candidates(SearchQuery.parse("go"), limit: 10), "under a trigram")
    }

    func testItBringsOnlyThePassagesThatHoldAWord() throws {
        let archive = try archive()
        let passages = [passage("Start with the parser", anchor: "a"), passage("Then lunch", day: 2),
                        passage("The parser is done", author: "Codex", day: 3, anchor: "c")]
        archive.save("past:x", stamp: 7, date: date(3), passages: passages)
        let found = archive.passages(["past:x", "past:missing"], for: SearchQuery.parse("parser"))
        XCTAssertEqual(found.keys.sorted(), ["past:x"])
        XCTAssertEqual(found["past:x"], [passages[0], passages[2]], "text, author, date and anchor come back as written")
        XCTAssertEqual(archive.stamps(), ["past:x": 7])
    }

    func testFoundChecksCandidatesUntilItHasEnough() throws {
        let archive = try archive()
        // Newest first: ten sessions that hold the trigrams of "parser" apart, then three that hold the word.
        for day in 0..<3 { archive.save("past:real\(day)", stamp: 1, date: date(day), passages: [passage("the parser \(day)")]) }
        for day in 10..<20 { archive.save("past:apart\(day)", stamp: 1, date: date(day), passages: [passage("par ars rse ser")]) }
        let found = try XCTUnwrap(archive.found(SearchQuery.parse("parser"), want: 2, batch: 4))
        XCTAssertEqual(found.map(\.key), ["past:real2", "past:real1"], "false hits are passed over, the newest real ones kept")
        let known = try XCTUnwrap(archive.found(SearchQuery.parse("parser"), want: 5) { $0 != "past:real2" })
        XCTAssertEqual(known.map(\.key), ["past:real1", "past:real0"], "sessions the caller does not know are left out")
    }

    func testWritingAgainReplacesAndRemovingForgets() throws {
        let archive = try archive()
        archive.save("past:x", stamp: 1, date: date(1), passages: [passage("first draft")])
        archive.save("past:x", stamp: 2, date: date(2), passages: [passage("second version")])
        XCTAssertEqual(archive.candidates(SearchQuery.parse("draft"), limit: 10), [], "the old text left the index")
        XCTAssertEqual(archive.candidates(SearchQuery.parse("version"), limit: 10), ["past:x"])
        XCTAssertEqual(archive.count, 1)
        archive.remove(["past:x"])
        XCTAssertEqual(archive.candidates(SearchQuery.parse("version"), limit: 10), [])
        XCTAssertEqual(archive.count, 0)

        // Kept across launches.
        archive.save("past:y", stamp: 1, date: date(1), passages: [passage("kept around")])
        let reopened = try XCTUnwrap(SessionArchive(url: folder.appendingPathComponent("session-search.sqlite")))
        XCTAssertEqual(reopened.candidates(SearchQuery.parse("kept"), limit: 10), ["past:y"])
        reopened.maintain()
    }

    func testPassagesAreSmallOnDisk() {
        let passages = (0..<200).map { passage("Ran the tests again, step \($0) of the migration", author: "Claude Code", day: $0, anchor: UUID().uuidString) }
        let packed = SessionArchive.pack(passages)
        XCTAssertEqual(SessionArchive.unpack(packed), passages)
        let plain = passages.map { $0.text + $0.author + ($0.anchor ?? "") }.joined().utf8.count
        XCTAssertLessThan(packed.count, plain, "compressed below the bare text")
    }

    func testASyncWritesWhatChangedNewestFirstAndForgetsWhatIsGone() {
        let old = run(updated: date(2)), fresh = run(updated: date(9))
        let transcripts = [
            SessionArchiveSync.Transcript(key: "past:a", path: "/a.jsonl", agent: "Claude Code", date: date(5)),
            SessionArchiveSync.Transcript(key: "past:b", path: "/b.jsonl", agent: "Codex", date: date(7)),
            SessionArchiveSync.Transcript(key: "past:gone", path: "/gone.jsonl", agent: "Codex", date: date(8)),
        ]
        let files = ["/a.jsonl": date(5), "/b.jsonl": date(7)]
        let stored = ["run:" + old.id.uuidString: date(2).timeIntervalSinceReferenceDate,
                      "past:a": date(4).timeIntervalSinceReferenceDate,
                      "past:gone": 1, "past:deleted": 1]
        let plan = SessionArchiveSync.plan(runs: [old, fresh], transcripts: transcripts, stored: stored, modified: { files[$0] })
        XCTAssertEqual(plan.changed.map(\.key), ["run:" + fresh.id.uuidString, "past:b", "past:a"],
                       "new and changed ones, newest first; the old run is as written")
        XCTAssertEqual(plan.gone, ["past:deleted", "past:gone"], "a deleted session and a transcript whose file is gone")
    }

    private func run(updated: Date) -> WorkspaceRun {
        WorkspaceRun(id: UUID(), title: "t", task: "t", provider: .claude, profileID: "p", model: "", resolvedModel: nil,
                     mode: .agent, permission: .acceptEdits, isolation: .folder, projectPath: "/w", workingDirectory: "/w",
                     repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil, instructions: "", status: .completed,
                     statusDetail: nil, providerSessionID: nil, createdAt: updated, updatedAt: updated, archived: false,
                     usage: RunUsage(), turnStartedAt: nil, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil)
    }

    func testASearchKeepsOnlyPassagesWithItsWords() {
        let filter = SearchArchiveFilter(SearchQuery.parse("parser OR lexer -lunch"))
        XCTAssertTrue(filter.keeps(passage("Fixed the Parser")))
        XCTAssertTrue(filter.keeps(passage("the lexer too")))
        XCTAssertFalse(filter.keeps(passage("Then lunch")))
        XCTAssertTrue(SearchArchiveFilter(SearchQuery.parse("is:settled")).keeps(passage("anything")))
    }
}

/// Measures the archive on this Mac's real transcripts: `NOOK_SESSION_ARCHIVE_BENCH=<folder> scripts/core-tests.sh
/// --filter SessionArchiveBenchTests`. Writes the archive into that folder and prints only counts, sizes and times.
final class SessionArchiveBenchTests: XCTestCase {
    func testRealTranscripts() throws {
        guard let out = ProcessInfo.processInfo.environment["NOOK_SESSION_ARCHIVE_BENCH"] else { throw XCTSkip("bench only") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files: [(String, String)] = []
        for (folder, agent, suffix) in [(".claude/projects", "Claude Code", ".jsonl"), (".codex/sessions", "Codex", ".jsonl"),
                                        (".gemini/tmp", "Gemini CLI", ".json")] {
            let root = home.appendingPathComponent(folder)
            let walker = FileManager.default.enumerator(atPath: root.path)
            while let path = walker?.nextObject() as? String {
                if path.hasSuffix(suffix) { files.append((root.appendingPathComponent(path).path, agent)) }
            }
        }
        let url = URL(fileURLWithPath: out).appendingPathComponent("session-search.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let archive = try XCTUnwrap(SessionArchive(url: url))
        var started = Date()
        var passages = 0, textBytes = 0, sessions = 0
        for (index, file) in files.enumerated() {
            autoreleasepool {
                let messages = AgentTranscript.recent(path: file.0, limit: SessionArchiveSync.messageLimit, remember: false, whole: true)
                let found = SessionPassages.make(messages, agent: file.1, limit: SessionArchiveSync.passageLimit)
                guard !found.isEmpty else { return }
                sessions += 1
                passages += found.count
                textBytes += found.reduce(0) { $0 + $1.text.utf8.count }
                archive.save("past:\(index)", stamp: 1, date: Date(timeIntervalSinceReferenceDate: Double(index)), passages: found)
            }
        }
        let build = Date().timeIntervalSince(started)
        archive.maintain()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        print("BENCH files \(files.count) sessions \(sessions) passages \(passages) text \(textBytes / 1_048_576) MB")
        print("BENCH archive \(size / 1_048_576) MB, built in \(Int(build)) s")
        for word in ["login", "migration", "the", "zoeken", "sqlite fts5", "xyzzyq"] {
            started = Date()
            let query = SearchQuery.parse(word)
            let keys = archive.candidates(query, limit: 5_000) ?? []
            let found = archive.found(query, want: 200) ?? []
            let documents = found.map { SearchDocument(id: $0.key, kind: .session, title: "", passages: $0.passages) }
            let hits = SearchIndex(documents).search(query, limit: 200)
            print("BENCH query '\(word)': \(keys.count) candidates, \(found.count) sessions, \(hits.count) hits, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
    }
}
