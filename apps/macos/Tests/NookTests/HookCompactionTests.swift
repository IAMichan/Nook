import XCTest

/// A compaction of a session in a terminal, as its hooks report it: when it starts and ends, when the transcript shows it
/// done, and which installs lack the hooks for it. Nothing here reads or writes an agent's real configuration.
final class HookCompactionTests: XCTestCase {
    private let marker = "nook-hook"

    private func ours(_ value: Any) -> Bool { "\(value)".contains(marker) }

    private func group(_ command: String) -> [[String: Any]] {
        [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
    }

    func testEveryAgentsNameStartsOrEndsACompaction() {
        // Gemini CLI says PreCompress, Cursor and Copilot CLI preCompact: all start one, like Claude Code's PreCompact.
        for name in ["PreCompact", "PreCompress", "preCompact"] {
            XCTAssertEqual(HookCompaction.change(kind: HookCompaction.canonical[name] ?? name), .start, name)
        }
        XCTAssertEqual(HookCompaction.canonical["postCompact"], "PostCompact")
        // Its end, and anything else the agent does afterwards, ends it.
        for kind in ["PostCompact", "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "StopFailure",
                     "Interrupt", "Notification"] {
            XCTAssertEqual(HookCompaction.change(kind: kind), .end, kind)
        }
    }

    func testACompactionNoEventEndsStopsShowingAfterTheTimeout() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(HookCompaction.isLive(since: nil, now: start))
        XCTAssertTrue(HookCompaction.isLive(since: start, now: start.addingTimeInterval(60)))
        XCTAssertFalse(HookCompaction.isLive(since: start, now: start.addingTimeInterval(HookCompaction.timeout)))
    }

    func testTheCompactedNoticeInTheTranscriptEndsIt() {
        let start = Date(timeIntervalSince1970: 1_000)
        let prompt = AgentChatMessage(id: "u", kind: .user, text: "Go on", date: start.addingTimeInterval(-60))
        let earlier = AgentChatMessage(id: "c0", notice: .compacted(tokens: nil), date: start.addingTimeInterval(-3_600))
        XCTAssertFalse(HookCompaction.finished([earlier, prompt], since: start), "an earlier compaction is not this one")
        let done = AgentChatMessage(id: "c1", notice: .compacted(tokens: 180_000), date: start.addingTimeInterval(30))
        XCTAssertTrue(HookCompaction.finished([earlier, prompt, done], since: start))
        // A transcript's time to the second can lie just before the hook came in.
        let rounded = AgentChatMessage(id: "c2", notice: .compacted(tokens: nil), date: start.addingTimeInterval(-0.5))
        XCTAssertTrue(HookCompaction.finished([prompt, rounded], since: start))
        // Without times only a notice at the very end counts.
        let undated = AgentChatMessage(id: "c3", notice: .compacted(tokens: nil))
        XCTAssertTrue(HookCompaction.finished([AgentChatMessage(id: "p", fromUser: true, text: "Hi"), undated], since: start))
        XCTAssertFalse(HookCompaction.finished([undated, AgentChatMessage(id: "p", fromUser: true, text: "Hi")], since: start))
        XCTAssertFalse(HookCompaction.finished([], since: start))
    }

    func testAnInstallWithoutTheCompactionHooksIsOutdated() {
        let nook = "'/Users/me/.nook/nook-hook' --agent claude-code"
        var hooks: [String: Any] = ["Stop": group(nook), "PreToolUse": group(nook)]
        XCTAssertTrue(HookCompaction.lacks(HookCompaction.claudeCodeEvents, in: hooks, ours: ours))
        // The user's own PreCompact hook is not Nook's.
        hooks["PreCompact"] = group("~/bin/backup-transcript.sh")
        XCTAssertTrue(HookCompaction.lacks(HookCompaction.claudeCodeEvents, in: hooks, ours: ours))
        hooks["PreCompact"] = group("~/bin/backup-transcript.sh") + group(nook)
        XCTAssertTrue(HookCompaction.lacks(HookCompaction.claudeCodeEvents, in: hooks, ours: ours), "PostCompact is missing")
        hooks["PostCompact"] = group(nook)
        XCTAssertFalse(HookCompaction.lacks(HookCompaction.claudeCodeEvents, in: hooks, ours: ours))
    }

    func testEachAgentGetsItsOwnNameForTheHook() {
        XCTAssertEqual(HookCompaction.claudeCodeEvents, ["PreCompact", "PostCompact"])
        XCTAssertEqual(HookCompaction.codexEvents, ["PreCompact", "PostCompact"])
        XCTAssertEqual(HookCompaction.geminiEvents, ["PreCompress"])
        XCTAssertEqual(HookCompaction.cursorEvents, ["preCompact"])
        XCTAssertEqual(HookCompaction.copilotEvents, ["preCompact"])
        // Gemini CLI's hook is installed as {"PreCompress": [...]}, Cursor's as {"preCompact": [{"command": ...}]}.
        let gemini: [String: Any] = ["PreCompress": group("nook-hook --agent gemini PreCompact")]
        XCTAssertFalse(HookCompaction.lacks(HookCompaction.geminiEvents, in: gemini, ours: ours))
        let cursor: [String: Any] = ["preCompact": [["command": "nook-hook --agent cursor preCompact"]]]
        XCTAssertFalse(HookCompaction.lacks(HookCompaction.cursorEvents, in: cursor, ours: ours))
    }
}
