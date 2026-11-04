import XCTest

/// The "Auto" access level per agent, restarting a session's agent, and side chats: the pure decisions behind them.
final class AgentSessionToolsTests: XCTestCase {
    // MARK: Auto access level

    func testMovingToAnotherAgentNeverWidensWhatASessionMayDo() {
        let withoutAuto: [PermissionPolicy] = [.ask, .acceptEdits, .bypass]
        XCTAssertEqual(PermissionPolicy.auto.steppedDown(within: withoutAuto), .acceptEdits)
        XCTAssertEqual(PermissionPolicy.bypass.steppedDown(within: withoutAuto), .bypass)
        XCTAssertEqual(PermissionPolicy.acceptEdits.steppedDown(within: [.ask, .bypass]), .ask)
        XCTAssertEqual(PermissionPolicy.auto.steppedDown(within: []), .ask)
    }

    func testAutoIsOfferedOnlyWhereTheAgentHasItsOwnReviewer() {
        for provider in RunProvider.allCases {
            let offered = provider.capabilities.policies.contains(.auto)
            switch provider {
            case .claude, .codex: XCTAssertTrue(offered, provider.rawValue)
            case .gemini, .opencode, .cursor, .grok, .antigravity, .acp: XCTAssertFalse(offered, provider.rawValue)
            }
        }
    }

    func testAutoRanksBetweenEditsAndEverything() {
        XCTAssertEqual(PermissionPolicy.allCases.sorted { $0.rank < $1.rank }, [.ask, .acceptEdits, .auto, .bypass])
        XCTAssertEqual(PermissionPolicy.allCases.filter(\.isUnattendedSafe), [.ask, .acceptEdits],
                       "a phone-started or scheduled session never runs with a reviewer nobody watches")
    }

