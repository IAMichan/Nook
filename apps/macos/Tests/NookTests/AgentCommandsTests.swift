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

    func testAnAgentsOwnCommandsJoinTheList() {
        let offered = [AgentSlashCommand(name: "web", detail: "Search the web", takesInput: true),
                       AgentSlashCommand(name: "plan", detail: "The agent's plan", takesInput: false),
                       AgentSlashCommand(name: "init", detail: nil, takesInput: false)]
        for p in RunProvider.allCases {
            let list = AgentCommands.commands(for: p, hasProject: true, offered: offered)
            XCTAssertEqual(list.first { $0.name == "web" }?.insertion, "/web ")
            XCTAssertEqual(list.first { $0.name == "web" }?.detail, "Search the web")
            XCTAssertEqual(list.first { $0.name == "init" }?.insertion, "/init")
            XCTAssertEqual(list.first { $0.name == "init" }?.detail, "", "no description: none shown, not an I18n key")
            let plan = list.filter { $0.name == "plan" }
            XCTAssertEqual(plan.count, 1, "one /plan")
            XCTAssertEqual(plan.first?.action, p.capabilities.planMode ? .plan : .insert, "Nook's own /plan stays Nook's")
        }
        XCTAssertFalse(AgentCommands.commands(for: .gemini, hasProject: false, offered: offered).contains { $0.name == "web" })
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
