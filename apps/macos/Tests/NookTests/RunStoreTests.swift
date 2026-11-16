import XCTest

final class RunStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTripKeepsEverything() throws {
        let store = RunStore(directory: folder)
        var run = TestData.run(status: .completed, model: "opus")
        run.providerSessionID = "sess-1"
        run.usage.add(TurnUsage(inputTokens: 5, outputTokens: 7, reportedCostUSD: 0.01))
        run.branch = "nook/x"
        try store.saveRuns([run])
        let loaded = RunStore(directory: folder).loadRuns()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, run.id)
        XCTAssertEqual(loaded[0].providerSessionID, "sess-1")
        XCTAssertEqual(loaded[0].usage.inputTokens, 5)
        XCTAssertEqual(loaded[0].usage.reportedCostUSD ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(loaded[0].branch, "nook/x")
        XCTAssertEqual(loaded[0].status, .completed)
    }

    /// Saves reuse the JSON of sessions that did not change: the file must be the same as encoding the whole list.
    func testSavesReuseUnchangedSessionsAndWriteTheSameFile() throws {
        let store = RunStore(directory: folder)
        let file = folder.appendingPathComponent("runs.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var runs = [TestData.run(status: .running), TestData.run(status: .completed), TestData.run(status: .failed)]
        try store.saveRuns(runs)
        try assertSameJSON(try Data(contentsOf: file), try encoder.encode(runs))

        runs[1].title = "Renamed"
        runs.remove(at: 2)
        runs.insert(TestData.run(status: .stopped), at: 0)
        try store.saveRuns(runs)
        try assertSameJSON(try Data(contentsOf: file), try encoder.encode(runs))
        XCTAssertEqual(RunStore(directory: folder).loadRuns().map(\.title), runs.map(\.title))

        try store.saveRuns([])
        XCTAssertEqual(try Data(contentsOf: file), Data("[]".utf8))
    }

    /// The same JSON value: `JSONEncoder` without `.sortedKeys` does not promise one key order, so two encodings of the
    /// same runs can differ byte for byte (they did on the CI runner).
    private func assertSameJSON(_ written: Data, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let lhs = try JSONSerialization.jsonObject(with: written) as? NSArray
        let rhs = try JSONSerialization.jsonObject(with: expected) as? NSArray
        XCTAssertNotNil(lhs, file: file, line: line)
        XCTAssertEqual(lhs, rhs, file: file, line: line)
    }

    func testActiveRunsAreNotRunningAfterRestart() throws {
        let store = RunStore(directory: folder)
        var running = TestData.run(status: .running)
        running.turnStartedAt = Date()
        let waiting = TestData.run(status: .waitingApproval)
        let done = TestData.run(status: .completed)
        try store.saveRuns([running, waiting, done])
        let loaded = RunStore(directory: folder).loadRuns()
        XCTAssertEqual(loaded.map(\.status), [.stopped, .stopped, .completed])
        XCTAssertEqual(loaded[0].statusDetail, "interrupted")
        XCTAssertNil(loaded[0].turnStartedAt)
        XCTAssertNil(loaded[2].statusDetail)
    }

    func testEventsRoundTripAndPendingExpire() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        let events = [
            RunEvent(kind: .user, text: "Doe het"),
            RunEvent(kind: .tool, text: "Bash · ls", tool: "Bash", callID: "t1", state: .running),
            RunEvent(kind: .approval, text: "Bash · rm", tool: "Bash", callID: "r1", state: .pending),
            RunEvent(kind: .assistant, text: "Klaar", state: .done)
        ]
        try store.saveEvents(id, events)
        let loaded = store.loadEvents(id)
        XCTAssertEqual(loaded.map(\.text), events.map(\.text))
        XCTAssertEqual(loaded[1].state, .failed, "a tool running when Nook stopped is no longer running")
        XCTAssertEqual(loaded[2].state, .expired, "a pending prompt can no longer be answered after restart")
        XCTAssertEqual(loaded[3].state, .done)
        store.deleteEvents(id)
        XCTAssertTrue(store.loadEvents(id).isEmpty)
    }

    /// Deleting in the background follows the saves handed over before it, and drops the ones after it.
    func testDeletingInTheBackgroundKeepsTheOrderOfSaves() {
        let store = RunStore(directory: folder)
        let id = UUID()
        store.saveEventsAsync(id, [RunEvent(kind: .user, text: "first")])
        store.appendEventAsync(id, RunEvent(kind: .assistant, text: "second"))
        store.deleteEventsAsync(id)
        store.appendEventAsync(id, RunEvent(kind: .assistant, text: "late"))
        store.saveEventsAsync(id, [RunEvent(kind: .user, text: "late save")])
        store.flush()
        XCTAssertTrue(store.loadEvents(id).isEmpty)
        XCTAssertTrue(RunStore(directory: folder).loadEvents(id).isEmpty)
    }

    func testLongTimelinesAreKeptWhole() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        // More than the 4,000 events the JSON files used to keep.
        let events = (0..<5_000).map { RunEvent(kind: .system, text: "\($0)") }
        try store.saveEvents(id, events)
        let loaded = RunStore(directory: folder).loadEvents(id)
        XCTAssertEqual(loaded.count, 5_000)
        XCTAssertEqual(loaded.first?.text, "0", "the oldest are kept too")
        XCTAssertEqual(loaded.last?.text, "4999")
    }

    func testFilesArePrivate() throws {
        let store = RunStore(directory: folder)
        try store.saveRuns([TestData.run(status: .completed)])
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("runs.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptFileGivesEmptyList() throws {
        try "{niet goed".write(to: folder.appendingPathComponent("runs.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(RunStore(directory: folder).loadRuns().isEmpty)
    }
}

final class UsageReportTests: XCTestCase {
    func testTotalsAndUnavailableCost() {
        var claude = RunUsage()
        claude.add(TurnUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 1000, cacheWriteTokens: 10, reportedCostUSD: 0.5))
        var codex = RunUsage()
        codex.add(TurnUsage(inputTokens: 200, outputTokens: 20, cacheReadTokens: 300))
        let runs = [
            TestData.run(status: .completed, provider: .claude, model: "opus", usage: claude),
            TestData.run(status: .failed, provider: .codex, usage: codex),
            TestData.run(status: .running, provider: .claude, model: "opus")
        ]
        let report = UsageReport.make(runs: runs, filter: UsageReport.Filter(range: .all))
        XCTAssertEqual(report.sessions, 3)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.running, 1)
        XCTAssertEqual(report.inputTokens, 300)
        XCTAssertEqual(report.outputTokens, 70)
        XCTAssertEqual(report.cacheReadTokens, 1300)
        XCTAssertEqual(report.cacheWriteTokens, 10)
        XCTAssertEqual(report.reportedCostUSD ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.sessionsWithCost, 1, "only Claude reported cost; nothing fabricated")
        XCTAssertEqual(report.sessionsWithTokens, 2)
        XCTAssertEqual(report.averageTokensPerSession, (1160 + 520) / 2)

        let opus = report.rows.first { $0.provider == .claude }
        XCTAssertEqual(opus?.model, "opus")
        XCTAssertEqual(opus?.sessions, 2)
        XCTAssertEqual(opus?.sessionsWithoutTokens, 1)
        let codexRow = report.rows.first { $0.provider == .codex }
        XCTAssertEqual(codexRow?.model, "default")
        XCTAssertNil(codexRow?.reportedCostUSD)
    }

    func testNoCostWhenNobodyReportedIt() {
        var usage = RunUsage()
        usage.add(TurnUsage(inputTokens: 1, outputTokens: 1))
        let report = UsageReport.make(runs: [TestData.run(status: .completed, provider: .codex, usage: usage)],
                                      filter: UsageReport.Filter(range: .all))
        XCTAssertNil(report.reportedCostUSD)
        XCTAssertNil(UsageReport.make(runs: [], filter: UsageReport.Filter(range: .all)).averageTokensPerSession)
    }

    func testFilters() {
        let now = Date()
        let old = TestData.run(status: .completed, project: "/a", updated: now.addingTimeInterval(-40 * 86_400))
        let recent = TestData.run(status: .completed, provider: .codex, project: "/b", updated: now)
        XCTAssertEqual(UsageReport.make(runs: [old, recent], filter: UsageReport.Filter(range: .week), now: now).sessions, 1)
        XCTAssertEqual(UsageReport.make(runs: [old, recent], filter: UsageReport.Filter(range: .all), now: now).sessions, 2)
        XCTAssertEqual(UsageReport.make(runs: [old, recent], filter: UsageReport.Filter(range: .all, provider: .claude), now: now).sessions, 1)
        XCTAssertEqual(UsageReport.make(runs: [old, recent], filter: UsageReport.Filter(range: .all, project: "/b"), now: now).sessions, 1)
    }

    func testResolvedModelWins() {
        var run = TestData.run(status: .completed, model: "")
        XCTAssertEqual(UsageReport.displayModel(run), "default")
        run.resolvedModel = "claude-sonnet-4-5"
        XCTAssertEqual(UsageReport.displayModel(run), "claude-sonnet-4-5")
    }

    func testPeekReadsTheTimelineWithoutChangingWhatSavesCompareWith() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        var event = RunEvent(kind: .assistant, text: "first")
        try RunStore(directory: folder).saveEvents(id, [event])

        // A new launch: this store has seen nothing of the timeline.
        let store = RunStore(directory: folder)
        XCTAssertEqual(store.peekEvents(id).map(\.text), ["first"])
        event.text = "second"
        try store.saveEvents(id, [event])
        XCTAssertEqual(store.peekEvents(id).map(\.text), ["second"])
        XCTAssertEqual(store.loadEvents(id).map(\.id), [event.id])
    }

    func testAFailedWriteOfTheSessionListIsReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")
        let store = RunStore(directory: folder)
        try FileManager.default.removeItem(at: folder)

        let failed = expectation(description: "the failure is reported")
        store.saveRunsAsync([TestData.run(status: .completed)]) { failed.fulfill() }
        wait(for: [failed], timeout: 5)
    }

    func testAChangeToAnyPartOfAnEventIsSaved() throws {
        let folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RunStore(directory: folder)
        let id = UUID()
        var event = RunEvent(kind: .user, text: "hello")
        try store.saveEvents(id, [event])
        event.rolledBack = true
        event.source = "transcript-1"
        try store.saveEvents(id, [event])
        let read = RunStore(directory: folder).loadEvents(id).first
        XCTAssertEqual(read?.rolledBack, true)
        XCTAssertEqual(read?.source, "transcript-1")
    }
}

