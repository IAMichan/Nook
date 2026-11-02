import XCTest

/// Agents whose only deciding hook runs before every tool call (Copilot CLI): Nook asks only where the agent would.
final class PreToolGateTests: XCTestCase {
    func testAsksWhereTheAgentWouldAsk() {
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "bash", input: ["command": "rm -rf build"]))
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "edit", input: ["path": "a.swift"]))
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "web_fetch", input: ["url": "https://example.com"]))
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "mcp__github__create_issue", input: [:]))
        XCTAssertTrue(PreToolGate.wouldAsk(tool: "bash", input: [:]), "a command Nook cannot read is asked about")
    }

    func testLeavesHarmlessCallsAlone() {
        XCTAssertFalse(PreToolGate.wouldAsk(tool: "bash", input: ["command": "ls"]))
        XCTAssertFalse(PreToolGate.wouldAsk(tool: "view", input: ["path": "a.swift"]))
        XCTAssertFalse(PreToolGate.wouldAsk(tool: "glob", input: ["pattern": "*.swift"]))
    }

    func testAlwaysCoversTheProgramOrTheTool() {
        XCTAssertEqual(PreToolGate.grant(tool: "bash", input: ["command": "git push origin main"]), "bash:git")
        XCTAssertEqual(PreToolGate.grant(tool: "Edit", input: ["path": "a.swift"]), "edit")
    }

    func testAnAgentStartedToAllowEverythingIsNotAsked() {
        XCTAssertTrue(PreToolGate.allowsEverything(["copilot", "--allow-all-tools"]))
        XCTAssertTrue(PreToolGate.allowsEverything(["copilot", "--yolo", "-p", "fix it"]))
        XCTAssertFalse(PreToolGate.allowsEverything(["copilot", "--allow-tool", "shell(git)"]))
    }
}
