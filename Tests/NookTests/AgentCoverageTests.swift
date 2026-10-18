import XCTest

/// Every agent Nook runs or reads gets the same treatment: the whole conversation with its thinking, and Gemini CLI as a
/// headless agent next to Claude Code and Codex.
final class AgentCoverageTests: XCTestCase {
    private func lines(_ objects: [[String: Any]]) -> Data {
        let text = objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        return Data(text.utf8)
    }

    // MARK: Transcripts

    func testCodexTranscriptKeepsItsReasoning() {
        let data = lines([
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Fix de test"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning", "text": "**Kijken** naar de test"]],
            ["type": "event_msg", "payload": ["type": "agent_reasoning", "text": "Oorzaak gevonden"]],
            ["type": "response_item", "payload": ["type": "reasoning", "summary": [["type": "summary_text", "text": "dubbel"]]]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Opgelost."]]
        ])
        let messages = AgentTranscript.jsonl(data)
        XCTAssertEqual(messages.map(\.kind), [.user, .thinking, .assistant])
        XCTAssertEqual(messages[1].text, "**Kijken** naar de test\n\nOorzaak gevonden", "reasoning in a row joins one bubble, never twice")
    }

    func testGeminiChatWithThoughts() {
        let chat: [String: Any] = ["sessionId": "s1", "messages": [
            ["id": "u1", "type": "user", "content": "Wat doet main.swift?"],
            ["id": "g1", "type": "gemini", "content": "Het start de app.",
             "thoughts": [["subject": "Lezen", "description": "Ik open main.swift."], ["subject": "", "description": "Klaar."]]],
            ["id": "i1", "type": "info", "content": "ignored"],
            ["id": "u2", "type": "user", "content": [["text": "En AppDelegate?"]]]
        ]]
        let messages = AgentTranscript.gemini(try! JSONSerialization.data(withJSONObject: chat))
        XCTAssertEqual(messages.map(\.kind), [.user, .thinking, .assistant, .user])
        XCTAssertEqual(messages[1].text, "**Lezen**\nIk open main.swift.\n\nKlaar.")
        XCTAssertEqual(messages[3].text, "En AppDelegate?")
    }

    func testWholeConversationIsRead() throws {
        var objects: [[String: Any]] = []
        for index in 0..<120 {
            objects.append(["type": "event_msg", "payload": ["type": "user_message", "message": "vraag \(index)"]])
            objects.append(["type": "event_msg", "payload": ["type": "agent_message", "message": "antwoord \(index)"]])
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines(objects).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let messages = AgentTranscript.recent(path: file.path)
        XCTAssertEqual(messages.count, 240, "no longer only the last 40 messages")
        XCTAssertEqual(messages.first?.text, "vraag 0")
    }

    func testGeminiChatFileIsReadFromDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["messages": [["type": "user", "content": "hoi"], ["type": "gemini", "content": "hallo"]]])
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(AgentTranscript.recent(path: file.path).map(\.text), ["hoi", "hallo"])
    }

    // MARK: Gemini CLI headless

    func testGeminiCommand() {
        var input = AgentCommand.Input(provider: .gemini, executable: "/opt/homebrew/bin/gemini", prompt: "-maak tests", model: "gemini-2.5-pro",
                                       mode: .agent, permission: .acceptEdits, instructions: "Gebruik tabs", workingDirectory: "/tmp/w",
                                       resumeSessionID: nil, accountEnvironment: [:], runID: UUID())
        var args = AgentCommand.spec(input).arguments
        XCTAssertEqual(value(after: "--output-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--approval-mode", in: args), "auto_edit")
        XCTAssertEqual(value(after: "--model", in: args), "gemini-2.5-pro")
        XCTAssertEqual(args.last, "--prompt=Gebruik tabs\n\n-maak tests", "a prompt starting with a dash stays one value")
        XCTAssertNil(value(after: "--resume", in: args))
        XCTAssertFalse(AgentCommand.spec(input).keepsInputOpen)

        input.resumeSessionID = "abc-123"
        input.mode = .plan
        args = AgentCommand.spec(input).arguments
        XCTAssertEqual(value(after: "--resume", in: args), "abc-123")
        XCTAssertEqual(value(after: "--approval-mode", in: args), "plan")
        XCTAssertEqual(args.last, "--prompt=-maak tests", "a resumed conversation already has the instructions")
        XCTAssertEqual(AgentCommand.geminiApprovalMode(mode: .agent, permission: .bypass), "yolo")
    }

    func testGeminiStream() {
        XCTAssertEqual(GeminiStreamParser.parse(#"{"type":"init","timestamp":"t","session_id":"s-1","model":"gemini-2.5-pro"}"#),
                       [.initialized(sessionID: "s-1", model: "gemini-2.5-pro")])
        XCTAssertEqual(GeminiStreamParser.parse(#"{"type":"message","role":"user","content":"hoi"}"#), [], "the echoed prompt is not an answer")
        XCTAssertEqual(GeminiStreamParser.parse(#"{"type":"message","role":"assistant","content":"Hal","delta":true}"#),
                       [.text("Hal", delta: true)])
        XCTAssertEqual(GeminiStreamParser.parse(#"{"type":"tool_use","tool_name":"run_shell_command","tool_id":"t1","parameters":{"command":"ls"}}"#),
                       [.toolUse(id: "t1", name: "run_shell_command", input: JSONBox(["command": "ls"]))])
        XCTAssertEqual(GeminiStreamParser.parse(#"{"type":"tool_result","tool_id":"t1","status":"error","error":{"type":"x","message":"nope"}}"#),
                       [.toolResult(id: "t1", output: "nope", isError: true)])
        XCTAssertEqual(GeminiStreamParser.parse(#"{"type":"error","severity":"warning","message":"traag"}"#), [.warning("traag")])
        let result = GeminiStreamParser.parse(#"{"type":"result","status":"success","stats":{"total_tokens":150,"input_tokens":120,"output_tokens":30,"cached":20,"input":100,"duration_ms":2500,"tool_calls":1,"models":{}}}"#)
        guard case .result(let isError, _, let usage)? = result.first else { return XCTFail("no result") }
        XCTAssertFalse(isError)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 20, "cached tokens are kept apart, never counted twice")
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.durationSeconds, 2.5)
    }

    func testGeminiFileChangesAndSummaries() {
        XCTAssertEqual(ToolSummary.fileChanges(tool: "write_file", input: ["file_path": "/a/b.swift"]).map(\.kind), ["written"])
        XCTAssertEqual(ToolSummary.fileChanges(tool: "replace", input: ["file_path": "/a/b.swift"]).map(\.kind), ["modified"])
        XCTAssertEqual(ToolSummary.describe(tool: "run_shell_command", input: ["command": "npm test"]), "run_shell_command · npm test")
        XCTAssertTrue(RunProvider.gemini.capabilities.policies.contains(.acceptEdits))
        XCTAssertTrue(RunProvider.gemini.capabilities.policies.contains(.ask), "over ACP Gemini asks Nook for permission")
    }

    func testCodexAsksForDetailedReasoning() {
        let input = AgentCommand.Input(provider: .codex, executable: "/bin/codex", prompt: "hoi", model: "", mode: .agent,
                                       permission: .acceptEdits, instructions: "", workingDirectory: "/tmp/w",
                                       resumeSessionID: nil, accountEnvironment: [:], runID: UUID())
        let args = AgentCommand.spec(input).arguments
        XCTAssertEqual(value(after: "-c", in: args), "model_reasoning_summary=\"detailed\"")
    }

    func testCheckedOutElsewhereReadsClearly() {
        let raw = GitError("fatal: 'main' is already used by worktree at '/Users/x/app'")
        XCTAssertEqual(GitService.friendlyWorktreeError(raw, base: "main").localizedDescription,
                       "'main' is already checked out in another worktree (/Users/x/app). Start from another branch, or remove that worktree first.")
        let other = GitError("fatal: invalid reference")
        XCTAssertEqual(GitService.friendlyWorktreeError(other, base: "main") as? GitError, other)
    }

    func testClaudeRateLimitEvent() {
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"rate_limit_event","rate_limit_info":{"rateLimitType":"five_hour","utilization":0.4,"resetsAt":1700000000}}"#),
                       [.rateLimits])
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