/// What waits on you survives a restart (`RestartRequests`): questions to answer as a message, a note for each approval
/// that expired, and the queue, held.
final class RestartRequestsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let question = RunQuestion(id: "q1", header: "Plan", question: "Which database?",
                                       options: [RunQuestionOption(label: "Postgres", description: "", preview: "```sql\nselect 1\n```"),
                                                 RunQuestionOption(label: "SQLite", description: "local")],
                                       multiSelect: true, allowsOther: false)

    private func queue(_ texts: [String], fresh: Bool = false) -> MessageQueue {
        var queue = MessageQueue()
        for text in texts { queue.enqueue(text, fresh: fresh, origin: .notice) }
        return queue
    }

    func testAQuestionAnApprovalAndTheQueueSurviveARestart() throws {
        let store = RunStore(directory: folder)
        let asking = TestData.run(status: .waitingApproval)
        var queued = TestData.run(status: .running)
        queued.id = UUID()
        let saved = try XCTUnwrap(RestartRequests.saved(id: "toolu_1", questions: [question], created: Date(timeIntervalSince1970: 100)))
        let list = RestartRequests.merged([asking, queued], questions: [asking.id: [saved]], approvals: [asking.id: ["Bash: rm -rf build"]],
                                          queues: [queued.id: queue(["one", "two"], fresh: true)])
        try store.saveRuns(list)

        var loaded = RunStore(directory: folder).loadRuns()
        XCTAssertEqual(loaded.first { $0.id == asking.id }?.status, .stopped, "the process that asked is gone")
        XCTAssertEqual(loaded.first { $0.id == asking.id }?.interruptedWhileWaiting, true, "so Nook does not go on by itself")
        let waiting = RestartRequests.take(&loaded)
        XCTAssertTrue(loaded.allSatisfy { $0.waitingQuestions == nil && $0.waitingApprovals == nil && $0.queue == nil },
                      "the sessions in memory never carry them")
        XCTAssertEqual(waiting[asking.id]?.questions, [saved], "options, previews and multi-select come back")
        XCTAssertEqual(waiting[asking.id]?.questions.first?.questions.first?.options.first?.preview, "```sql\nselect 1\n```")
        XCTAssertEqual(waiting[asking.id]?.approvals, ["Bash: rm -rf build"])
        let restored = try XCTUnwrap(waiting[queued.id]?.queue)
        XCTAssertEqual(restored.messages.map(\.text), ["one", "two"])
        XCTAssertTrue(restored.messages.allSatisfy { $0.fresh && $0.origin == .notice }, "its flags come back")
        XCTAssertTrue(restored.isHeld, "nothing goes out by itself at launch")
    }

    func testOnlyListedSessionsAreWrittenAndClearedOnesLoseTheirState() {
        let kept = TestData.run(status: .completed)
        var gone = TestData.run(status: .completed)
        gone.id = UUID()
        let merged = RestartRequests.merged([kept], questions: [gone.id: [SavedQuestion(id: "x", questions: [question], created: Date())]],
                                            approvals: [:], queues: [gone.id: queue(["lost"])])
        XCTAssertEqual(merged.count, 1, "a deleted session's state goes with it")
        XCTAssertNil(merged[0].queue)
        var stale = kept
        stale.queue = queue(["sent meanwhile"])
        XCTAssertNil(RestartRequests.merged([stale], questions: [:], approvals: [:], queues: [:])[0].queue)
        XCTAssertNil(RestartRequests.merged([kept], questions: [:], approvals: [:], queues: [kept.id: MessageQueue()])[0].queue,
                     "an empty queue is not written")
        XCTAssertEqual(RestartRequests.merged([kept], questions: [:], approvals: [:], queues: [:]), [kept], "nothing waits: unchanged")
    }

    func testAnEmptyQuestionIsNotSaved() {
        let empty = RunQuestion(id: "e", header: "", question: "", options: [], multiSelect: false, allowsOther: true)
        XCTAssertNil(RestartRequests.saved(id: "e", questions: [empty], created: Date()))
        XCTAssertNil(RestartRequests.restoredQueue(MessageQueue()))
    }

    func testTheAnswerGoesAsAMessage() {
        let answers = ["q1": ["Postgres", "SQLite"]]
        XCTAssertEqual(RestartRequests.message([question], answers: answers, restored: false), "Which database? → Postgres, SQLite")
        let restored = RestartRequests.message([question], answers: answers, restored: true)
        XCTAssertTrue(restored.hasSuffix("Which database? → Postgres, SQLite"))
        XCTAssertTrue(restored.contains("before Nook restarted"), "the agent learns what the answer is to")
    }

    func testOlderAndNewerFilesDecode() throws {
        // A question saved without a preview or flags still loads.
        let json = #"{"id":"q","question":"Go?","options":[{"label":"Yes"}]}"#
        let decoded = try JSONDecoder().decode(RunQuestion.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.options.first?.preview, "")
        XCTAssertEqual(decoded.options.first?.description, "")
        XCTAssertFalse(decoded.multiSelect)
        XCTAssertEqual(try JSONDecoder().decode(RunQuestion.self, from: JSONEncoder().encode(question)), question)
        // A session saved before any of this has none of it.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TestData.run(status: .stopped))) as? [String: Any])
        object["waitingQuestions"] = nil
        object["queue"] = nil
        let run = try JSONDecoder().decode(WorkspaceRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(run.waitingQuestions)
        XCTAssertNil(run.queue)
    }
}
