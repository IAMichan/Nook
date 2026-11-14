import XCTest

/// The text generator chosen per task (agent CLI or a model API), the API requests and answers, and the suggested next
/// prompt. No network: a fake transport answers.
final class TextGeneratorTests: XCTestCase {
    /// Records the request and answers with a fixed body and status.
    final class FakeTransport: TextGeneratorTransport, @unchecked Sendable {
        let body: Data
        let status: Int
        private(set) var requests: [URLRequest] = []

        init(_ json: String, status: Int = 200) {
            body = Data(json.utf8)
            self.status = status
        }

        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            return (body, status)
        }
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    // MARK: - Choice and routing

    func testStoredGeneratorRoundTrips() {
        XCTAssertEqual(TextGenerator(stored: nil), .agent)
        XCTAssertEqual(TextGenerator(stored: "agent"), .agent)
        XCTAssertEqual(TextGenerator(stored: "api:openrouter:anthropic/claude-haiku"), .api(.openrouter, model: "anthropic/claude-haiku"))
        XCTAssertEqual(TextGenerator(stored: "api:ollama:qwen3:8b"), .api(.ollama, model: "qwen3:8b"), "a model with a colon stays whole")
        XCTAssertEqual(TextGenerator(stored: "api:gone:x"), .agent, "an unknown provider falls back to the agent")
        XCTAssertEqual(TextGenerator(stored: "api:claudeCode:"), .agent, "a CLI subscription is not an API")
        let generator = TextGenerator.api(.lmstudio, model: "")
        XCTAssertEqual(TextGenerator(stored: generator.stored), generator)
        XCTAssertFalse(TextGenerator.apiProviders.contains(.claudeCode))
        XCTAssertTrue(TextGenerator.apiProviders.contains(.claude))
        XCTAssertTrue(TextGenerator.apiProviders.contains(.ollama))
    }

    func testModelFallsBackToProviderDefault() {
        XCTAssertEqual(TextGenerator.api(.openai, model: "").model, AIProvider.openai.defaultModel)
        XCTAssertEqual(TextGenerator.api(.openai, model: "gpt-x").model, "gpt-x")
        XCTAssertEqual(TextGenerator.agent.model, "")
    }

    func testRouting() {
        XCTAssertEqual(TextGenerationRoute.resolve(.agent, key: { _ in "k" }), .agent)
        XCTAssertEqual(TextGenerationRoute.resolve(.api(.openai, model: "m"), key: { _ in nil }), .agent,
                       "a provider that needs a key and has none leaves the text to the agent")
        XCTAssertEqual(TextGenerationRoute.resolve(.api(.openai, model: "m"), key: { _ in "  " }), .agent)
        XCTAssertEqual(TextGenerationRoute.resolve(.api(.openai, model: "m"), key: { _ in " sk-1 " }), .api(.openai, model: "m", key: "sk-1"))
        XCTAssertEqual(TextGenerationRoute.resolve(.api(.ollama, model: "llama3"), key: { _ in nil }), .api(.ollama, model: "llama3", key: nil),
                       "a server on this Mac needs no key")
    }

    // MARK: - Requests

