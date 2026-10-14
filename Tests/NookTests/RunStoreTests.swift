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
        XCTAssertEqual(loaded[1].state, .failed, "een tool die liep toen Nook stopte, loopt niet meer")
        XCTAssertEqual(loaded[2].state, .expired, "een open vraag kan na een herstart niet meer beantwoord worden")
        XCTAssertEqual(loaded[3].state, .done)
        store.deleteEvents(id)
        XCTAssertTrue(store.loadEvents(id).isEmpty)
    }

    func testEventLimit() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        let events = (0..<(RunStore.eventLimit + 10)).map { RunEvent(kind: .system, text: "\($0)") }
        try store.saveEvents(id, events)
        let loaded = store.loadEvents(id)
        XCTAssertEqual(loaded.count, RunStore.eventLimit)
        XCTAssertEqual(loaded.last?.text, "\(RunStore.eventLimit + 9)", "de nieuwste blijven")
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
        XCTAssertEqual(report.sessionsWithCost, 1, "alleen Claude meldde kosten; niets erbij verzonnen")
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
}
