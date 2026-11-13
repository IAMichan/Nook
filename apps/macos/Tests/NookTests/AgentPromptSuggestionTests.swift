import XCTest

/// The suggested next prompt written by the agent itself (`PromptSuggestionSource`): Claude Code's `--prompt-suggestions`,
/// Codex's `thread/sample`, and the subscription as the composers' sentence model.
final class AgentPromptSuggestionTests: XCTestCase {
    func testClaudeCodeSendsItsSuggestionAfterTheTurn() {
        let line = #"{"type":"prompt_suggestion","suggestion":"  save it to add.py \n","uuid":"u","session_id":"s"}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line), [.promptSuggestion("save it to add.py")])
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"prompt_suggestion","suggestion":"  "}"#), [])
        XCTAssertFalse(ClaudeStreamEvent.isWork(.promptSuggestion("x")), "a suggestion must not wake a parked session")
    }

    func testClaudeCodeIsLaunchedWithTheFlagOnlyWhenAsked() {
        var input = AgentCommand.Input(provider: .claude, executable: "/usr/local/bin/claude", prompt: "hi", model: "",
                                       mode: .agent, permission: .acceptEdits, instructions: "", workingDirectory: "/tmp/w",
                                       resumeSessionID: nil, accountEnvironment: [:], runID: UUID())
        XCTAssertFalse(AgentCommand.spec(input).arguments.contains("--prompt-suggestions"))
        input.promptSuggestions = true
        let arguments = AgentCommand.spec(input).arguments
        guard let index = arguments.firstIndex(of: "--prompt-suggestions") else { return XCTFail("flag missing") }
        XCTAssertEqual(arguments[index + 1], "true")
    }

    func testEveryAgentHasASource() {
        for provider in RunProvider.allCases {
            switch provider {
            case .claude: XCTAssertEqual(provider.capabilities.promptSuggestions, .agentStream)
            case .codex: XCTAssertEqual(provider.capabilities.promptSuggestions, .threadSample)
            case .gemini, .opencode, .cursor, .grok, .antigravity, .pi, .acp:
                XCTAssertEqual(provider.capabilities.promptSuggestions, .generator)
            }
        }
    }

    func testCodexSamplesTheThreadAfterItsLastTurn() {
        let params = CodexRPC.sampleParams(threadID: "t1", turnID: "turn-9", prompt: "Predict it. Do not use tools.")
        XCTAssertEqual(params["threadId"] as? String, "t1")
        XCTAssertEqual(params["expectedTurnId"] as? String, "turn-9")
        XCTAssertEqual(params["effort"] as? String, "low")
        XCTAssertTrue((params["prompt"] as? String)?.contains("Do not use tools") == true)
    }

    func testTheSubscriptionIsAComposerModel() {
        XCTAssertEqual(ComposerCompletion.Choice(stored: "agent"), .agent)
        XCTAssertEqual(ComposerCompletion.Choice.agent.stored, "agent")
        XCTAssertEqual(ComposerCompletion.agentSchema["required"] as? [String], ["text"])
    }
}