    func testAutoMapsToEachAgentsOwnMode() {
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .agent, permission: .auto), "auto")
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .plan, permission: .auto), "plan")
        XCTAssertEqual(AgentCommand.codexSandbox(mode: .agent, permission: .auto), "workspace-write")
        XCTAssertEqual(AgentCommand.geminiApprovalMode(mode: .agent, permission: .auto), "auto_edit",
                       "Gemini CLI has no reviewer: an old setting only edits")
    }

    func testCodexAutoRoutesApprovalsToItsReviewer() {
        let auto = CodexRPC.turnStartParams(threadID: "t", text: "x", cwd: "/w", model: "", mode: .agent, permission: .auto, planModel: nil)
        XCTAssertEqual(auto["approvalsReviewer"] as? String, "auto_review")
        XCTAssertEqual(auto["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual((auto["sandboxPolicy"] as? [String: Any])?["type"] as? String, "workspaceWrite")
        let plan = CodexRPC.turnStartParams(threadID: "t", text: "x", cwd: "/w", model: "", mode: .plan, permission: .auto, planModel: nil)
        XCTAssertEqual(plan["approvalsReviewer"] as? String, "user")
        for policy in [PermissionPolicy.ask, .acceptEdits, .bypass] {
            XCTAssertEqual(CodexRPC.reviewer(mode: .agent, permission: policy), "user", policy.rawValue)
        }
    }

    func testAutoAnswersOnlyEditsInNook() {
        XCTAssertTrue(LiveRights.coversClaude(tool: "Edit", permission: .auto, mode: .agent))
        XCTAssertFalse(LiveRights.coversClaude(tool: "Bash", permission: .auto, mode: .agent),
                       "what Claude Code's reviewer passes on is risky: you decide")
        XCTAssertFalse(LiveRights.coversCodex(.command, permission: .auto, mode: .agent))
        XCTAssertTrue(LiveRights.coversCodex(.fileChange, permission: .auto, mode: .agent))
    }

    func testDelegationAndSchedulesDoNotEscalateThroughAuto() {
        let all = PermissionPolicy.allCases
        XCTAssertEqual(DelegationPolicy.resolve(parentMode: .agent, parentPermission: .acceptEdits, mode: nil, permission: .auto,
                                                role: .implementation, offered: all), .failure(.escalation("rights")))
        XCTAssertEqual(try DelegationPolicy.resolve(parentMode: .agent, parentPermission: .auto, mode: nil, permission: nil,
                                                    role: .implementation, offered: all).get().permission, .auto)
        XCTAssertEqual(try DelegationPolicy.resolve(parentMode: .agent, parentPermission: .bypass, mode: nil, permission: .auto,
                                                    role: .implementation, offered: all).get().permission, .auto)
        if case .success = BridgeScheduleArguments.permission("auto", caller: .bypass) {
            XCTFail("a scheduled task never runs with auto rights")
        }
    }

    // MARK: Restart agent

    func testRestartResumesWhereTheAgentCan() {
        XCTAssertEqual(AgentRestart.plan(hasConversation: false, canResume: true), .fresh)
        XCTAssertEqual(AgentRestart.plan(hasConversation: true, canResume: true), .resume)
        XCTAssertEqual(AgentRestart.plan(hasConversation: true, canResume: nil), .resume,
                       "unknown: try, the agent's own 'session gone' answer still carries the conversation over")
        XCTAssertEqual(AgentRestart.plan(hasConversation: true, canResume: false), .summary)
    }

    func testEveryAgentAnswersHowItResumes() {
        for provider in RunProvider.allCases {
            let native = AgentRestart.resumesNatively(provider)
            if provider.usesACP {
                XCTAssertNil(native, "\(provider.rawValue) says it in its initialize answer")
            } else {
                XCTAssertEqual(native, true, provider.rawValue)
            }
        }
    }

    // MARK: Side chats

    func testSideChatCommands() {
        XCTAssertEqual(SideChat.question(in: "/btw why is the test slow?"), "why is the test slow?")
        XCTAssertEqual(SideChat.question(in: "  /side  look at the parser \n"), "look at the parser")
        XCTAssertEqual(SideChat.question(in: "/BTW x"), "x")
        XCTAssertEqual(SideChat.question(in: "/btw"), "")
        XCTAssertNil(SideChat.question(in: "/btwx hello"), "another command")
        XCTAssertNil(SideChat.question(in: "by the way /btw"))
        XCTAssertNil(SideChat.question(in: "/fork"))
        let names = AgentCommands.commands(for: .gemini, hasProject: true).map(\.name)
        XCTAssertTrue(names.contains("btw") && names.contains("side"), "every agent gets a side chat")
        XCTAssertFalse(AgentCommands.commands(for: .claude, hasProject: true, surface: .chat).contains { $0.name == "btw" })
    }

    func testSideChatStartsFromTheLastFinishedTurn() {
        let events = [RunEvent(kind: .user, text: "first"), RunEvent(kind: .assistant, text: "done"),
                      RunEvent(kind: .user, text: "second"), RunEvent(kind: .tool, text: "make test")]
        XCTAssertEqual(SideChat.cutoff(events: events, turnRunning: false), 4)
        XCTAssertEqual(SideChat.cutoff(events: events, turnRunning: true), 2, "the running turn is not finished")
        XCTAssertEqual(SideChat.cutoff(events: [], turnRunning: true), 0)
    }

    func testSideChatCopiesTheConversationOnlyWhereTheAgentCanForkAtATurn() {
        let mark = ConversationMark(session: "s1", provider: .claude, turns: 2, head: "uuid-7")
        XCTAssertEqual(SideChat.start(provider: .claude, session: "s1", turnRunning: false, lastFinished: mark), .nativeCopy)
        XCTAssertEqual(SideChat.start(provider: .claude, session: "s1", turnRunning: true, lastFinished: mark),
                       .nativeCopyAt(session: "s1", head: "uuid-7"))
        XCTAssertEqual(SideChat.start(provider: .claude, session: "s1", turnRunning: true, lastFinished: nil), .summary,
                       "no mark of the last finished turn: a summary")
        XCTAssertEqual(SideChat.start(provider: .claude, session: nil, turnRunning: false, lastFinished: nil), .summary)
        for provider in RunProvider.allCases where !provider.capabilities.nativeFork {
            XCTAssertEqual(SideChat.start(provider: provider, session: "s1", turnRunning: false, lastFinished: mark), .summary,
                           provider.rawValue)
        }
    }

    func testSideChatsAreListedOnlyWithTheirParent() {
        let parent = session(), other = session()
        var side = session()
        side.lineage = RunLineage(kind: .side, parentID: parent.id, atEvent: 3)
        var fork = session()
        fork.lineage = RunLineage(kind: .fork, parentID: UUID(), atEvent: 1)
        XCTAssertEqual(SideChat.listed([parent, side, other, fork]).map(\.id), [parent.id, side.id, other.id, fork.id])
        XCTAssertEqual(SideChat.listed([side, other]).map(\.id), [other.id], "never on its own")
        XCTAssertEqual(SideChat.children(of: parent.id, in: [parent, side, fork]).map(\.id), [side.id])
        XCTAssertTrue(side.lineage!.bringsBack)
        XCTAssertFalse(RunLineage(kind: .comparison, parentID: parent.id, atEvent: 0).bringsBack)
        XCTAssertEqual(side.lineage?.labelKey, "lineage.sideOf")
    }

    private func session() -> WorkspaceRun {
        WorkspaceRun(id: UUID(), title: "t", task: "t", provider: .claude, profileID: "p", model: "", resolvedModel: nil,
                     mode: .agent, permission: .acceptEdits, isolation: .folder, projectPath: "/w", workingDirectory: "/w",
                     repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil, instructions: "", status: .completed,
                     statusDetail: nil, providerSessionID: nil, createdAt: Date(), updatedAt: Date(), archived: false,
                     usage: RunUsage(), turnStartedAt: nil, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil)
    }
}
