import XCTest

final class TimelineCopyTests: XCTestCase {
    private func items(_ actions: [WorkAction], failing: Set<Int> = []) -> [WorkGroupItem] {
        actions.enumerated().map { WorkGroupItem(action: $0.element, failed: failing.contains($0.offset)) }
    }

    func testEmpty() {
        let s = WorkGroupSummary.make([])
        XCTAssertEqual(s.kind, .empty)
        XCTAssertTrue(s.parts.isEmpty)
        XCTAssertFalse(s.hasFailure)
    }

    func testThoughtOnly() {
        XCTAssertEqual(WorkGroupSummary.make(items([.thought])).kind, .thoughtOnly(count: 1))
        XCTAssertEqual(WorkGroupSummary.make(items([.thought, .thought, .thought])).kind, .thoughtOnly(count: 3))
    }

    func testSingleCategoryCounts() {
        let s = WorkGroupSummary.make(items([.read, .read, .read]))
        XCTAssertEqual(s.kind, .work)
        XCTAssertEqual(s.parts, [.init(category: .read, count: 3)])
        XCTAssertEqual(s.otherCount, 0)
    }

    func testThoughtsMixedWithToolsAreIgnored() {
        let s = WorkGroupSummary.make(items([.thought, .command, .thought]))
        XCTAssertEqual(s.parts, [.init(category: .command, count: 1)])
        XCTAssertEqual(s.otherCount, 0)
    }

    func testTwoPartsByPriorityKeepFirstSeenOrder() {
        let s = WorkGroupSummary.make(items([.read, .read, .edit, .search, .command]))
        // command and edit outrank search and read; shown in the order they first appeared.
        XCTAssertEqual(s.parts, [.init(category: .edit, count: 1), .init(category: .command, count: 1)])
        XCTAssertEqual(s.otherCount, 3)
    }

    func testReadsRankBelowSearchWebMcp() {
        let s = WorkGroupSummary.make(items([.read, .web, .mcp, .read]))
        XCTAssertEqual(s.parts.map(\.category), [.web, .mcp])
        XCTAssertEqual(s.otherCount, 2)
    }

    func testAgentCountsAsOrchestration() {
        let s = WorkGroupSummary.make(items([.search, .agent, .read]))
        XCTAssertEqual(s.parts.map(\.category), [.search, .agent])
        XCTAssertEqual(s.otherCount, 1)
    }

    func testTiesGoToFirstSeen() {
        let s = WorkGroupSummary.make(items([.other, .read, .other, .read]))
        XCTAssertEqual(s.parts.map(\.category), [.other, .read])
        XCTAssertEqual(s.otherCount, 0)
        let t = WorkGroupSummary.make(items([.read, .other, .command]))
        XCTAssertEqual(t.parts.map(\.category), [.read, .command])
        XCTAssertEqual(t.otherCount, 1)
    }

    func testFailureCountsEvenInHiddenGroups() {
        let s = WorkGroupSummary.make(items([.command, .edit, .read], failing: [2]))
        XCTAssertTrue(s.hasFailure)
        XCTAssertEqual(s.otherCount, 1)
        XCTAssertFalse(WorkGroupSummary.make(items([.command, .edit])).hasFailure)
    }

    func testFoldLabels() {
        XCTAssertEqual(FoldLabel.make(status: .completed, durationSeconds: 42, superseded: false),
                       FoldLabel(kind: .worked(seconds: 42)))
        XCTAssertEqual(FoldLabel.make(status: .stopped, durationSeconds: 12, superseded: false),
                       FoldLabel(kind: .stoppedAfter(seconds: 12)))
        XCTAssertEqual(FoldLabel.make(status: .stopped, durationSeconds: nil, superseded: false),
                       FoldLabel(kind: .stopped))
        XCTAssertEqual(FoldLabel.make(status: .completed, durationSeconds: nil, superseded: false),
                       FoldLabel(kind: .worked(seconds: nil)))
    }

    func testFailedKeepsWorkedAndFlags() {
        let label = FoldLabel.make(status: .failed, durationSeconds: 5, superseded: false)
        XCTAssertEqual(label?.kind, .worked(seconds: 5))
        XCTAssertEqual(label?.failed, true)
        XCTAssertEqual(FoldLabel.make(status: .completed, durationSeconds: 5, superseded: false)?.failed, false)
    }

    func testSupersededWinsOverStatus() {
        for status in RunStatus.allCases {
            XCTAssertEqual(FoldLabel.make(status: status, durationSeconds: 9, superseded: true)?.kind, .superseded)
        }
    }

    func testActiveTurnsHaveNoFold() {
        for status in [RunStatus.preparing, .running, .waitingApproval] {
            XCTAssertNil(FoldLabel.make(status: status, durationSeconds: 3, superseded: false))
        }
    }

    func testNegativeDurationClamps() {
        XCTAssertEqual(FoldLabel.make(status: .completed, durationSeconds: -4, superseded: false)?.kind, .worked(seconds: 0))
    }

    func testFailureJump() {
        let ok = RunEvent(kind: .tool, text: "ls", state: .done)
        let running = RunEvent(kind: .tool, text: "build", state: .running)
        let bad = RunEvent(kind: .tool, text: "test", state: .failed)
        let err = RunEvent(kind: .error, text: "boom")
        let assistantFailed = RunEvent(kind: .assistant, text: "x", state: .failed)
        XCTAssertNil(FailureJump.firstFailure(in: []))
        XCTAssertEqual(FailureJump.failureCount(in: []), 0)
        XCTAssertNil(FailureJump.firstFailure(in: [ok, running, assistantFailed]))
        XCTAssertEqual(FailureJump.firstFailure(in: [ok, bad, err]), bad.id)
        XCTAssertEqual(FailureJump.firstFailure(in: [ok, err, bad]), err.id)
        XCTAssertEqual(FailureJump.failureCount(in: [ok, bad, err, assistantFailed]), 2)
    }
}
