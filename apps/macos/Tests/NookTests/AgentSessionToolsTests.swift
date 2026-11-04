import XCTest

/// The "Auto" access level per agent, restarting a session's agent, and side chats: the pure decisions behind them.
final class AgentSessionToolsTests: XCTestCase {
    // MARK: Auto access level

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
}
