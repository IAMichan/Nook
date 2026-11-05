import XCTest

final class SessionGoalTests: XCTestCase {
    typealias G = SessionGoals

    func testCommands() {
        XCTAssertEqual(G.command(in: "/goal"), .show)
        XCTAssertEqual(G.command(in: " /goal clear\n"), .clear)
        XCTAssertEqual(G.command(in: "/goal PAUSE"), .pause)
        XCTAssertEqual(G.command(in: "/goal resume"), .resume)
        XCTAssertEqual(G.command(in: "/goal all tests pass"), .set("all tests pass"))
        XCTAssertNil(G.command(in: "/goals are nice"))
        XCTAssertNil(G.command(in: "my /goal"))
    }

    func testClaudeReportsItsGoal() {
        XCTAssertEqual(G.claude(synthetic: "Goal set: tests pass"), .set(SessionGoal(objective: "tests pass", status: .active, checks: 0)))
        XCTAssertEqual(G.claude(synthetic: "Goal cleared: tests pass"), .cleared)
        XCTAssertEqual(G.claude(synthetic: "No goal set"), .cleared)
        XCTAssertEqual(G.claude(synthetic: "Goal active: a (b) c (3 turns)"), .set(SessionGoal(objective: "a (b) c", status: .active, checks: 3)))
        XCTAssertEqual(G.claude(synthetic: "Goal active: x (not yet evaluated)"), .set(SessionGoal(objective: "x", status: .active, checks: 0)))
        XCTAssertNil(G.claude(synthetic: "Something else"))
    }

    func testParserFollowsSyntheticMessagesOnly() {
        let synthetic = #"{"type":"assistant","parent_tool_use_id":null,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Goal set: ship"}]}}"#
        XCTAssertTrue(ClaudeStreamParser.parse(synthetic).contains(.goal(.set(SessionGoal(objective: "ship", status: .active, checks: 0)))))
        let real = #"{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-opus","content":[{"type":"text","text":"Goal set: ship"}]}}"#
        XCTAssertFalse(ClaudeStreamParser.parse(real).contains { if case .goal = $0 { return true }; return false })
    }

    func testAHookCheckCountsForItsOwnGoal() {
        let goal = SessionGoal(objective: "ship", status: .active, checks: 1)
        let feedback = #"{"type":"user","isSynthetic":true,"parent_tool_use_id":null,"message":{"content":"Stop hook feedback:\n[ship]: two tests fail"}}"#
        guard case .goal(let update)? = ClaudeStreamParser.parse(feedback).first else { return XCTFail("no goal event") }
        let next = G.apply(update, to: goal)
        XCTAssertEqual(next?.checks, 2)
        XCTAssertEqual(next?.lastCheck, "two tests fail")
        XCTAssertEqual(G.apply(.check("[other]: no"), to: goal), goal)
        XCTAssertNil(G.apply(update, to: nil))
    }

    func testARepeatKeepsWhatChecksFound() {
        let checked = SessionGoal(objective: "ship", status: .active, checks: 4, lastCheck: "not yet")
        let next = G.apply(.set(SessionGoal(objective: "ship", status: .active, checks: 0)), to: checked)
        XCTAssertEqual(next?.checks, 4)
        XCTAssertEqual(next?.lastCheck, "not yet")
        XCTAssertNil(G.apply(.set(SessionGoal(objective: "new", status: .active)), to: checked)?.lastCheck)
    }

    func testCodexReportsItsGoal() {
        let update = G.codex(["objective": " ship ", "status": "budgetLimited", "tokensUsed": 12, "tokenBudget": 100, "timeUsedSeconds": 3])
        XCTAssertEqual(update, .set(SessionGoal(objective: "ship", status: .budgetLimited, tokensUsed: 12, tokenBudget: 100, timeUsedSeconds: 3)))
        XCTAssertNil(G.codex(["objective": "  "]))
        XCTAssertNil(G.codex(nil))
    }

    func testCodexNotifications() {
        let cleared = CodexAppServerMapper.events(.notification(method: "thread/goal/cleared", params: JSONBox([String: Any]())))
        XCTAssertEqual(cleared, [.goal(.cleared)])
    }
}
