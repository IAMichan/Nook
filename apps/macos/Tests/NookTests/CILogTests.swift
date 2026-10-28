import XCTest

/// The CI of a watched pull request: which checks have a job log, the steps of a job, and a raw log made readable.
final class CILogTests: XCTestCase {
    func testJobIDOnlyForGitHubActions() {
        XCTAssertEqual(CILogParser.jobID(from: URL(string: "https://github.com/o/r/actions/runs/123/job/456")), 456)
        XCTAssertEqual(CILogParser.jobID(from: URL(string: "https://github.com/o/r/actions/runs/123/job/456?pr=7")), 456)
        XCTAssertNil(CILogParser.jobID(from: URL(string: "https://github.com/o/r/runs/456")), "a check run page, not a job")
        XCTAssertNil(CILogParser.jobID(from: URL(string: "https://ci.example.com/actions/runs/1/job/2")), "another host")
        XCTAssertNil(CILogParser.jobID(from: nil))
    }

    func testSteps() {
        let job: [String: Any] = ["steps": [
            ["number": 1, "name": "Set up job", "status": "completed", "conclusion": "success"],
            ["number": 2, "name": "Test", "status": "completed", "conclusion": "failure"],
            ["number": 3, "name": "Upload", "status": "completed", "conclusion": "skipped"],
            ["number": 4, "name": "Post", "status": "in_progress"],
        ]]
        XCTAssertEqual(CILogParser.steps(job: job).map(\.outcome), [.passing, .failing, .skipped, .pending])
        XCTAssertEqual(CILogParser.steps(job: job).map(\.name), ["Set up job", "Test", "Upload", "Post"])
        XCTAssertTrue(CILogParser.steps(job: [:]).isEmpty)
    }

    func testRunningJobKeepsItsClock() {
        let job: [String: Any] = ["status": "in_progress", "started_at": "2026-10-28T12:00:00Z", "steps": [
            ["number": 1, "name": "Set up job", "status": "completed", "conclusion": "success",
             "started_at": "2026-10-28T12:00:00Z", "completed_at": "2026-10-28T12:00:05Z"],
            ["number": 2, "name": "Build", "status": "in_progress", "started_at": "2026-10-28T12:00:05Z"],
            ["number": 3, "name": "Test", "status": "queued"],
        ]]
        let log = CILogParser.log(job: job)
        XCTAssertNotNil(log.started)
        XCTAssertNil(log.finished, "a running job has no end yet")
        XCTAssertEqual(log.runningStep?.name, "Build")
        XCTAssertEqual(log.doneSteps, 1)
        XCTAssertEqual(log.steps.map(\.running), [false, true, false], "a queued step waits, it does not run")
        XCTAssertEqual(CILogParser.elapsed(started: log.steps[0].started, finished: log.steps[0].finished), 5)
        let now = log.steps[1].started!.addingTimeInterval(72)
        XCTAssertEqual(CILogParser.elapsed(started: log.steps[1].started, finished: nil, now: now), 72)
        XCTAssertNil(CILogParser.elapsed(started: nil, finished: nil))
    }

    func testClock() {
        XCTAssertEqual(CILogParser.clock(0), "0:00")
        XCTAssertEqual(CILogParser.clock(42.9), "0:42")
        XCTAssertEqual(CILogParser.clock(192), "3:12")
        XCTAssertEqual(CILogParser.clock(3845), "1:04:05")
        XCTAssertEqual(CILogParser.clock(-3), "0:00")
    }

    func testCleanDropsTimestampsAndColours() {
        let raw = "\u{FEFF}2026-10-20T12:00:01.1234567Z ##[group]Run swift test\r\n"
            + "2026-10-20T12:00:02.0000000Z \u{1B}[31merror:\u{1B}[0m it broke\n"
            + "no stamp here\n"
        let cleaned = CILogParser.clean(raw)
        XCTAssertEqual(cleaned.text, "##[group]Run swift test\nerror: it broke\nno stamp here")
        XCTAssertEqual(cleaned.omitted, 0)
    }

    func testCleanKeepsTheEnd() {
        let raw = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let cleaned = CILogParser.clean(raw, limit: 3)
        XCTAssertEqual(cleaned.text, "line 8\nline 9\nline 10")
        XCTAssertEqual(cleaned.omitted, 7)
    }

    func testLinesTakeTheirKindFromGitHubMarkersAndWords() {
        let lines = CILogParser.lines("##[group]Run build\n##[command]xcodebuild\nCompiling\nFoo.swift:1: error: nope\n"
            + "Foo.swift:2: warning: hmm\n##[endgroup]\n##[debug]noise\n##[error]Process completed with exit code 65.")
        XCTAssertEqual(lines.map(\.kind), [.group, .command, .plain, .error, .warning, .error])
        XCTAssertEqual(lines.first?.text, "Run build")
        XCTAssertEqual(lines.last?.text, "Process completed with exit code 65.")
    }

    func testProblemsKeepTheirGroupOnce() {
        let lines = CILogParser.lines("##[group]A\nfine\n##[group]Build\nx: error: one\ny: error: two\n##[group]Post\nfine")
        XCTAssertEqual(CILogParser.problems(lines).map(\.text), ["Build", "x: error: one", "y: error: two"])
        XCTAssertTrue(CILogParser.problems(CILogParser.lines("all good")).isEmpty)
    }
}
