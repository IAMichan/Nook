import XCTest

final class TokenSavingsTests: XCTestCase {
    // MARK: Prompt cache

    func testClaudeCacheLifetime() {
        XCTAssertEqual(PromptCache.claudeTTL(["cache_creation": ["ephemeral_1h_input_tokens": 26_000, "ephemeral_5m_input_tokens": 0]]), 3_600)
        XCTAssertEqual(PromptCache.claudeTTL(["cache_creation": ["ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 900]]), 300)
        XCTAssertNil(PromptCache.claudeTTL(["cache_creation": ["ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 0]]),
                     "a request served from the cache wrote nothing")
        XCTAssertNil(PromptCache.claudeTTL(["input_tokens": 3]))
    }

    func testStreamParserCarriesTheLifetime() {
        let usage: [String: Any] = ["input_tokens": 2, "output_tokens": 5, "cache_read_input_tokens": 15_000,
                                    "cache_creation_input_tokens": 26_000,
                                    "cache_creation": ["ephemeral_1h_input_tokens": 26_000, "ephemeral_5m_input_tokens": 0]]
        XCTAssertEqual(ClaudeStreamParser.tokens(usage).cacheTTL, 3_600)
    }

    func testARequestStartsWithItsCacheLifetime() throws {
        let line = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","usage":{"input_tokens":2,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":800}}}}}"#
        let events = ClaudeStreamParser.parse(line)
        guard case .requestStarted(let ttl)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(ttl, 300)
    }

    // MARK: Idle compaction

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func candidate(_ change: (inout IdleCompaction.Candidate) -> Void = { _ in }) -> IdleCompaction.Candidate {
        var value = IdleCompaction.Candidate(
            agentReportsCacheLifetime: true, status: .completed, archived: false, settled: false, snoozedUntil: nil,
            contextTokens: 250_000, cache: PromptCacheWindow(expiresAt: now.addingTimeInterval(3_000), ttl: 3_600),
            holdsForYou: false, isRemote: false)
        change(&value)
        return value
    }

    func testALongIdleSessionIsSummarizedJustBeforeItsCacheExpires() {
        XCTAssertEqual(IdleCompaction.fireDate(candidate(), now: now), now.addingTimeInterval(3_000 - IdleCompaction.lead))
    }

    func testAShortCacheStartsHalfwayThrough() {
        let fire = IdleCompaction.fireDate(candidate { $0.cache = PromptCacheWindow(expiresAt: self.now.addingTimeInterval(300), ttl: 300) },
                                           now: now)
        XCTAssertEqual(fire, now.addingTimeInterval(300 - IdleCompaction.lead))
        let late = IdleCompaction.fireDate(candidate { $0.cache = PromptCacheWindow(expiresAt: self.now.addingTimeInterval(30), ttl: 300) },
                                           now: now)
        XCTAssertEqual(late, now, "inside the lead it goes at once, while the cache is still warm")
    }

    func testWhatHoldsTheSummaryBack() {
        let held: [(String, IdleCompaction.Candidate)] = [
            ("an agent without a cache lifetime", candidate { $0.agentReportsCacheLifetime = false }),
            ("a short conversation", candidate { $0.contextTokens = IdleCompaction.minimumContextTokens - 1 }),
            ("no usage reported", candidate { $0.contextTokens = nil }),
            ("an expired cache", candidate { $0.cache = PromptCacheWindow(expiresAt: self.now, ttl: 3_600) }),
            ("no cache window", candidate { $0.cache = nil }),
            ("a summary already", candidate { $0.cache?.afterCompaction = true }),
            ("a failed turn", candidate { $0.status = .failed }),
            ("a stopped turn", candidate { $0.status = .stopped }),
            ("a working session", candidate { $0.status = .running }),
            ("an archived session", candidate { $0.archived = true }),
            ("a settled session", candidate { $0.settled = true }),
            ("a snoozed session", candidate { $0.snoozedUntil = self.now.addingTimeInterval(60) }),
            ("waiting on you", candidate { $0.holdsForYou = true }),
            ("another machine", candidate { $0.isRemote = true }),
        ]
        for (reason, value) in held { XCTAssertNil(IdleCompaction.fireDate(value, now: now), reason) }
        XCTAssertNotNil(IdleCompaction.fireDate(candidate { $0.snoozedUntil = self.now.addingTimeInterval(-60) }, now: now),
                        "a snooze that ended no longer holds it")
    }

    func testOnlyClaudeReportsItsCacheLifetime() {
        for provider in RunProvider.allCases {
            XCTAssertEqual(provider.capabilities.reportsPromptCacheLifetime, provider == .claude, provider.rawValue)
        }
    }

    // MARK: Tool search

    func testToolSearchIsTurnedOnUnlessYouChoseOtherwise() {
        XCTAssertEqual(ClaudeToolSearch.override(userValue: nil), "true")
        XCTAssertEqual(ClaudeToolSearch.override(userValue: "auto"), "true")
        XCTAssertEqual(ClaudeToolSearch.override(userValue: "auto:10"), "true")
        XCTAssertEqual(ClaudeToolSearch.override(userValue: "auto:x"), "true", "Claude Code reads an unreadable auto:N as auto")
        XCTAssertNil(ClaudeToolSearch.override(userValue: "auto:0"), "already on")
        XCTAssertNil(ClaudeToolSearch.override(userValue: "auto:100"), "off by your choice")
        XCTAssertNil(ClaudeToolSearch.override(userValue: "false"))
        XCTAssertNil(ClaudeToolSearch.override(userValue: "true"))
    }

    func testToolSearchReadsTheStrongestSettingsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolsearch-\(UUID().uuidString)")
        let project = folder.appendingPathComponent("project")
        let config = folder.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ClaudeToolSearch.settingsFiles(workingDirectory: project.path, configDirectory: config.path)
        XCTAssertNil(ClaudeToolSearch.userValue(in: files))
        try #"{"env":{"ENABLE_TOOL_SEARCH":"false"}}"#.write(to: config.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeToolSearch.userValue(in: files), "false")
        try #"{"env":{"ENABLE_TOOL_SEARCH":"auto"}}"#.write(to: project.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeToolSearch.userValue(in: files), "auto", "the project's settings beat your own")
    }

    // MARK: Launch

    func testClaudeSettingsCarryTheEnvironment() throws {
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentCredits.claudeSettings(omit: false).utf8)) as? [String: Any])
        XCTAssertEqual(plain["showThinkingSummaries"] as? Bool, true)
        XCTAssertNil(plain["env"])
        let json = AgentCredits.claudeSettings(omit: true, env: ["ENABLE_TOOL_SEARCH": "true"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["env"] as? [String: String])?["ENABLE_TOOL_SEARCH"], "true")
        XCTAssertEqual(object["includeCoAuthoredBy"] as? Bool, false)
        XCTAssertEqual((object["attribution"] as? [String: String])?["commit"], "")
    }

    func testClaudeLaunchFlags() throws {
        var input = AgentCommand.Input(provider: .claude, executable: "/bin/claude", prompt: "hi", model: "", mode: .agent,
                                       permission: .ask, instructions: "", workingDirectory: "/tmp", accountEnvironment: [:],
                                       runID: UUID())
        let bare = AgentCommand.spec(input).arguments
        XCTAssertFalse(try settings(bare).keys.contains("env"))
        input.toolSearch = "true"
        let lean = AgentCommand.spec(input).arguments
        XCTAssertEqual((try settings(lean)["env"] as? [String: String])?["ENABLE_TOOL_SEARCH"], "true")
    }

    private func settings(_ arguments: [String]) throws -> [String: Any] {
        let index = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any])
    }

    // MARK: Bridge

    func testASessionNookStartedGetsTheNoteOnce() {
        XCTAssertNil(BridgeLaunch.serverInstructions(startedByNook: true, remote: false), "it has the note from its launch")
        XCTAssertNil(BridgeLaunch.serverInstructions(startedByNook: true, remote: true))
        XCTAssertEqual(BridgeLaunch.serverInstructions(startedByNook: true, remote: false, agent: "codex"), BridgeLaunch.instructions,
                       "a conversation taken over from Codex has no note of its own")
        XCTAssertNil(BridgeLaunch.serverInstructions(startedByNook: true, remote: false, agent: "claude"))
        XCTAssertEqual(BridgeLaunch.serverInstructions(startedByNook: false, remote: false), BridgeLaunch.instructions)
        XCTAssertEqual(BridgeLaunch.serverInstructions(startedByNook: false, remote: true), RemoteBridge.instructions)
    }

    func testInitializeLeavesOutEmptyInstructions() async throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize"]
        let quiet = await BridgeRPC.response(to: message, instructions: nil) { _, _ in BridgeRPC.ToolResult(text: "ok") }
        XCTAssertNil((quiet?["result"] as? [String: Any])?["instructions"])
        let told = await BridgeRPC.response(to: message) { _, _ in BridgeRPC.ToolResult(text: "ok") }
        XCTAssertEqual((told?["result"] as? [String: Any])?["instructions"] as? String, BridgeLaunch.instructions)
    }

    /// Every request of a session carries the note, and the tool list until tool search defers it. A new tool or rule
    /// earns its bytes: raise a budget here only with a reason in the commit.
    func testBridgeBudget() throws {
        XCTAssertLessThanOrEqual(BridgeLaunch.instructions.utf8.count, 1_400, "the bridge note")
        XCTAssertLessThanOrEqual(RemoteBridge.instructions.utf8.count, 700, "the note for another machine")
        let tools = try JSONSerialization.data(withJSONObject: BridgeTool.allCases.map(\.definition), options: [.sortedKeys])
        // 33,741 bytes for 43 tools on 2026-11-07. Claude Code defers them behind tool search; Codex and the ACP agents
        // send them with every request. 36,195 bytes on 2026-11-10 after the t3code parity packages: render_page takes a
        // file path, request_secret a url and a delivery, scheduled tasks a target and a conversation, delegate_task `@` models.
        // 37,991 bytes later that day: session_wait, and session_start/session_send as t3code's create_threads,
        // t3_thread_launch and t3_thread_send (several sessions, a place, idle starts, send modes).
        XCTAssertLessThanOrEqual(tools.count, 38_200, "the tool list")
    }

    private func size(_ setting: Int = 350_000, tokens: Int?, window: Int? = 1_000_000, can: Bool = true, completed: Bool = true,
                      holds: Bool = false, remote: Bool = false, compacted: Bool = false) -> Bool {
        SizeCompaction.shouldCompact(setting: setting, contextTokens: tokens, contextWindow: window, canCompact: can,
                                     completed: completed, holdsForYou: holds, isRemote: remote, alreadyCompacted: compacted)
    }

    func testASessionPastYourLimitIsSummarizedWhenItsTurnEnds() {
        XCTAssertTrue(size(tokens: 350_000))
        XCTAssertFalse(size(tokens: 349_999))
        XCTAssertFalse(size(0, tokens: 900_000), "off")
        XCTAssertFalse(size(tokens: nil))
    }

    func testASmallWindowIsSummarizedBeforeItIsFull() {
        XCTAssertEqual(SizeCompaction.limit(setting: 350_000, contextWindow: 200_000), 160_000)
        XCTAssertEqual(SizeCompaction.limit(setting: 350_000, contextWindow: nil), 350_000)
        XCTAssertTrue(size(tokens: 170_000, window: 200_000))
    }

    func testSizeCompactionLeavesWhatWaitsForYouAlone() {
        XCTAssertFalse(size(tokens: 500_000, can: false))
        XCTAssertFalse(size(tokens: 500_000, completed: false))
        XCTAssertFalse(size(tokens: 500_000, holds: true))
        XCTAssertFalse(size(tokens: 500_000, remote: true))
        XCTAssertFalse(size(tokens: 500_000, compacted: true))
    }
}
