import XCTest

final class SessionLivenessTests: XCTestCase {
    private func tail(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    private let prompt = #"{"type":"user","uuid":"1","message":{"role":"user","content":"fix it"}}"#
    private let toolCall = #"{"type":"assistant","uuid":"2","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
    private let toolResult = #"{"type":"user","uuid":"3","message":{"role":"user","content":[{"type":"tool_result"}]}}"#
    private let partial = #"{"type":"assistant","uuid":"4","message":{"stop_reason":null,"content":[{"type":"text"}]}}"#
    private let reply = #"{"type":"assistant","uuid":"5","message":{"stop_reason":"end_turn","content":[{"type":"text"}]}}"#

    func testClaudeTurnEndsOnlyOnAFinalAssistantLine() {
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, toolCall, toolResult, partial, reply])), .ended)
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, toolCall])), .open, "a tool call follows")
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, toolCall, toolResult])), .open)
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, partial])), .open, "text before the final block")
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([reply, prompt])), .open, "a new prompt reopens the turn")
    }

    func testBookkeepingLinesAreSkipped() {
        let summary = #"{"type":"summary","summary":"Update Nook"}"#
        let sidechain = #"{"type":"user","isSidechain":true,"message":{"content":"sub task"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"skill text"}}"#
        let cut = #"ssage":{"stop_reason":"#
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([cut, reply, summary, sidechain, meta, ""])), .ended)
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([summary])), .unknown)
        XCTAssertEqual(SessionLiveness.lastTurn(in: Data()), .unknown)
    }

    func testEscapeInterruptionEndsTheTurn() {
        let interrupted = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, toolCall, interrupted])), .ended)
    }

    func testCodexRolloutEvents() {
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        let item = #"{"type":"response_item","payload":{"type":"message"}}"#
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([started, item, complete, item])), .ended)
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([complete, started, item])), .open)
    }

    func testVerdictWaitsForQuietBeforeTrustingTheTranscript() {
        let now = Date()
        let recent = now.addingTimeInterval(-3)
        let quiet = now.addingTimeInterval(-SessionLiveness.settleDelay - 1)
        XCTAssertEqual(SessionLiveness.verdict(working: true, lastEvent: quiet, turn: .ended, transcriptModified: quiet,
                                               missingScans: 0, now: now), .turnEnded)
        XCTAssertNil(SessionLiveness.verdict(working: true, lastEvent: recent, turn: .ended, transcriptModified: quiet,
                                             missingScans: 0, now: now), "a Stop hook may still be on its way")
        XCTAssertNil(SessionLiveness.verdict(working: true, lastEvent: quiet, turn: .ended, transcriptModified: recent,
                                             missingScans: 0, now: now))
        XCTAssertNil(SessionLiveness.verdict(working: true, lastEvent: quiet, turn: .open, transcriptModified: quiet,
                                             missingScans: 0, now: now))
        XCTAssertNil(SessionLiveness.verdict(working: false, lastEvent: quiet, turn: .ended, transcriptModified: quiet,
                                             missingScans: 0, now: now), "waiting asks something of you")
    }

    func testVerdictForAProcessThatQuit() {
        let now = Date()
        let old = now.addingTimeInterval(-SessionLiveness.goneDelay - 1)
        let scans = SessionLiveness.goneScans
        XCTAssertEqual(SessionLiveness.verdict(working: false, lastEvent: old, turn: .unknown, transcriptModified: nil,
                                               missingScans: scans, now: now), .processGone)
        XCTAssertNil(SessionLiveness.verdict(working: true, lastEvent: old, turn: .unknown, transcriptModified: nil,
                                             missingScans: scans - 1, now: now), "one missed scan is not enough")
        XCTAssertNil(SessionLiveness.verdict(working: true, lastEvent: now, turn: .unknown, transcriptModified: nil,
                                             missingScans: scans, now: now), "a hook just arrived")
    }

    func testProcessMatchingAllowsSubfolders() {
        let processes = [(name: "Claude Code", cwd: "/Users/me/nook")]
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/nook", in: processes))
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/nook/apps/macos", in: processes))
        XCTAssertFalse(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/nook-old", in: processes))
        XCTAssertFalse(SessionLiveness.isRunning(agent: "Codex", cwd: "/Users/me/nook", in: processes))
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/elsewhere",
                                                in: [(name: "Claude Code", cwd: "")]), "unknown folder")
    }

    func testReadsTheTailOfATranscriptFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("liveness-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try tail([prompt, reply]).write(to: url)
        XCTAssertEqual(SessionLiveness.readTurn(path: url.path)?.turn, .ended)
        XCTAssertNotNil(SessionLiveness.readTurn(path: url.path)?.modified)
        XCTAssertNil(SessionLiveness.readTurn(path: url.path + ".missing"))
        XCTAssertNil(SessionLiveness.readTurn(path: ""))
    }
}
