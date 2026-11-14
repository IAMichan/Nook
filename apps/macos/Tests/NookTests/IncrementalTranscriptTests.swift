import XCTest

/// Transcripts that grow are read on from where the last read stopped (the live view and the history scan). These check
/// that reading a file in two parts gives exactly what reading it at once gives, for every agent read that way.
final class IncrementalTranscriptTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("incremental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    /// Gemini CLI 0.33+: metadata, messages, patches (content, tool results, removal, reordering), a rewind and a $set.
    private let geminiLines = [
        #"{"sessionId":"s1","projectHash":"abc","startTime":"2026-10-29T10:00:00.000Z","lastUpdated":"2026-10-29T10:00:00.000Z","kind":"main"}"#,
        #"{"id":"u1","timestamp":"2026-10-29T10:00:01.000Z","type":"user","content":[{"text":"Fix the login"}]}"#,
        #"{"id":"g1","timestamp":"2026-10-29T10:00:02.000Z","type":"gemini","content":"","model":"gemini-3-pro","toolCalls":[{"id":"t1","name":"read_file","args":{"file_path":"a.swift"},"status":"success"}]}"#,
        #"{"$patch":{"id":"g1","content":"Done.","toolCalls":[{"id":"t1","result":[{"text":"ok"}]}]}}"#,
        #"{"id":"u2","type":"user","content":"and the logout"}"#,
        #"{"id":"g2","type":"gemini","content":"Working","thoughts":[{"subject":"Plan","description":"Look first"}]}"#,
        #"{"id":"u3","type":"user","content":"never mind"}"#,
        #"{"$patch":{"removeIds":["u3"],"orderIds":["g2","u2"],"updates":[{"id":"g2","content":"Working on it"}]}}"#,
        #"{"id":"u4","type":"user","content":"one more"}"#,
        #"{"$rewindTo":"u4"}"#,
        #"{"$set":{"lastUpdated":"2026-10-29T10:05:00.000Z","directories":["/Users/me/app"]}}"#,
        #"{"id":"g3","type":"gemini","content":"All set.","tokens":{"input":10,"output":5,"cached":2}}"#,
    ]

    /// Cursor's CLI: Claude Code's blocks under "role", without ids (each line is numbered instead).
    private let cursorLines = [
        #"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nAdd a test\n</user_query>"}]}}"#,
        #"{"role":"assistant","message":{"content":[{"type":"text","text":"Looking at the tests."}]}}"#,
        #"{"role":"assistant","message":{"content":[{"type":"tool_use","id":"c1","name":"Read","input":{"file_path":"/app/a.swift"}}]}}"#,
        #"{"role":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"ok"}]}}"#,
        "",
        #"{"role":"assistant","message":{"content":[{"type":"text","text":"Added it."}]}}"#,
        #"{"role":"user","message":{"content":[{"type":"text","text":"Thanks"}]}}"#,
    ]

    /// Antigravity's transcript.jsonl.
    private let antigravityLines = [
        #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-16T13:35:32Z","content":"<USER_REQUEST>\nFind the bug\n</USER_REQUEST>"}"#,
        #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-16T13:35:33Z","input_tokens":100,"output_tokens":50,"tool_calls":[{"name":"run_command","args":{"CommandLine":"ls","Cwd":"/app"}}]}"#,
        #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-16T13:35:35Z","content":"Found it."}"#,
        #"{"step_index":3,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-16T13:36:00Z","content":"Fix it"}"#,
        #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-16T13:36:05Z","content":"Fixed."}"#,
    ]

    private func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    /// Every way to cut `data` in two: at each byte, so mid-line too.
    private func cuts(_ data: Data) -> [Int] { Array(1..<data.count) }

    // MARK: Line counting

    func testLineCountMatchesSplit() {
        for text in ["", "\n", "\n\n", "a", "a\n", "a\nb", "\na\n\nb\n", "a\n\n\nb\n\nc", "{}\n{}\n"] {
            let data = Data(text.utf8)
            XCTAssertEqual(AgentTranscript.lineCount(data), data.split(separator: 0x0A).count, "\(text.debugDescription)")
            // Also on a slice that does not start at zero, as the live view passes it.
            let padded = Data("xx".utf8) + data
            let slice = padded[padded.index(padded.startIndex, offsetBy: 2)...]
            XCTAssertEqual(AgentTranscript.lineCount(slice), slice.split(separator: 0x0A).count, "\(text.debugDescription)")
        }
    }

    // MARK: Gemini CLI

    private func json(_ chat: GeminiChatLog.Chat?) throws -> Data {
        let chat = try XCTUnwrap(chat)
        return try JSONSerialization.data(withJSONObject: ["metadata": chat.metadata, "messages": chat.messages], options: .sortedKeys)
    }

    func testGeminiLogReplayedInTwoPartsIsTheWholeChat() throws {
        let all = data(geminiLines)
        let whole = try json(GeminiChatLog.read(all))
        var lineEnds: [Int] = []
        for (index, byte) in all.enumerated() where byte == 0x0A { lineEnds.append(index + 1) }
        for cut in lineEnds.dropLast() {
            var log = GeminiChatLog.Log()
            log.apply(all[..<cut])
            log.apply(all[cut...])
            XCTAssertEqual(try json(log.chat), whole, "cut after byte \(cut)")
        }
        XCTAssertEqual(AgentTranscript.gemini(messages: try XCTUnwrap(GeminiChatLog.read(all)).messages), AgentTranscript.gemini(all))
    }

    func testGeminiLiveViewReadsOnFromWhereItStopped() throws {
        let chats = folder.appendingPathComponent(".gemini/tmp/app/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let all = data(geminiLines)
        let expected = AgentTranscript.gemini(all)
        XCTAssertFalse(expected.isEmpty)
        // Cut at a few places, mid-line among them: the half-written line counts for that read only.
        for cut in stride(from: 7, to: all.count - 1, by: max(1, all.count / 9)) {
            let file = chats.appendingPathComponent("session-\(UUID().uuidString).jsonl")
            XCTAssertTrue(GeminiChatLog.isLog(path: file.path))
            try all[..<cut].write(to: file)
            let first = AgentTranscript.recent(path: file.path)
            XCTAssertEqual(first, AgentTranscript.gemini(all[..<cut]), "first part, cut at \(cut)")
            try append(all[cut...], to: file)
            XCTAssertEqual(AgentTranscript.recent(path: file.path), expected, "cut at \(cut)")
        }
    }

    func testGeminiLiveViewStartsOverWhenTheLogIsRewritten() throws {
        let chats = folder.appendingPathComponent(".gemini/tmp/app/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-rewrite.jsonl")
        try data(geminiLines).write(to: file)
        _ = AgentTranscript.recent(path: file.path)
        // Shorter: truncated and written again.
        let shorter = data([geminiLines[0], #"{"id":"x1","type":"user","content":"a new start"}"#])
        try shorter.write(to: file)
        XCTAssertEqual(AgentTranscript.recent(path: file.path), AgentTranscript.gemini(shorter))
        // Longer, with other bytes where the last read stopped.
        let longer = data([geminiLines[0]] + (0..<20).map { #"{"id":"y\#($0)","type":"user","content":"line \#($0)"}"# })
        try longer.write(to: file)
        XCTAssertEqual(AgentTranscript.recent(path: file.path), AgentTranscript.gemini(longer))
    }

    func testGeminiJsonFormStillReadsWhole() throws {
        let file = folder.appendingPathComponent("session-old.json")
        let json = Data(#"{"sessionId":"s0","messages":[{"id":"a","type":"user","content":"hi"},{"id":"b","type":"gemini","content":"hello"}]}"#.utf8)
        try json.write(to: file)
        XCTAssertEqual(AgentTranscript.recent(path: file.path), AgentTranscript.gemini(json))
        XCTAssertEqual(AgentTranscript.recent(path: file.path).count, 2)
    }

    // MARK: JSONL (Cursor, Antigravity, Claude Code, Codex)

    func testJsonlParsedInTwoPartsIsTheWholeTranscript() {
        for lines in [cursorLines, antigravityLines] {
            let all = data(lines)
            let whole = AgentTranscript.jsonl(all)
            XCTAssertFalse(whole.isEmpty)
            for cut in cuts(all) {
                // As the history scan does it: whole lines first, numbered on, then the rest.
                let head = all[..<cut]
                let end = head.lastIndex(of: 0x0A).map { head.index(after: $0) } ?? head.startIndex
                let first = AgentTranscript.jsonl(all[..<end], continuing: [], firstLine: 0)
                let rest = AgentTranscript.jsonl(all[end...], continuing: first, firstLine: AgentTranscript.lineCount(all[..<end]))
                XCTAssertEqual(rest, whole, "cut at \(cut)")
            }
        }
    }

    func testJsonlLiveViewReadsOnFromWhereItStopped() throws {
        for (name, lines) in [("cursor", cursorLines), ("antigravity", antigravityLines)] {
            let all = data(lines)
            let expected = AgentTranscript.jsonl(all)
            for cut in stride(from: 5, to: all.count - 1, by: max(1, all.count / 7)) {
                let file = folder.appendingPathComponent("\(name)-\(UUID().uuidString).jsonl")
                try all[..<cut].write(to: file)
                _ = AgentTranscript.recent(path: file.path)
                try append(all[cut...], to: file)
                XCTAssertEqual(AgentTranscript.recent(path: file.path), expected, "\(name), cut at \(cut)")
            }
        }
    }

    func testJsonlLiveViewStartsOverWhenTheFileIsRewritten() throws {
        let file = folder.appendingPathComponent("rewritten.jsonl")
        try data(cursorLines).write(to: file)
        _ = AgentTranscript.recent(path: file.path)
        let other = data(antigravityLines + antigravityLines.map { $0.replacingOccurrences(of: "step_index\":", with: "step_index\":1") })
        try other.write(to: file)
        XCTAssertEqual(AgentTranscript.recent(path: file.path), AgentTranscript.jsonl(other))
        let shorter = data(Array(cursorLines.prefix(2)))
        try shorter.write(to: file)
        XCTAssertEqual(AgentTranscript.recent(path: file.path), AgentTranscript.jsonl(shorter))
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
