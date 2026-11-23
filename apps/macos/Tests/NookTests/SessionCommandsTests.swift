import XCTest

final class SessionCommandsTests: XCTestCase {
    private func session(_ provider: RunProvider = .claude) -> WorkspaceRun {
        WorkspaceRun(id: UUID(), title: "t", task: "t", provider: provider, profileID: "p", model: "", resolvedModel: "opus",
                     mode: .agent, permission: .acceptEdits, isolation: .folder, projectPath: "/w", workingDirectory: "/w",
                     repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil, instructions: "", status: .completed,
                     statusDetail: nil, providerSessionID: nil, createdAt: Date(), updatedAt: Date(), archived: false,
                     usage: RunUsage(), turnStartedAt: nil, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil)
    }

    func testEveryAgentGetsNooksCommands() {
        for p in RunProvider.allCases {
            let list = AgentCommands.commands(for: p, hasProject: true)
            for command in NookCommand.allCases {
                XCTAssertTrue(list.contains { $0.name == command.name }, "\(p.rawValue) /\(command.name)")
            }
            XCTAssertEqual(list.first { $0.name == "status" }?.action, .session(.status))
            XCTAssertEqual(list.first { $0.name == "rename" }?.insertion, "/rename ")
            XCTAssertEqual(list.first { $0.name == "init" }?.action, .insert)
            XCTAssertEqual(Set(list.map(\.name)).count, list.count, "\(p.rawValue): one entry per name")
        }
        XCTAssertFalse(AgentCommands.commands(for: .claude, hasProject: true, surface: .chat).contains { $0.name == "status" })
    }

    func testTheAgentsOwnMemoryInitAndReviewWin() {
        let own = [AgentSlashCommand(name: "init", detail: "Analyze the project", takesInput: false),
                   AgentSlashCommand(name: "review", detail: "Review", takesInput: true),
                   AgentSlashCommand(name: "memory", detail: "Memory", takesInput: true),
                   AgentSlashCommand(name: "model", detail: "Set the model", takesInput: true)]
        let list = AgentCommands.commands(for: .gemini, hasProject: true, offered: own)
        XCTAssertEqual(list.first { $0.name == "init" }?.detail, "Analyze the project")
        XCTAssertEqual(list.first { $0.name == "memory" }?.insertion, "/memory ")
        XCTAssertEqual(list.filter { $0.name == "model" }.map(\.action), [.session(.model)], "the model stays Nook's picker")
        XCTAssertNil(SessionCommands.prompt(for: "/init", provider: .gemini, offered: own, nativeReview: false))
        XCTAssertNil(SessionCommands.prompt(for: "/review", provider: .gemini, offered: own, nativeReview: false))
    }

    func testTypedCommands() {
        XCTAssertEqual(SessionCommands.action(in: " /status ")?.command, .status)
        XCTAssertEqual(SessionCommands.action(in: "/Model")?.command, .model)
        XCTAssertEqual(SessionCommands.action(in: "/rename New name")?.rest, "New name")
        XCTAssertNil(SessionCommands.action(in: "/memory add use tabs"), "words after it: the agent's own command")
        XCTAssertNil(SessionCommands.action(in: "/init"), "a prompt, not Nook's action")
        XCTAssertNil(SessionCommands.action(in: "/statusline"))
        XCTAssertNil(SessionCommands.action(in: "what is /status"))
    }

