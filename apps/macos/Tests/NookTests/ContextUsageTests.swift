import XCTest

final class ContextUsageTests: XCTestCase {
    /// Claude Code 2.1.322's answer to `get_context_usage` (trimmed: `gridRows` and the skill list left out).
    private let claudeAnswer = """
    {"categories":[{"id":"system_prompt","name":"System prompt","tokens":3515,"kind":"used"},
    {"id":"system_tools_deferred","name":"System tools (deferred)","tokens":15823,"isDeferred":true,"kind":"deferred"},
    {"id":"messages","name":"Messages","tokens":110600,"kind":"used"},
    {"id":"new_part","name":"Something new","tokens":10,"kind":"used"},
    {"id":"autocompact_buffer","name":"Autocompact buffer","tokens":33000,"kind":"buffer"},
    {"id":"free_space","name":"Free space","tokens":837062,"kind":"free"}],
    "totalTokens":114125,"maxTokens":1000000,"memoryFiles":[{"path":"/a/CLAUDE.md","tokens":1667}],"mcpTools":[],
    "agents":[{"agentType":"a"},{"agentType":"b"}],"skills":{"totalSkills":104,"includedSkills":104,"tokens":9957}}
    """

    func testReadsClaudeCodesBreakdown() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claudeAnswer.utf8)) as? [String: Any])
        let usage = try XCTUnwrap(ContextUsage.claude(object))
        XCTAssertEqual(usage.window, 1_000_000)
        XCTAssertEqual(usage.usedTokens, 114_125)
        XCTAssertTrue(usage.detailed)
        XCTAssertEqual(usage.inWindow.map(\.id), ["system_prompt", "messages", "new_part", "autocompact_buffer", "free_space"])
        XCTAssertEqual(usage.deferred.map(\.id), ["system_tools_deferred"])
        XCTAssertEqual(usage.memoryFiles, 1)
        XCTAssertEqual(usage.mcpTools, 0)
        XCTAssertEqual(usage.agents, 2)
        XCTAssertEqual(usage.skills, 104)
        XCTAssertEqual(usage.share(usage.inWindow[1]), 0.1106, accuracy: 0.0001)
    }

    func testAnswerWithoutAWindowIsNoBreakdown() {
        XCTAssertNil(ContextUsage.claude(["categories": [], "maxTokens": 0]))
    }

    func testEstimateSplitsTheWindowAtTheAutoCompactPoint() {
        let usage = ContextUsage.estimate(used: 100_000, window: 1_000_000, autoCompactAt: 350_000)
        XCTAssertFalse(usage.detailed)
        XCTAssertEqual(usage.categories.map(\.tokens), [100_000, 650_000, 250_000])
        XCTAssertEqual(usage.categories.map(\.kind), [.used, .buffer, .free])
    }

    func testEstimateWithoutAnAutoCompactPointLeavesTheRestFree() {
        let usage = ContextUsage.estimate(used: 1_200_000, window: 1_000_000, autoCompactAt: nil)
        XCTAssertEqual(usage.categories.map(\.tokens), [1_000_000, 0, 0])
        XCTAssertEqual(usage.inWindow.map(\.id), [ContextUsage.conversation])
    }
}
