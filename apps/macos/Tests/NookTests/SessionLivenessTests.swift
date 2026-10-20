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

    func testSlashCommandsBetweenTurnsKeepTheTurnAsItWas() {
        let exit = #"{"type":"user","message":{"role":"user","content":"<command-name>/exit</command-name>\n<command-message>exit</command-message>\n<command-args></command-args>"}}"#
        let caveat = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: …</local-command-caveat>"}}"#
        let bye = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Goodbye!</local-command-stdout>"}}"#
        let system = #"{"type":"system","subtype":"local_command","content":"…"}"#
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, reply, caveat, exit, bye])), .ended, "/exit after the answer")
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, reply, caveat, exit, system, bye])), .ended)
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, toolCall, exit, bye])), .open, "a command run mid-turn")
        let review = #"{"type":"user","message":{"role":"user","content":"<command-message>review is running…</command-message>\n<command-name>/review</command-name>"}}"#
        let expanded = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Review the diff."}}"#
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([reply, review, expanded])), .open, "a command that prompts the agent")
    }

    func testAnApiErrorEndsTheTurn() {
        let limit = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","stop_reason":null,"content":[{"type":"text","text":"You've hit your limit"}]}}"#
        XCTAssertEqual(SessionLiveness.lastTurn(in: tail([prompt, toolCall, toolResult, limit])), .ended)
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
        let processes = [(pid: Int32(40), name: "Claude Code", cwd: "/Users/me/nook")]
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/nook", in: processes))
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/nook/apps/macos", in: processes))
        XCTAssertFalse(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/nook-old", in: processes))
        XCTAssertFalse(SessionLiveness.isRunning(agent: "Codex", cwd: "/Users/me/nook", in: processes))
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/elsewhere",
                                                in: [(pid: Int32(41), name: "Claude Code", cwd: "")]), "unknown folder")
    }

    func testAKnownProcessIsMatchedByItself() {
        let other = [(pid: Int32(50), name: "Claude Code", cwd: "/Users/me/site")]
        XCTAssertFalse(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/site", pid: 42, in: other),
                       "another session in the same folder does not keep a closed one alive")
        XCTAssertTrue(SessionLiveness.isRunning(agent: "Claude Code", cwd: "/Users/me/site", pid: 50, in: other))
        XCTAssertFalse(SessionLiveness.isRunning(agent: "Codex", cwd: "/Users/me/site", pid: 50, in: other))
    }

    func testTheAgentIsFoundAmongTheHooksParents() {
        let processes = [(pid: Int32(50), name: "Claude Code", cwd: "/a"), (pid: Int32(60), name: "Codex", cwd: "/a")]
        // The hook script, its shell, the agent, the terminal.
        XCTAssertEqual(SessionLiveness.agentProcess(agent: "Claude Code", lineage: [90, 80, 50, 10], in: processes), 50)
        XCTAssertNil(SessionLiveness.agentProcess(agent: "Claude Code", lineage: [90, 80, 60], in: processes))
        XCTAssertNil(SessionLiveness.agentProcess(agent: "Claude Code", lineage: [], in: processes))
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
