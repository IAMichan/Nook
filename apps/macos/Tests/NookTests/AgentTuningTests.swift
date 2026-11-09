import XCTest

final class AgentTuningTests: XCTestCase {
    private var home: URL!
    private let now = Date()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tuning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func millis(daysAgo: Double) -> Int { Int((now.timeIntervalSince1970 - daysAgo * 86_400) * 1000) }

    private func skill(_ name: String, _ description: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n"
    }

    // MARK: Claude Code

    private func claudeHome(connectorUsed: Bool) throws {
        try write(".claude/plugins/synced/acct/manifest.json", #"{"plugins":[{"name":"sales"},{"name":"engineering"},{"name":"design"}]}"#)
        try write(".claude/plugins/synced/acct/sales/skills/forecast/SKILL.md", skill("forecast", "Write the forecast narrative."))
        try write(".claude/plugins/synced/acct/engineering~g2/skills/debug/SKILL.md", skill("debug", "Structured debugging."))
        try write(".claude/plugins/synced/acct/design/skills/critique/SKILL.md", skill("critique", "Design feedback."))
        try write(".claude/settings.json", #"{"enabledPlugins":{"design@inline":false}}"#)
        try write(".claude.json", """
        {"pluginUsage":{"sales@inline":{"usageCount":0,"lastUsedAt":\(millis(daysAgo: 1))},
                        "engineering@inline":{"usageCount":4,"lastUsedAt":\(millis(daysAgo: 2))}},
         "skillUsage":{"sales:forecast":{"usageCount":1,"lastUsedAt":\(millis(daysAgo: 45))}},
         "claudeAiMcpEverConnected":["claude.ai Gmail","claude.ai Claude Docs"],
         "mcpServers":{"elementor":{},"old-server":{}},
         "autoCompactEnabled":false}
        """)
        var calls = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"mcp__elementor__list","input":{}}]}}"# + "\n"
        if connectorUsed { calls += #"{"message":{"content":[{"type":"tool_use","id":"toolu_2","name":"mcp__claude_ai_Claude_Docs__read","input":{}}]}}"# + "\n" }
        // A tool list in a request names tools without calling them.
        calls += #"{"type":"api-request-shape","shape":{"tools":[{"name":"mcp__old-server__x"}]}}"# + "\n"
        try write(".claude/projects/p/s.jsonl", calls)
    }

    func testClaudeSuggestsWhatYouDoNotUse() throws {
        try claudeHome(connectorUsed: false)
        let advice = AgentTuning.claude(home: home, now: now)
        let plugins = try XCTUnwrap(advice.first { $0.kind == .unusedPlugins })
        XCTAssertEqual(plugins.items, ["sales@inline"], "engineering is used, design is off already")
        XCTAssertTrue(plugins.appliesInNook)
        XCTAssertGreaterThan(plugins.characters ?? 0, 0)
        XCTAssertTrue(plugins.snippet?.contains("\"sales@inline\" : false") == true, plugins.snippet ?? "")

        let connectors = try XCTUnwrap(advice.first { $0.kind == .cloudConnectors })
        XCTAssertEqual(connectors.items, ["claude.ai Gmail", "claude.ai Claude Docs"])
        XCTAssertTrue(connectors.appliesInNook)

        let servers = try XCTUnwrap(advice.first { $0.kind == .unusedServers })
        XCTAssertEqual(servers.items, ["old-server"], "a tool list in a request is not a call")
        XCTAssertNotNil(advice.first { $0.kind == .autoCompactOff })
    }

    func testAConnectorInUseKeepsTheSwitchOn() throws {
        try claudeHome(connectorUsed: true)
        let connectors = try XCTUnwrap(AgentTuning.claude(home: home, now: now).first { $0.kind == .cloudConnectors })
        XCTAssertEqual(connectors.items, ["claude.ai Gmail"])
        XCTAssertEqual(connectors.kept, ["claude.ai Claude Docs"])
        XCTAssertFalse(connectors.appliesInNook, "turning all off would take the one you use")
        XCTAssertTrue(connectors.location.hasPrefix("https://claude.ai/"))
    }

    func testAPluginSyncedTwiceIsCountedOnce() throws {
        try claudeHome(connectorUsed: false)
        try write(".claude/plugins/synced/acct2/manifest.json", #"{"plugins":[{"name":"sales"}]}"#)
        try write(".claude/plugins/synced/acct2/sales/skills/forecast/SKILL.md", skill("forecast", "Write the forecast narrative."))
        let plugins = try XCTUnwrap(AgentTuning.claude(home: home, now: now).first { $0.kind == .unusedPlugins })
        XCTAssertEqual(plugins.items, ["sales@inline"])
    }

    func testWhatYouAppliedStaysListed() {
        var applied = AgentTuning.Applied()
        applied.claudePlugins = ["sales@inline", "marketing@inline"]
        applied.claudeNoConnectors = true
        let now = [TuningAdvice(provider: .claude, kind: .unusedPlugins, items: ["sales@inline"], location: "", appliesInNook: true)]
        let rows = AgentTuning.withApplied(now, applied: applied, settingsFile: "/s")
        XCTAssertEqual(rows.filter { $0.kind == .unusedPlugins }.map(\.items), [["sales@inline"], ["marketing@inline"]],
                       "marketing was used since, but is still off in Nook's sessions until you turn it on")
        XCTAssertTrue(rows.allSatisfy(applied.isApplied))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testAppliedSuggestionsReachClaudesSettings() throws {
        var applied = AgentTuning.Applied()
        let plugins = TuningAdvice(provider: .claude, kind: .unusedPlugins, items: ["sales@inline"], location: "", appliesInNook: true)
        let connectors = TuningAdvice(provider: .claude, kind: .cloudConnectors, items: ["claude.ai Gmail"], location: "", appliesInNook: true)
        applied.set(plugins, on: true)
        applied.set(connectors, on: true)
        XCTAssertTrue(applied.isApplied(plugins))
        let json = AgentCredits.claudeSettings(omit: false, extra: applied.claudeSettings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["enabledPlugins"] as? [String: Bool])?["sales@inline"], false)
        XCTAssertEqual(object["disableClaudeAiConnectors"] as? Bool, true)
        XCTAssertEqual(object["showThinkingSummaries"] as? Bool, true)
        applied.set(plugins, on: false)
        XCTAssertFalse(applied.isApplied(plugins))
        XCTAssertNil(applied.claudeSettings["enabledPlugins"])
    }

    // MARK: Other agents

    func testCodexServers() throws {
        try write(".codex/config.toml", """
        model = "gpt-5"
        [mcp_servers.github] # the work one
        command = "gh-mcp"
        [mcp_servers.github.env]
        TOKEN = "x"
        [mcp_servers."my server"]
        command = "a"
        [mcp_servers.off]
        command = "b"
        enabled	=	false # not now
        [mcp_servers."büro"]
        command = "c"
        [projects."/tmp"]
        trust_level = "trusted"
        """)
        let advice = try XCTUnwrap(AgentTuning.codex(home: home).first)
        XCTAssertEqual(advice.kind, .servers)
        XCTAssertEqual(advice.items, ["büro", "github", "my server"], "a comment after a header or a value is no part of it")
        let snippet = try XCTUnwrap(advice.snippet)
        XCTAssertFalse(snippet.contains("\n[mcp_servers"), "a table named twice makes the file invalid")
        XCTAssertTrue(snippet.contains("[mcp_servers.\"my server\"] table, add:\nenabled = false"), snippet)
        XCTAssertTrue(snippet.contains("[mcp_servers.\"büro\"]"), "a bare key is ASCII only")
        XCTAssertEqual(CodexConfig.key("github-2"), "github-2")
        XCTAssertFalse(advice.appliesInNook)
    }

    func testGeminiOpenCodeCursorAntigravity() throws {
        try write(".gemini/settings.json", #"{"mcpServers":{"a":{},"b":{}},"mcp":{"excluded":["b"]}}"#)
        XCTAssertEqual(AgentTuning.gemini(home: home).first?.items, ["a"])
        XCTAssertTrue(AgentTuning.gemini(home: home).first?.snippet?.contains("\"a\"") == true)

        try write(".config/opencode/opencode.jsonc", "{\n  // mine\n  \"mcp\": {\"x\": {\"type\": \"local\"}, \"y\": {\"enabled\": false},},\n}")
        XCTAssertEqual(AgentTuning.opencode(home: home).first?.items, ["x"])

        try write(".cursor/mcp.json", #"{"mcpServers":{"z":{"command":"z"}}}"#)
        try write(".gemini/antigravity/mcp_config.json", #"{"mcpServers":{"q":{"disabled":true}}}"#)
        let all = AgentTuning.scan(home: home, now: now)
        XCTAssertEqual(all.first { $0.provider == .cursor }?.items, ["z"])
        XCTAssertNil(all.first { $0.provider == .antigravity }, "a server turned off already")
    }

    func testLongInstructions() throws {
        try write(".codex/AGENTS.md", String(repeating: "Be brief. ", count: 1_000))
        let advice = try XCTUnwrap(AgentTuning.codex(home: home).first { $0.kind == .longInstructions })
        XCTAssertEqual(advice.characters, 10_000)
        XCTAssertEqual(advice.tokens, 2_500)
        try write(".gemini/GEMINI.md", "Short.")
        XCTAssertTrue(AgentTuning.gemini(home: home).isEmpty)
    }

    func testAnEmptyHomeHasNothingToSay() {
        XCTAssertTrue(AgentTuning.scan(home: home, now: now).isEmpty)
    }

    // MARK: Parsing

    func testJSONCKeepsStrings() {
        let text = #"{"url": "https://x.dev/a//b", /* c */ "list": [1, 2,], // end"# + "\n}"
        XCTAssertEqual(AgentTuning.jsonObject(JSONC.strip(text))?["url"] as? String, "https://x.dev/a//b")
    }

    func testConnectorKeys() {
        XCTAssertEqual(TranscriptToolUse.serverKey(connector: "claude.ai Google Drive"), "claude_ai_Google_Drive")
    }
}
