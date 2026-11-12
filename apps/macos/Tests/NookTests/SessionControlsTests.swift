import XCTest

/// Deny with a reason, `/clear`, how much a timeline shows, speed tiers, `@` for a model, and the picker keys.
final class SessionControlsTests: XCTestCase {
    // MARK: Deny with a reason

    private func decoded(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testClaudeDenialCarriesTheReason() {
        let line = ClaudeStreamParser.permissionResponse(requestID: "r1", allow: false, input: JSONBox([String: Any]()),
                                                         message: "use the staging database")
        let response = (decoded(line)["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(response?["behavior"] as? String, "deny")
        XCTAssertEqual(response?["message"] as? String, "Denied by user in Nook: use the staging database")
    }

    func testClaudeDenialWithoutReasonKeepsItsLine() {
        let line = ClaudeStreamParser.permissionResponse(requestID: "r1", allow: false, input: JSONBox([String: Any]()))
        let response = (decoded(line)["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(response?["message"] as? String, "Denied by user in Nook.")
    }

    func testEveryAgentHasAWayToHearTheReason() {
        for provider in RunProvider.allCases {
            switch provider {
            case .claude:
                XCTAssertEqual(provider.capabilities.denyReason, .inResponse, "control_response carries a message")
            case .opencode:
                // Its own server's reject carries the message; over ACP `AcpTurnDriver` sends it as a message instead.
                XCTAssertEqual(provider.capabilities.denyReason, .inResponse, "permission reply carries a message")
            case .codex, .gemini, .antigravity, .cursor, .grok, .pi, .acp:
                // Codex's decline and ACP's reject outcome have no text: the reason follows as a message.
                XCTAssertEqual(provider.capabilities.denyReason, .followUpMessage, provider.rawValue)
            }
        }
    }

    // MARK: /clear

    func testClearIsOfferedForEveryAgentInASession() {
        for provider in RunProvider.allCases {
            let list = AgentCommands.commands(for: provider, hasProject: true, surface: .agent)
            XCTAssertEqual(list.first { $0.name == "clear" }?.action, .clear, provider.rawValue)
            XCTAssertNil(AgentCommands.commands(for: provider, hasProject: true, surface: .chat).first { $0.name == "clear" })
        }
    }

    func testClearIsDescribedByNook() {
        let clear = AgentCommands.commands(for: .codex, hasProject: true).first { $0.name == "clear" }
        XCTAssertEqual(clear.map(AgentCommands.descriptionKey), "composer.command.clear.description")
    }

    // MARK: Timeline detail

    private let user = RunEvent(kind: .user, text: "fix it")
    private let thought = RunEvent(kind: .thinking, text: "hmm")
    private let read = RunEvent(kind: .tool, text: "Read", tool: "Read", state: .done)
    private let failed = RunEvent(kind: .tool, text: "Bash", tool: "Bash", state: .failed)
    private let running = RunEvent(kind: .tool, text: "Bash", tool: "Bash", state: .running)
    private let edit = RunEvent(kind: .fileChange, text: "a.swift", state: .done)
    private let between = RunEvent(kind: .assistant, text: "Looking")
    private let answer = RunEvent(kind: .assistant, text: "Done")
    private let approval = RunEvent(kind: .approval, text: "rm", state: .pending)
    private let error = RunEvent(kind: .error, text: "boom")
    private let cleared = RunEvent(kind: .system, text: "New conversation", tool: "clear")
    private let next = RunEvent(kind: .user, text: "and now")
    private let lastAnswer = RunEvent(kind: .assistant, text: "Also done")

    private var all: [RunEvent] {
        [user, thought, read, between, failed, running, edit, approval, error, answer, cleared, next, lastAnswer]
    }

    func testEverythingShowsEveryEvent() {
        XCTAssertEqual(TimelineDetail.everything.filter(all), all)
    }

    func testHideSucceededKeepsWhatRunsOrFailed() {
        let shown = TimelineDetail.hideSucceeded.filter(all).map(\.id)
        XCTAssertFalse(shown.contains(read.id))
        XCTAssertFalse(shown.contains(edit.id))
        XCTAssertTrue(shown.contains(failed.id))
        XCTAssertTrue(shown.contains(running.id))
        XCTAssertTrue(shown.contains(thought.id))
    }

    func testNoToolsHidesEveryStepButKeepsThinking() {
        let shown = TimelineDetail.noTools.filter(all).map(\.id)
        for step in [read, failed, running, edit] { XCTAssertFalse(shown.contains(step.id)) }
        XCTAssertTrue(shown.contains(thought.id))
        XCTAssertTrue(shown.contains(approval.id))
        XCTAssertTrue(shown.contains(error.id))
    }

    func testZenKeepsTheConversationAndTheFinalAnswerOfEachTurn() {
        let shown = TimelineDetail.zen.filter(all).map(\.id)
        XCTAssertEqual(shown, [user.id, approval.id, error.id, answer.id, cleared.id, next.id, lastAnswer.id])
    }

    func testASessionsChoiceWinsOverSettings() {
        XCTAssertEqual(TimelineDetail.resolve(session: nil, global: .zen), .zen)
        XCTAssertEqual(TimelineDetail.resolve(session: .everything, global: .zen), .everything)
    }

    // MARK: Speed tiers

    func testCodexTiersComeFromTheModelList() {
        let page = AgentModelCatalog.codexPage(["data": [
            ["model": "gpt-5.5", "displayName": "gpt-5.5", "isDefault": true,
             "serviceTiers": [["id": "fast", "name": "Fast", "description": ""],
                              ["id": "ultrafast", "name": "Ultrafast", "description": "Even faster"]]],
            ["model": "gpt-5.4", "displayName": "gpt-5.4", "additionalSpeedTiers": ["fast"]],
            ["model": "gpt-5-mini", "displayName": "gpt-5-mini"],
        ]])
        let models = page.models
        XCTAssertEqual(models[0].tiers, [SpeedTier(id: "fast", name: "Fast"), SpeedTier(id: "ultrafast", name: "Ultrafast", detail: "Even faster")])
        XCTAssertEqual(models[1].tiers, [SpeedTier(id: "fast", name: "Fast")])
        XCTAssertNil(models[2].tiers)
        XCTAssertEqual(SpeedTiers.tiers(for: .codex, model: "gpt-5.4", listed: models).map(\.id), ["fast"])
        XCTAssertEqual(SpeedTiers.tiers(for: .codex, model: "", listed: models).map(\.id), ["fast", "ultrafast"], "the default model's")
        XCTAssertEqual(SpeedTiers.tiers(for: .codex, model: "gpt-5-mini", listed: models), [])
    }

    func testOnlyClaudeAndCodexHaveTiers() {
        for provider in RunProvider.allCases {
            switch provider {
            case .claude:
                XCTAssertEqual(SpeedTiers.tiers(for: provider, model: nil, listed: []), [SpeedTiers.claudeFast])
            case .codex:
                XCTAssertTrue(provider.capabilities.speedTiers)
            case .gemini, .antigravity, .opencode, .cursor, .grok, .pi, .acp:
                XCTAssertFalse(provider.capabilities.speedTiers, provider.rawValue)
                XCTAssertEqual(SpeedTiers.tiers(for: provider, model: nil, listed: []), [])
            }
        }
    }

    func testCodexTurnStartTakesTheTierOrNull() {
        let offered = [SpeedTier(id: "fast", name: "Fast")]
        XCTAssertEqual(SpeedTiers.codexTurnParam(tier: "fast", offered: offered)["serviceTier"] as? String, "fast")
        XCTAssertTrue(SpeedTiers.codexTurnParam(tier: nil, offered: offered)["serviceTier"] is NSNull, "standard clears it")
        XCTAssertTrue(SpeedTiers.codexTurnParam(tier: "gone", offered: offered)["serviceTier"] is NSNull)
        XCTAssertTrue(SpeedTiers.codexTurnParam(tier: "fast", offered: []).isEmpty, "a Codex without tiers never gets the field")
    }

    private func input(_ provider: RunProvider, tier: String?) -> AgentCommand.Input {
        var input = AgentCommand.Input(provider: provider, executable: "/bin/agent", prompt: "hi", model: "", mode: .agent,
                                       permission: .acceptEdits, instructions: "", workingDirectory: "/tmp/w",
                                       resumeSessionID: nil, accountEnvironment: [:], runID: UUID())
        input.speedTier = tier
        return input
    }

    func testClaudeFastModeGoesInItsSettings() {
        let args = AgentCommand.spec(input(.claude, tier: "fast")).arguments
        let settings = args.firstIndex(of: "--settings").map { args[$0 + 1] } ?? ""
        let json = decoded(settings)
        XCTAssertEqual(json["fastMode"] as? Bool, true)
        let standard = AgentCommand.spec(input(.claude, tier: nil)).arguments
        XCTAssertNil(decoded(standard.firstIndex(of: "--settings").map { standard[$0 + 1] } ?? "")["fastMode"])
    }

    func testCodexExecTakesTheTierAsConfig() {
        let args = AgentCommand.spec(input(.codex, tier: "fast")).arguments
        XCTAssertTrue(args.contains("service_tier=\"fast\""))
        XCTAssertFalse(AgentCommand.spec(input(.codex, tier: nil)).arguments.contains { $0.hasPrefix("service_tier") })
        XCTAssertEqual(SpeedTiers.codexExecArguments(tier: "fa\"st"), [], "no quotes into the config")
    }

    // MARK: @model

    private let candidates = [
        ModelMention.Candidate(agent: "claude", agentName: "Claude Code", model: "claude-opus-4-6", name: "Opus 4.6"),
        ModelMention.Candidate(agent: "claude", agentName: "Claude Code", model: "claude-sonnet-4-5", name: "Sonnet 4.5"),
        ModelMention.Candidate(agent: "opencode", agentName: "OpenCode", model: "anthropic/claude-opus-4-6", name: "Opus 4.6"),
        ModelMention.Candidate(agent: "codex", agentName: "Codex", model: "gpt-5.5", name: "GPT-5.5"),
    ]

    func testModelMentionsMatchModelAndAgentWords() {
        XCTAssertEqual(ModelMention.matches("opus", in: candidates).map(\.agent), ["claude", "opencode"])
        XCTAssertEqual(ModelMention.matches("opus:opencode", in: candidates).map(\.agent), ["opencode"])
        XCTAssertEqual(ModelMention.matches("gpt-5", in: candidates).map(\.model), ["gpt-5.5"])
        XCTAssertEqual(ModelMention.matches("", in: candidates), [], "a bare @ lists files and sessions")
    }

    func testAModelReferenceReachesTheAgentAsAgentAndModel() {
        let ref = ModelMention.ref(candidates[0])
        let projected = ContextRefs.project("Delegate the tests to " + ContextRefs.link(ref))
        XCTAssertTrue(projected.hasPrefix("Delegate the tests to [model: Opus 4.6 · Claude Code]"))
        XCTAssertTrue(projected.contains(#"<ref kind="model" id="claude/claude-opus-4-6"/>"#))
    }

    func testAgentsYouAddedAreNotNamed() {
        let list = ModelMention.candidates([.claude, .acp]) { _ in [(id: "m", name: "M")] }
        XCTAssertEqual(list.map(\.agent), ["claude"])
    }

    // MARK: Keys

    func testPickerKeysAreWiredAndFree() {
        for command in ["effortPicker.toggle", "permissionPicker.toggle", "effort.increase", "effort.decrease"] {
            XCTAssertTrue(Keybindings.commandIDs.contains(command), command)
        }
        XCTAssertEqual(Keybindings.defaults.first { $0.command == "effortPicker.toggle" }?.key, "mod+shift+e")
        XCTAssertEqual(Keybindings.defaults.first { $0.command == "permissionPicker.toggle" }?.key, "mod+shift+a")
        XCTAssertNil(Keybindings.defaults.first { $0.command == "effort.increase" }, "unbound by default")
        XCTAssertEqual(Keybindings.conflicts(Keybindings.defaults), [])
    }
}
