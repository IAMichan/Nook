import XCTest

final class CompactionProgressTests: XCTestCase {
    private let you = RunEvent(kind: .user, text: "/compact")

    /// Applies a change as `WorkspaceManager+Compaction` does.
    private func applying(_ change: CompactionChange, to events: [RunEvent]) -> [RunEvent] {
        var events = events
        switch change {
        case .append(let event): events.append(event)
        case .update(let id, let kind, let text, let state):
            guard let index = events.firstIndex(where: { $0.id == id }) else { return events }
            events[index].kind = kind
            events[index].text = text
            events[index].state = state
        case .none: break
        }
        return events
    }

    func testACompactionIsLiveUntilItIsDone() {
        var events = applying(CompactionProgress.start([you], done: "Compacted"), to: [you])
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(CompactionProgress.isRunning(events[1]))
        XCTAssertEqual(AgentActivity.current(events), .compacting, "the live line says the agent compacts")
        XCTAssertEqual(CompactionProgress.start(events, done: "Compacted"), .none, "a start reported twice is one row")

        events = applying(CompactionProgress.finish(events, text: "Compacted by Nook"), to: events)
        XCTAssertEqual(events.count, 2, "the live row becomes the result")
        XCTAssertEqual(events[1].state, .done)
        XCTAssertEqual(events[1].text, "Compacted by Nook")
        XCTAssertNotEqual(AgentActivity.current(events), .compacting)
    }

    func testAnAgentThatOnlyReportsTheResultGetsOneDoneRow() {
        var events = applying(CompactionProgress.finish([you], text: "Compacted"), to: [you])
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(CompactionProgress.isCompaction(events[1]))
        XCTAssertEqual(events[1].state, .done)
        // Codex reports one compaction as its item and as `thread/compacted`.
        events = applying(CompactionProgress.finish(events, text: "Compacted"), to: events)
        XCTAssertEqual(events.count, 2)
    }

    func testAFailedCompactionBecomesItsError() {
        let started = applying(CompactionProgress.start([you], done: "Compacted"), to: [you])
        let failed = applying(CompactionProgress.fail(started, message: "Prompt is too long", stopped: "Stopped"), to: started)
        XCTAssertEqual(failed[1].kind, .error)
        XCTAssertEqual(failed[1].text, "Prompt is too long")
        XCTAssertEqual(failed[1].state, .failed)
        let stopped = applying(CompactionProgress.fail(started, message: nil, stopped: "Stopped"), to: started)
        XCTAssertEqual(stopped[1].text, "Stopped")
        XCTAssertEqual(CompactionProgress.fail([you], message: "x", stopped: "Stopped"), .none, "nothing runs: nothing to fail")
    }

    func testOnlyTheLastTurnsCompactionCounts() {
        let old = RunEvent(kind: .system, text: "Compacted", tool: CompactionProgress.tool, state: .running)
        XCTAssertNil(CompactionProgress.running(in: [old, you]), "a message of yours ends the turn it ran in")
    }

    func testTheEndOfATurnSettlesACompactionLeftRunning() {
        let running = RunEvent(kind: .system, text: "Compacted", tool: CompactionProgress.tool, state: .running)
        XCTAssertEqual(OpenWork.settle(events: [you, running], reason: .completed).map(\.state), [.done])
        XCTAssertEqual(OpenWork.settle(events: [you, running], reason: .stopped).map(\.state), [.failed])
        let other = RunEvent(kind: .system, text: "Stopping", state: .running)
        XCTAssertTrue(OpenWork.settle(events: [other], reason: .completed).isEmpty, "other notices are left alone")
    }

    // MARK: What each agent reports

    func testClaudeCodeReportsTheStartAndAFailure() {
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"system","subtype":"status","status":"compacting","session_id":"s"}"#),
                       [.compaction(.started)])
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"Not enough messages"}"#),
                       [.compaction(.failed("Not enough messages"))])
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"system","subtype":"status","status":null,"compact_result":"success"}"#), [],
                       "the result is compact_boundary")
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual"}}"#),
                       [.notice("compact")])
        XCTAssertFalse(ClaudeStreamEvent.isWork(.compaction(.started)))
    }

    func testCodexAppServerReportsTheStart() {
        let started = #"{"method":"item/started","params":{"item":{"type":"contextCompaction","id":"c1"},"threadId":"t","turnId":"u"}}"#
        let completed = #"{"method":"item/completed","params":{"item":{"type":"contextCompaction","id":"c1"},"threadId":"t","turnId":"u"}}"#
        XCTAssertEqual(CodexAppServerMapper.events(CodexRPC.parse(started)!), [.compaction(.started)])
        XCTAssertEqual(CodexAppServerMapper.events(CodexRPC.parse(completed)!), [.notice("compact")])
    }

    func testPiReportsTheStartAndTheEnd() {
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"compaction_start","reason":"manual"}"#), [.compactionStarted])
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"compaction_end","aborted":true}"#), [.compactionEnded(failed: "")])
    }
}
