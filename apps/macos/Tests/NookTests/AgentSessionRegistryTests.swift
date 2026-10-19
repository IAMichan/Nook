import XCTest

/// One conversation is one row, wherever Nook learned about it.
final class AgentSessionRegistryTests: XCTestCase {
    private func record(_ id: String, _ sources: Set<AgentSessionRecord.Source>, conversation: String = "", pid: Int32? = nil,
                        cwd: String = "/work/app", agent: String = "Claude Code", phase: AgentSessionRecord.Phase = .working,
                        home: String = "", updated: TimeInterval = 100) -> AgentSessionRecord {
        AgentSessionRecord(id: id, sources: sources, agent: agent, accountHome: home, conversationID: conversation, pid: pid,
                           cwd: cwd, title: id, phase: phase, updated: Date(timeIntervalSince1970: updated))
    }

    func testTheSameConversationFromHookTranscriptAndRunIsOneRow() {
        let merged = AgentSessionRegistry.merge([
            record("hook", [.hook], conversation: "abc"),
            record("past", [.transcript], conversation: "abc", phase: .finished, updated: 50),
            record("run", [.nook], conversation: "abc")
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sources, [.hook, .transcript, .nook])
        XCTAssertEqual(merged[0].leading, .nook)
    }

    func testTheSameConversationInTwoAccountsStaysTwoRows() {
        let merged = AgentSessionRegistry.merge([
            record("a", [.transcript], conversation: "abc", phase: .finished),
            record("b", [.transcript], conversation: "abc", phase: .finished, home: "/Users/x/.claude-work")
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testTwoProcessesInOneFolderAreTwoRows() {
        let merged = AgentSessionRegistry.merge([
            record("p1", [.process], pid: 10, phase: .idle),
            record("p2", [.process], pid: 11, phase: .idle)
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testAHookedSessionCoversOneProcessOfItsFolderOnly() {
        let merged = AgentSessionRegistry.merge([
            record("hook", [.hook], conversation: "abc"),
            record("p1", [.process], pid: 10, phase: .idle),
            record("p2", [.process], pid: 11, phase: .idle)
        ])
        XCTAssertEqual(merged.map(\.id).sorted(), ["hook", "p2"])
    }

    func testAProcessInAnotherFolderIsNotCovered() {
        let merged = AgentSessionRegistry.merge([
            record("hook", [.hook], conversation: "abc"),
            record("p1", [.process], pid: 10, cwd: "/other", phase: .idle)
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testLiveSessionIsNotListedAgainAsEarlier() {
        let merged = AgentSessionRegistry.merge([
            record("hook", [.hook], conversation: "abc"),
            record("past", [.transcript], conversation: "abc", phase: .finished)
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].section, .active)
    }

    func testSectionsAndOrder() {
        let merged = AgentSessionRegistry.merge([
            record("old", [.transcript], conversation: "1", phase: .finished, updated: 10),
            record("busy", [.hook], conversation: "2", updated: 20),
            record("asks", [.hook], conversation: "3", phase: .needsYou, updated: 5),
            record("mine", [.nook], conversation: "4", phase: .idle, updated: 30)
        ])
        XCTAssertEqual(merged.map(\.id), ["asks", "busy", "mine", "old"])
        XCTAssertEqual(merged.map(\.section), [.needsYou, .active, .inNook, .earlier])
    }

    // MARK: Process environment

    func testEnvironmentValueWithSpaces() {
        let line = "123 /usr/local/bin/claude TERM=xterm CLAUDE_CONFIG_DIR=/Users/x/My Projects/.claude-work HOME=/Users/x"
        XCTAssertEqual(AgentProcessEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: line), "/Users/x/My Projects/.claude-work")
        XCTAssertEqual(AgentProcessEnvironment.value(of: "HOME", in: line), "/Users/x")
        XCTAssertNil(AgentProcessEnvironment.value(of: "CODEX_HOME", in: line))
    }

    func testEnvironmentValueDoesNotMatchALongerName() {
        XCTAssertNil(AgentProcessEnvironment.value(of: "HOME", in: "1 cmd CODEX_HOME=/x"))
    }

    func testNookOwnedProcessesAreRecognised() {
        XCTAssertTrue(AgentProcessEnvironment.isNookOwned("9 codex app-server PATH=/usr/bin NOOK_RUN_ID=abc"))
        XCTAssertTrue(AgentProcessEnvironment.isNookOwned("9 claude -p NOOK_INTERNAL=1"))
        XCTAssertFalse(AgentProcessEnvironment.isNookOwned("9 claude PATH=/usr/bin"))
    }
}
