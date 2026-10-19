import XCTest

final class AgentCommandsTests: XCTestCase {
    private func names(_ p: RunProvider, project: Bool = true, surface: AgentCommands.Surface = .agent) -> [String] {
        AgentCommands.commands(for: p, hasProject: project, surface: surface).map(\.name)
    }

    func testClaudeAndCodexHaveCompactAndGoal() {
        for p in [RunProvider.claude, .codex] {
            let list = AgentCommands.commands(for: p, hasProject: true)
            XCTAssertEqual(list.first { $0.name == "compact" }?.insertion, "/compact")
            XCTAssertEqual(list.first { $0.name == "goal" }?.insertion, "/goal ")
        }
        XCTAssertFalse(names(.claude).contains("context"))
    }

    func testOtherAgentsHaveNoPassThroughs() {
        for p in RunProvider.allCases where p != .claude && p != .codex {
            XCTAssertFalse(names(p).contains("compact"))
            XCTAssertFalse(names(p).contains("goal"))
        }
    }

    func testNewOnlyInChatAndForkNeedsProject() {
        XCTAssertFalse(names(.claude).contains("new"))
        XCTAssertTrue(names(.claude, surface: .chat).contains("new"))
        XCTAssertFalse(names(.claude, project: false).contains("fork"))
        XCTAssertFalse(names(.claude, project: false).contains("compact"))
        XCTAssertTrue(names(.claude).contains("fork"))
        XCTAssertTrue(names(.claude).contains("plan"))
    }

    func testDescriptionKey() {
        let c = ComposerCommand(name: "goal", insertion: "/goal ", action: .insert)
        XCTAssertEqual(AgentCommands.descriptionKey(for: c), "composer.command.goal.description")
    }
}
