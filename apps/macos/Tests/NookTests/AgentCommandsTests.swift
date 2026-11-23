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
            // Pi compacts through its own command, but has no goal.
            XCTAssertEqual(names(p).contains("compact"), p == .pi)
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

    func testMcpIsNooksForTheAgentsThatReportTheirServers() {
        for p in RunProvider.allCases {
            let mcp = AgentCommands.commands(for: p, hasProject: true).first { $0.name == "mcp" }
            XCTAssertEqual(mcp?.action, AgentCommands.reportsMcpStatus(p) ? .mcp : nil, p.rawValue)
        }
        XCTAssertTrue(AgentCommands.reportsMcpStatus(.claude))
        XCTAssertTrue(AgentCommands.reportsMcpStatus(.codex))
        XCTAssertTrue(AgentCommands.reportsMcpStatus(.opencode))
        // An agent that announces its own /mcp keeps it when Nook cannot ask for the list.
        let own = [AgentSlashCommand(name: "mcp", detail: "List servers", takesInput: false)]
        XCTAssertEqual(AgentCommands.commands(for: .gemini, hasProject: true, offered: own).first { $0.name == "mcp" }?.action, .insert)
        XCTAssertFalse(names(.claude, surface: .chat).contains("mcp"))
    }

    func testClaudeCommandsFromItsInitializeReply() {
        let raw: [[String: Any]] = [
            ["name": "context", "description": "Show current context usage", "argumentHint": "", "builtin": true],
            ["name": "mcp", "description": "Manage MCP servers", "argumentHint": "[reconnect|enable|disable [<server>|all]]"],
            ["name": "model", "description": "Set the AI model for Claude Code", "argumentHint": "<model>"],
            ["name": "agents", "description": "(removed) Ask Claude to create/manage subagents", "argumentHint": ""],
            ["name": "__remote-workflow", "description": "internal"],
            ["name": "deploy", "description": "Deploy the site (user)", "argumentHint": "<env>"],
            ["name": "context", "description": "duplicate"],
        ]
        let commands = AgentSlashCommand.claude(raw)
        XCTAssertEqual(commands.map(\.name), ["context", "mcp", "deploy"])
        XCTAssertEqual(commands.first?.detail, "Show current context usage")
        XCTAssertFalse(commands[0].takesInput)
        XCTAssertTrue(commands[2].takesInput)
        // Nook's own /mcp stays Nook's; the agent's others go to it as a prompt.
        let list = AgentCommands.commands(for: .claude, hasProject: true, offered: commands)
        XCTAssertEqual(list.filter { $0.name == "mcp" }.map(\.action), [.mcp])
        XCTAssertEqual(list.first { $0.name == "context" }?.insertion, "/context")
        XCTAssertEqual(list.first { $0.name == "deploy" }?.insertion, "/deploy ")
    }

    func testDescriptionKey() {
        let c = ComposerCommand(name: "goal", insertion: "/goal ", action: .insert)
        XCTAssertEqual(AgentCommands.descriptionKey(for: c), "composer.command.goal.description")
    }

    func testStartCommandsArePlanAndTheAgentsOwn() {
        let own = [AgentSlashCommand(name: "brand-voice:enforce-voice", detail: "(brand-voice) Apply guidelines", takesInput: true),
                   AgentSlashCommand(name: "init", detail: nil, takesInput: false)]
        let list = AgentCommands.startCommands(for: .claude, offered: own)
        XCTAssertEqual(list.map(\.name), ["plan", "brand-voice:enforce-voice", "init"])
        XCTAssertEqual(list[1].insertion, "/brand-voice:enforce-voice ")
        XCTAssertEqual(list[2].insertion, "/init")
        XCTAssertFalse(list.contains { $0.name == "status" || $0.name == "fork" }, "session commands need a running session")
    }

    func testCommandMemoryKeepsTheLastListPerAgent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentCommandMemoryTests"))
        defaults.removePersistentDomain(forName: "AgentCommandMemoryTests")
        let own = [AgentSlashCommand(name: "review-pr", detail: "Review", takesInput: true)]
        AgentCommandMemory.remember(own, for: .claude, defaults: defaults)
        AgentCommandMemory.remember([], for: .claude, defaults: defaults)
        XCTAssertEqual(AgentCommandMemory.recalled(for: .claude, defaults: defaults), own, "an empty list does not wipe it")
        XCTAssertEqual(AgentCommandMemory.recalled(for: .codex, defaults: defaults), [])
        defaults.removePersistentDomain(forName: "AgentCommandMemoryTests")
    }
}
