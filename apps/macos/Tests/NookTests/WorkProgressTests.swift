import XCTest

final class WorkProgressTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func command(_ line: String, at offset: TimeInterval, took: TimeInterval? = nil, output: String? = nil,
                         tool: String = "Bash") -> RunEvent {
        var event = RunEvent(kind: .tool, text: tool + " · " + line, tool: tool, callID: UUID().uuidString,
                             detail: ToolSummary.json(["command": line]), output: output, state: took == nil ? .running : .done,
                             date: start.addingTimeInterval(offset))
        event.ended = took.map { start.addingTimeInterval(offset + $0) }
        return event
    }

    private func subagent(_ kind: String, at offset: TimeInterval, took: TimeInterval? = nil) -> RunEvent {
        var event = RunEvent(kind: .tool, text: "Agent · Look around", tool: "Agent", callID: UUID().uuidString,
                             detail: ToolSummary.json(["description": "Look around", "prompt": "Look", "subagent_type": kind]),
                             state: took == nil ? .running : .done, date: start.addingTimeInterval(offset))
        event.ended = took.map { start.addingTimeInterval(offset + $0) }
        return event
    }

    // MARK: What it printed

    func testReadsStepCountsAndPercentagesFromTheEnd() throws {
        XCTAssertEqual(try XCTUnwrap(WorkProgress.reported(in: "Building for debugging...\n[12/48] Compiling Nook Foo.swift\n")), 0.25)
        XCTAssertEqual(try XCTUnwrap(WorkProgress.reported(in: "    Building [=====>    ] 120/240: serde\n")), 0.5)
        XCTAssertEqual(try XCTUnwrap(WorkProgress.reported(in: "tests/a.py ....  [ 40%]\ntests/b.py ..   [ 60%]\n")), 0.6)
        // A progress bar redraws itself on one line.
        XCTAssertEqual(try XCTUnwrap(WorkProgress.reported(in: "Receiving objects:  10% (1/10)\rReceiving objects:  70% (7/10)")), 0.7)
    }

    func testIgnoresPercentagesAboutSomethingElse() {
        XCTAssertNil(WorkProgress.reported(in: "Done. 140% CPU"))
        XCTAssertNil(WorkProgress.reported(in: "All files | 85.3 | Stmts"))
        XCTAssertNil(WorkProgress.reported(in: "Coverage: 85%"))
        XCTAssertNil(WorkProgress.reported(in: "hello world"))
        XCTAssertNil(WorkProgress.reported(in: "[3/1] odd"), "more done than the total is not a count")
        XCTAssertNil(WorkProgress.reported(in: "ratio 250%"))
        XCTAssertNil(WorkProgress.reported(in: nil))
    }

    // MARK: Earlier runs

    func testEstimatesACommandFromItsEarlierRun() throws {
        let earlier = command("swift test", at: 0, took: 120)
        let other = command("swift build", at: 200, took: 30)
        let now = command("swift  test", at: 300)
        let progress = try XCTUnwrap(WorkProgress.of(now, in: [earlier, other, now]))
        XCTAssertNil(progress.reported)
        XCTAssertEqual(progress.expected, 120, "the same command line, spaces folded; the other command does not count")
        XCTAssertEqual(progress.started, now.date)
    }

    func testNoEstimateWithoutAnEarlierRunOrForQuickWork() {
        let now = command("swift test", at: 300)
        XCTAssertNil(WorkProgress.of(now, in: [now]))
        let quick = command("ls", at: 0, took: 1)
        let again = command("ls", at: 10)
        XCTAssertNil(WorkProgress.of(again, in: [quick, again]))
        var failed = command("make", at: 0, took: 60)
        failed.state = .failed
        let retry = command("make", at: 100)
        XCTAssertNil(WorkProgress.of(retry, in: [failed, retry]), "only runs that finished well say how long it takes")
    }

    func testSubagentsNeedTwoEarlierOnesOfTheirKind() throws {
        let first = subagent("Explore", at: 0, took: 40)
        let now = subagent("Explore", at: 100)
        XCTAssertNil(WorkProgress.of(now, in: [first, now]))
        let second = subagent("Explore", at: 50, took: 60)
        let plan = subagent("Plan", at: 60, took: 600)
        XCTAssertEqual(try XCTUnwrap(WorkProgress.of(now, in: [first, second, plan, now])).expected, 50, "the median of its kind")
    }

    func testRunningListsOnlyRunningWorkWithProgress() {
        let streaming = command("npm install", at: 0, output: "added 10 packages\nprogress 45%")
        let silent = command("sleep 100", at: 0)
        let done = command("swift test", at: 0, took: 100)
        let progress = WorkProgress.running(in: [streaming, silent, done])
        XCTAssertEqual(progress.keys.sorted { $0.uuidString < $1.uuidString }, [streaming.id])
        XCTAssertEqual(progress[streaming.id]?.percent, 45)
    }

    func testEstimatedBarIsFullALittleAfterTheExpectedEnd() throws {
        let progress = WorkProgress(reported: nil, started: start, expected: 90)
        XCTAssertEqual(try XCTUnwrap(progress.estimatedEnd).timeIntervalSince(start), 100, accuracy: 0.001)
    }

    // MARK: When it ended

    func testNotesTheEndOnceWhenACallSettles() {
        var event = command("swift test", at: 0)
        event.noteEnd(wasRunning: true, at: start.addingTimeInterval(5))
        XCTAssertNil(event.ended, "still running")
        event.state = .done
        event.noteEnd(wasRunning: true, at: start.addingTimeInterval(10))
        XCTAssertEqual(event.ended, start.addingTimeInterval(10))
        event.noteEnd(wasRunning: true, at: start.addingTimeInterval(20))
        XCTAssertEqual(event.ended, start.addingTimeInterval(10), "the first end stays")

        var added = command("ls", at: 0, took: nil)
        added.state = .done
        added.noteEnd(wasRunning: false, at: start)
        XCTAssertNil(added.ended, "a call that was never seen running has no duration")

        var text = RunEvent(kind: .assistant, text: "Hi", state: .running)
        text.state = .done
        text.noteEnd(wasRunning: true)
        XCTAssertNil(text.ended, "only tool calls")
    }

    func testEndSurvivesSavingAndAnOldTimelineReadsWithoutIt() throws {
        var event = command("swift test", at: 0, took: 30)
        event.ended = start.addingTimeInterval(30)
        let decoded = try JSONDecoder().decode(RunEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.ended, event.ended)
        XCTAssertNotEqual(RunStore.fingerprint(event), RunStore.fingerprint({ var copy = event; copy.ended = nil; return copy }()))
    }

    // MARK: Background commands

    func testABackgroundCommandTakesTheShareItsOutputFileReports() {
        var info = BackgroundCommandInfo(id: UUID(), title: "Build", command: "make", state: .running, output: nil, started: start,
                                         progress: WorkProgress(reported: nil, started: start, expected: 60))
        let activity = BackgroundCommandActivity(state: .working, reported: 0.4)
        XCTAssertEqual(info.reading(activity).progress, WorkProgress(reported: 0.4, started: start, expected: 60))
        XCTAssertEqual(info.reading(nil), info)
        info.state = .done
        XCTAssertEqual(info.reading(activity), info, "a finished command shows no progress")
    }
}