    func testInitAndReviewPrompts() {
        let claudeInit = SessionCommands.prompt(for: "/init", provider: .cursor, offered: [], nativeReview: false)
        XCTAssertTrue(claudeInit?.hasPrefix("Generate a file named AGENTS.md") == true)
        XCTAssertTrue(SessionCommands.prompt(for: "/init", provider: .antigravity, offered: [], nativeReview: false)?
            .hasPrefix("Generate a file named GEMINI.md") == true)
        XCTAssertEqual(SessionCommands.prompt(for: "/review", provider: .pi, offered: [], nativeReview: false), SessionCommands.reviewPrompt)
        XCTAssertEqual(SessionCommands.prompt(for: "/review the parser", provider: .pi, offered: [], nativeReview: false),
                       SessionCommands.reviewPrompt + "\n\nFocus: the parser")
        XCTAssertNil(SessionCommands.prompt(for: "/review", provider: .codex, offered: [], nativeReview: true), "Codex reviews itself")
        XCTAssertNotNil(SessionCommands.prompt(for: "/init", provider: .codex, offered: [], nativeReview: true))
        XCTAssertNil(SessionCommands.prompt(for: "/init now", provider: .codex, offered: [], nativeReview: true))
        XCTAssertNil(SessionCommands.prompt(for: "fix /review", provider: .pi, offered: [], nativeReview: false))
        XCTAssertNil(SessionCommands.prompt(for: "/init", provider: .claude, offered: [], nativeReview: false), "Claude Code's own")
        XCTAssertNil(SessionCommands.prompt(for: "/review", provider: .claude, offered: [], nativeReview: false))
    }

    func testCodexReviewTargets() {
        XCTAssertEqual(SessionCommands.codexReviewTarget("/review")?["type"] as? String, "uncommittedChanges")
        let base = SessionCommands.codexReviewTarget("/review base main")
        XCTAssertEqual(base?["type"] as? String, "baseBranch")
        XCTAssertEqual(base?["branch"] as? String, "main")
        XCTAssertEqual(SessionCommands.codexReviewTarget("/review commit abc123")?["sha"] as? String, "abc123")
        let custom = SessionCommands.codexReviewTarget("/review the error handling in Parser.swift")
        XCTAssertEqual(custom?["type"] as? String, "custom")
        XCTAssertEqual(custom?["instructions"] as? String, "the error handling in Parser.swift")
        XCTAssertNil(SessionCommands.codexReviewTarget("please /review"))
    }

    func testCodexReviewFindingsShowOnce() {
        // As Codex 0.171 sends a review: the findings in `exitedReviewMode`, then again as the turn's answer.
        func events(_ line: String) -> [CodexStreamEvent] { CodexAppServerMapper.events(CodexRPC.parse(line)!) }
        XCTAssertEqual(events(#"{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"type":"exitedReviewMode","id":"r1","review":"[P1] add() subtracts."}}}"#), [])
        XCTAssertEqual(events(#"{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"type":"agentMessage","id":"m1","text":"[P1] add() subtracts.","phase":"final_answer"}}}"#),
                       [.messageCompleted(id: "m1", text: "[P1] add() subtracts.")])
    }

    func testInstructionFiles() {
        XCTAssertEqual(SessionCommands.instructionFiles(.claude).first, "CLAUDE.md")
        XCTAssertEqual(SessionCommands.instructionFiles(.codex), ["AGENTS.md"])
        let found = SessionCommands.existingInstructions(.gemini, folder: "/p") { $0 == "/p/AGENTS.md" }
        XCTAssertEqual(found, "/p/AGENTS.md")
        XCTAssertNil(SessionCommands.existingInstructions(.claude, folder: "/p") { _ in false })
    }

    func testStatusRows() {
        var r = session()
        r.effort = "high"
        r.branch = "feature"
        r.providerSessionID = "abc"
        let rows = SessionCommands.statusRows(r)
        XCTAssertTrue(rows.allSatisfy { $0.count == 2 })
        XCTAssertTrue(rows.contains { $0.last == "opus" }, "the model the agent reported when none was picked")
        XCTAssertTrue(rows.contains { $0.last == "high" })
        XCTAssertTrue(rows.contains { $0.last == "feature" })
        XCTAssertTrue(rows.contains { $0.last == "abc" })
        let event = SessionCommands.statusEvent(r)
        XCTAssertEqual(SessionCommands.statusRows(in: event), rows)
    }
}
