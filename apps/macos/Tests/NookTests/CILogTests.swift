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
}
