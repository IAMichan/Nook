import XCTest

/// Tools per agent: the user switches groups of Nook's tools off for one agent, for its sessions in Nook and when it is
/// linked in a terminal alike.
final class BridgeAccessTests: XCTestCase {
    func testEveryToolBelongsToAGroupExceptTheDescription() {
        for tool in BridgeTool.allCases where tool != .workspaceInfo {
            XCTAssertNotNil(tool.capability, tool.rawValue)
        }
        XCTAssertNil(BridgeTool.workspaceInfo.capability, "every agent may always ask what the bridge offers")
        for capability in BridgeCapability.allCases {
            XCTAssertTrue(BridgeTool.allCases.contains { $0.capability == capability }, "an empty group: \(capability)")
        }
    }

    func testAGroupSwitchedOffForOneAgentStaysOnForTheOthers() {
        var access = BridgeAccess()
        XCTAssertTrue(access.allows(.terminalRun, agent: "codex"), "everything is on until the user switches it off")
        access.set(.terminal, on: false, agent: "codex")
        XCTAssertFalse(access.allows(.terminalRun, agent: "codex"))
        XCTAssertFalse(access.allows(.terminalRead, agent: "codex"), "the whole group goes")
        XCTAssertTrue(access.allows(.browserOpen, agent: "codex"))
        XCTAssertTrue(access.allows(.terminalRun, agent: "claude"))
        XCTAssertTrue(access.allows(.workspaceInfo, agent: "codex"))
        access.set(.terminal, on: true, agent: "codex")
        XCTAssertEqual(access, BridgeAccess(), "switching it on again leaves nothing behind")
    }

    func testStoredAsTheGroupsSwitchedOff() {
        var access = BridgeAccess()
        access.set(.screen, on: false, agent: "gemini")
        access.set(.secrets, on: false, agent: "gemini")
        XCTAssertEqual(access.stored, ["gemini": ["screen", "secrets"]])
        XCTAssertEqual(BridgeAccess(stored: access.stored), access)
        XCTAssertEqual(BridgeAccess(stored: ["gemini": ["unknown"]]), BridgeAccess(), "a group a newer Nook knew is ignored")
    }

    func testTerminalAgentsAreKnownByTheNameTheyGiveTheBridge() {
        XCTAssertEqual(BridgeAccess.agentKey(forClient: "claude-code"), RunProvider.claude.rawValue)
        XCTAssertEqual(BridgeAccess.agentKey(forClient: "codex"), RunProvider.codex.rawValue)
        XCTAssertEqual(BridgeAccess.agentKey(forClient: "Gemini"), RunProvider.gemini.rawValue)
        XCTAssertEqual(BridgeAccess.agentKey(forClient: "something-else"), "something-else")
        XCTAssertTrue(BridgeAccess.refusal(.terminalRun, agent: "Codex").contains("Settings › Automation"))
    }
}
