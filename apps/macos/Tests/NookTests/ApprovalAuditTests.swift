import XCTest

/// Every decision on an agent's request goes to the action log, with what it asked for and where it was decided.
final class ApprovalAuditTests: XCTestCase {
    func testADecisionNamesTheAgentTheRequestAndWhereItWasMade() {
        let entry = ApprovalAudit.entry(agent: "Codex", project: "web", tool: "Bash", asked: "npm test", decision: "allow",
                                        source: .phone, danger: false)
        XCTAssertEqual(entry.tool, "agent_approval")
        XCTAssertEqual(entry.args, "Codex · web · Bash · npm test")
        XCTAssertEqual(entry.result, "allow · phone")
    }

    func testDangerIsMarkedAndLongRequestsAreShortened() {
        let long = String(repeating: "x", count: 1_000)
        let entry = ApprovalAudit.entry(agent: "Claude Code", project: "", tool: "Bash", asked: long, decision: "deny",
                                        source: .notification, danger: true)
        XCTAssertEqual(entry.result, "deny · notification · danger")
        XCTAssertTrue(entry.args.hasSuffix("…"))
        XCTAssertLessThan(entry.args.count, 450, "the log keeps the start of a long command, not all of it")
        XCTAssertFalse(entry.args.contains(" ·  · "), "an empty field leaves no gap")
    }

    func testARequestNobodyAnsweredIsLoggedAsExpired() {
        let entry = ApprovalAudit.expired(agent: "Gemini CLI", project: "api", tool: "browser_open", asked: "https://example.com")
        XCTAssertEqual(entry.result, "expired")
        XCTAssertEqual(entry.args, "Gemini CLI · api · browser_open · https://example.com")
    }
}