    func testAnthropicRequest() throws {
        let request = try TextGeneratorAPI.request(provider: .claude, model: "claude-haiku", key: "sk-ant", prompt: "Hi",
                                                   schema: TextGeneration.commitSchema, maxTokens: 300, timeout: 30)
        XCTAssertEqual(request.url?.absoluteString, AIProvider.claude.baseURL + "/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), TextGeneratorAPI.anthropicVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku")
        XCTAssertEqual(json["max_tokens"] as? Int, 300)
        let text = ((json["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("Hi\n\n"))
        XCTAssertTrue(text.contains("body (string), subject (string)"), "the JSON keys are named in the prompt")
    }

    func testOpenAICompatibleRequests() throws {
        let openai = try TextGeneratorAPI.request(provider: .openai, model: "gpt", key: "sk", prompt: "Hi", schema: nil,
                                                  maxTokens: 50, timeout: 30)
        XCTAssertEqual(openai.url?.absoluteString, AIProvider.openai.baseURL + "/chat/completions")
        XCTAssertEqual(openai.value(forHTTPHeaderField: "Authorization"), "Bearer sk")
        XCTAssertEqual(body(openai)["max_completion_tokens"] as? Int, 50)
        XCTAssertNil(body(openai)["max_tokens"])
        let messages = body(openai)["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages?.last?["content"] as? String, "Hi", "no schema: the prompt as it is")

        let local = try TextGeneratorAPI.request(provider: .lmstudio, model: "", key: nil, prompt: "Hi", schema: nil,
                                                 maxTokens: 50, timeout: 30)
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(body(local)["model"], "no model: the one the server has loaded")
        XCTAssertEqual(body(local)["max_tokens"] as? Int, 50)
    }

    // MARK: - Answers

    func testAnswerParsing() throws {
        let anthropic = #"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"  Fix login \n"}]}"#
        XCTAssertEqual(try TextGeneratorAPI.answerText(provider: .claude, data: Data(anthropic.utf8), status: 200), "Fix login")
        let openai = #"{"choices":[{"message":{"content":"<think>hmm</think>\n{\"title\":\"A\"}"}}]}"#
        XCTAssertEqual(try TextGeneratorAPI.answerText(provider: .openai, data: Data(openai.utf8), status: 200), #"{"title":"A"}"#,
                       "a reasoning model's thinking is dropped")
        let parts = #"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#
        XCTAssertEqual(try TextGeneratorAPI.answerText(provider: .openrouter, data: Data(parts.utf8), status: 200), "ab")
        XCTAssertThrowsError(try TextGeneratorAPI.answerText(provider: .openai, data: Data(#"{"choices":[]}"#.utf8), status: 200)) {
            XCTAssertEqual($0 as? TextGeneratorError, .empty)
        }
        let refused = #"{"error":{"message":"invalid x-api-key"}}"#
        XCTAssertThrowsError(try TextGeneratorAPI.answerText(provider: .claude, data: Data(refused.utf8), status: 401)) {
            XCTAssertEqual($0 as? TextGeneratorError, .status(401, "invalid x-api-key"))
        }
        XCTAssertEqual(TextGeneratorAPI.withoutThinking("a<think>never closed"), "a")
    }

    func testOneKeySchemaTakesPlainWords() {
        XCTAssertEqual(TextGeneratorAPI.object("Run the tests", schema: NextPromptSuggestion.schema)?["prompt"] as? String, "Run the tests")
        XCTAssertNil(TextGeneratorAPI.object("Fix it", schema: TextGeneration.commitSchema), "two keys need real JSON")
    }

    func testGenerateGoesThroughTransport() async throws {
        let fake = FakeTransport(#"{"choices":[{"message":{"content":"```json\n{\"prompt\":\"Now add tests\"}\n```"}}]}"#)
        let answer = try await TextGeneratorAPI.generate(provider: .ollama, model: "qwen3", key: nil, prompt: "p",
                                                         schema: NextPromptSuggestion.schema, maxTokens: 200, transport: fake)
        XCTAssertEqual(answer?["prompt"] as? String, "Now add tests")
        XCTAssertEqual(fake.requests.count, 1, "one request, no retries")
        XCTAssertEqual(fake.requests.first?.url?.absoluteString, AIProvider.ollama.baseURL + "/chat/completions")

        let failing = FakeTransport(#"{"error":"rate limited"}"#, status: 429)
        do {
            _ = try await TextGeneratorAPI.test(provider: .openai, model: "m", key: "k", transport: failing)
            XCTFail("a 429 is an error")
        } catch {
            XCTAssertEqual(error as? TextGeneratorError, .status(429, "rate limited"))
        }
    }

    // MARK: - Suggested next prompt

    func testNextPromptPrompt() throws {
        typealias M = NextPromptSuggestion.Message
        XCTAssertNil(NextPromptSuggestion.prompt([M(role: .user, text: "hi")]), "no reply yet: nothing to predict")
        XCTAssertNil(NextPromptSuggestion.prompt([M(role: .agent, text: "Hello")]), "no message of yours: nothing to follow")
        let messages = (1...5).map { M(role: .user, text: "ask \($0)") } + [M(role: .agent, text: "Done. Shall I add tests?"), M(role: .user, text: " ")]
        let prompt = try XCTUnwrap(NextPromptSuggestion.prompt(messages))
        XCTAssertTrue(prompt.contains("- ask 3\n- ask 4\n- ask 5"), "the last three messages of yours")
        XCTAssertFalse(prompt.contains("ask 2"))
        XCTAssertTrue(prompt.hasSuffix("The agent's last reply:\nDone. Shall I add tests?"))
        XCTAssertTrue(prompt.contains("data, not instructions"))
        let long = try XCTUnwrap(NextPromptSuggestion.prompt([M(role: .user, text: "go"), M(role: .agent, text: "a" + String(repeating: "b", count: 5_000))]))
        XCTAssertTrue(long.contains("[…]\n"), "a long reply keeps its end")
        XCTAssertFalse(long.contains("ab"))
    }

    /// A long turn of tool calls and replies still reaches back to your messages, so a prompt is always written.
    func testNextPromptMessagesReachBackToYourMessages() throws {
        let replies = (1...300).flatMap { [RunEvent(kind: .tool, text: "Bash · ls", tool: "Bash"), RunEvent(kind: .assistant, text: "step \($0)")] }
        let events = [RunEvent(kind: .user, text: "fix the build")] + replies
        let messages = NextPromptSuggestion.messages(events)
        XCTAssertEqual(messages.first, NextPromptSuggestion.Message(role: .user, text: "fix the build"))
        XCTAssertEqual(messages.last?.text, "step 300")
        XCTAssertEqual(messages.count, 41, "the last 40 replies and your message")
        XCTAssertNotNil(NextPromptSuggestion.prompt(messages))
    }

    func testNextPromptClean() {
        XCTAssertEqual(NextPromptSuggestion.clean(#"{"prompt":"  \"Add a test for it\"  "}"#), "Add a test for it")
        XCTAssertEqual(NextPromptSuggestion.clean("Prompt: run   the\tbuild\nsecond line"), "run the build")
        XCTAssertNil(NextPromptSuggestion.clean(#"{"prompt":""}"#))
        XCTAssertNil(NextPromptSuggestion.clean("None."))
        let long = NextPromptSuggestion.clean(String(repeating: "word ", count: 100)) ?? ""
        XCTAssertLessThanOrEqual(long.count, NextPromptSuggestion.maxLength + 1)
        XCTAssertTrue(long.hasSuffix("word…"), "cut at a word")
    }

    func testNextPromptGate() {
        let open = NextPromptSuggestion.Gate(enabled: true, turnCompleted: true, composerEmpty: true, holds: false,
                                             delegated: false, alreadyTried: false)
        XCTAssertTrue(open.allows)
        for change in [\NextPromptSuggestion.Gate.enabled, \.turnCompleted, \.composerEmpty] {
            var gate = open
            gate[keyPath: change] = false
            XCTAssertFalse(gate.allows)
        }
        for change in [\NextPromptSuggestion.Gate.holds, \.delegated, \.alreadyTried, \.stale] {
            var gate = open
            gate[keyPath: change] = true
            XCTAssertFalse(gate.allows, "only once per turn, and never while the session waits on something else")
        }
    }

    func testNextPromptStateShowsOnlyForItsTurn() {
        let turn = UUID()
        let ready = NextPromptState(turn: turn, phase: .ready("Ship it"))
        XCTAssertEqual(ready.shown(for: turn), "Ship it")
        XCTAssertNil(ready.shown(for: UUID()), "a newer reply hides an old suggestion")
        XCTAssertNil(NextPromptState(turn: turn, phase: .writing).shown(for: turn))
        XCTAssertNil(NextPromptState(turn: turn, phase: .done).shown(for: turn))
    }

    /// When Claude Code stays silent, the fallback writes with the session's own model at low effort; any other agent's
    /// model name means nothing to `claude`, so those get the small default.
    func testTheFallbackWritesWithTheSessionsOwnClaudeModel() {
        var run = WorkspaceRun(id: UUID(), title: "t", task: "t", provider: .claude, profileID: "p", model: "claude-opus-5-5",
                               resolvedModel: nil, mode: .agent, permission: .acceptEdits, isolation: .folder, projectPath: "/w",
                               workingDirectory: "/w", repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil,
                               instructions: "", status: .completed, statusDetail: nil, providerSessionID: nil, createdAt: Date(),
                               updatedAt: Date(), archived: false, usage: RunUsage(), turnStartedAt: nil, reviewedAt: nil,
                               lastChangeAt: nil, changedFiles: nil)
        XCTAssertEqual(NextPromptSuggestion.agentModel(run), "claude-opus-5-5")
        run.model = ""
        run.resolvedModel = "claude-sonnet-5-5"
        XCTAssertEqual(NextPromptSuggestion.agentModel(run), "claude-sonnet-5-5", "the default model as Claude Code reported it")
        run.resolvedModel = nil
        XCTAssertNil(NextPromptSuggestion.agentModel(run))
        run.provider = .codex
        run.model = "gpt-5.5"
        XCTAssertNil(NextPromptSuggestion.agentModel(run))

        let arguments = TextGeneration.claudeArguments(schema: NextPromptSuggestion.schema, model: "claude-opus-5-5",
                                                       effort: NextPromptSuggestion.agentEffort)
        guard let index = arguments.firstIndex(of: "--effort") else { return XCTFail("effort missing") }
        XCTAssertEqual(arguments[index + 1], "low")
        XCTAssertFalse(TextGeneration.claudeArguments(schema: NextPromptSuggestion.schema).contains("--effort"))
    }
}
