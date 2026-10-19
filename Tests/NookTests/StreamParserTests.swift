import XCTest

final class ClaudeStreamParserTests: XCTestCase {
    func testInit() {
        let events = ClaudeStreamParser.parse(#"{"type":"system","subtype":"init","session_id":"abc","model":"claude-sonnet-4-5","cwd":"/x","tools":[]}"#)
        XCTAssertEqual(events, [.initialized(sessionID: "abc", model: "claude-sonnet-4-5")])
    }

    func testTextDeltaOnlyForTopLevel() {
        let top = #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(top), [.textDelta("Hal")])
        let nested = #"{"type":"stream_event","parent_tool_use_id":"toolu_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(nested), [])
        let thinking = #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(thinking), [.thinkingDelta("hm", starts: false)], "thinking streams live, as in T3Code")
    }

    func testAssistantMessageWithToolUseAndUsage() {
        let line = #"""
        {"type":"assistant","parent_tool_use_id":null,"session_id":"abc","message":{"id":"msg_1","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Ik kijk even."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}
        """#
        let events = ClaudeStreamParser.parse(line)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .text("Ik kijk even."))
        XCTAssertEqual(events[1], .toolUse(id: "toolu_1", name: "Bash", input: JSONBox(["command": "ls"]), nested: false))
        XCTAssertEqual(events[2], .usage(messageID: "msg_1", tokens: TokenCounts(input: 10, output: 5, cacheRead: 100, cacheWrite: 20), model: "claude-sonnet-4-5"))
        if case .usage(_, let tokens, _) = events[2] { XCTAssertEqual(tokens.context, 130) }
    }

    func testNestedToolUseIsMarked() {
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"id":"m","content":[{"type":"text","text":"sub"},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a"}}],"usage":{"input_tokens":1,"output_tokens":1}}}"#
        let events = ClaudeStreamParser.parse(line)
        XCTAssertEqual(events, [.toolUse(id: "t2", name: "Read", input: JSONBox(["file_path": "/a"]), nested: true)],
                       "text and tokens from subagents do not count as top-level response")
    }

    func testToolResultStringAndBlocks() {
        let string = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(string), [.toolResult(id: "t1", output: "ok", isError: false)])
        let blocks = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}],"is_error":true}]}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(blocks), [.toolResult(id: "t2", output: "a\nb", isError: true)])
    }

    func testPermissionRequest() {
        let line = #"{"type":"control_request","request_id":"req_7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules"}],"tool_use_id":"toolu_9"}}"#
        let events = ClaudeStreamParser.parse(line)
        XCTAssertEqual(events, [.permissionRequest(requestID: "req_7", tool: "Bash", input: JSONBox(["command": "rm -rf build"]),
                                                   suggestions: JSONBox([["type": "addRules"]]), toolUseID: "toolu_9")])
    }

    func testResultWithCostAndContextWindow() {
        let line = #"""
        {"type":"result","subtype":"success","is_error":false,"duration_ms":4200,"num_turns":3,"result":"Klaar.","session_id":"abc","total_cost_usd":0.0421,"usage":{"input_tokens":12,"output_tokens":340,"cache_read_input_tokens":9000,"cache_creation_input_tokens":800},"modelUsage":{"claude-sonnet-4-5":{"inputTokens":12,"contextWindow":200000,"costUSD":0.04}},"permission_denials":[{"tool_name":"Bash"}]}
        """#
        guard case .result(let result)? = ClaudeStreamParser.parse(line).first else { return XCTFail("no result") }
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "Klaar.")
        XCTAssertEqual(result.sessionID, "abc")
        XCTAssertEqual(result.usage.inputTokens, 12)
        XCTAssertEqual(result.usage.outputTokens, 340)
        XCTAssertEqual(result.usage.cacheReadTokens, 9000)
        XCTAssertEqual(result.usage.cacheWriteTokens, 800)
        XCTAssertEqual(result.usage.reportedCostUSD ?? 0, 0.0421, accuracy: 0.00001)
        XCTAssertEqual(result.usage.contextWindow, 200_000)
        XCTAssertEqual(result.usage.durationSeconds ?? 0, 4.2, accuracy: 0.001)
        XCTAssertEqual(result.permissionDenials, 1)
    }

    func testResultWithoutCostKeepsNil() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s"}"#
        guard case .result(let result)? = ClaudeStreamParser.parse(line).first else { return XCTFail("no result") }
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.usage.reportedCostUSD)
        XCTAssertNil(result.usage.inputTokens)
        XCTAssertNil(result.usage.contextWindow)
    }

    func testGarbageIsIgnored() {
        XCTAssertEqual(ClaudeStreamParser.parse("not json"), [])
        XCTAssertEqual(ClaudeStreamParser.parse("{}"), [])
        XCTAssertEqual(ClaudeStreamParser.parse(#"{"type":"control_response","response":{}}"#), [])
    }

    // MARK: Outgoing to Claude Code

    func testUserMessageShape() throws {
        let line = ClaudeStreamParser.userMessage("Hallo \"wereld\"\nregel 2")
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "exactly one line, even with embedded newlines in text")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(message["content"] as? String, "Hallo \"wereld\"\nregel 2")
    }

    func testPermissionResponses() throws {
        let input = JSONBox(["command": "ls"])
        let allow = try json(ClaudeStreamParser.permissionResponse(requestID: "r1", allow: true, input: input))
        XCTAssertEqual(allow["type"] as? String, "control_response")
        let response = try XCTUnwrap(allow["response"] as? [String: Any])
        XCTAssertEqual(response["request_id"] as? String, "r1")
        XCTAssertEqual(response["subtype"] as? String, "success")
        let decision = try XCTUnwrap(response["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual((decision["updatedInput"] as? [String: Any])?["command"] as? String, "ls")
        XCTAssertNil(decision["updatedPermissions"])

        let always = try json(ClaudeStreamParser.permissionResponse(requestID: "r2", allow: true, input: input, rules: JSONBox([["type": "addRules"]])))
        let alwaysDecision = (always["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertNotNil(alwaysDecision?["updatedPermissions"])

        let deny = try json(ClaudeStreamParser.permissionResponse(requestID: "r3", allow: false, input: input))
        let denyDecision = (deny["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(denyDecision?["behavior"] as? String, "deny")
        XCTAssertNotNil(denyDecision?["message"] as? String)
    }

    func testInterruptRequest() throws {
        let object = try json(ClaudeStreamParser.interruptRequest(id: "x"))
        XCTAssertEqual(object["type"] as? String, "control_request")
        XCTAssertEqual((object["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
    }

    private func json(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

final class CodexStreamParserTests: XCTestCase {
    func testThreadAndMessages() {
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"thread.started","thread_id":"t-1"}"#), [.threadStarted("t-1")])
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Klaar"}}"#), [.message("Klaar")])
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"denk"}}"#), [.reasoning("denk")])
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"item.started","item":{"id":"i0","type":"agent_message","text":""}}"#), [])
    }

    func testCommands() {
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}"#),
                       [.commandStarted(id: "c1", command: "bash -lc ls")])
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"a\nb","exit_code":2,"status":"failed"}}"#),
                       [.commandFinished(id: "c1", command: "ls", output: "a\nb", exitCode: 2)])
    }

    func testFileChangesAndLegacyItemType() {
        let line = #"{"type":"item.completed","item":{"id":"f1","item_type":"file_change","changes":[{"path":"/r/a.swift","kind":"update"},{"path":"/r/b.swift","kind":"add"}],"status":"completed"}}"#
        XCTAssertEqual(CodexStreamParser.parse(line), [.fileChanges(id: "f1", changes: [CodexFileChange(path: "/r/a.swift", kind: "update"),
                                                                                      CodexFileChange(path: "/r/b.swift", kind: "add")])])
    }

    func testUsageSeparatesCache() {
        guard case .turnCompleted(let usage)? = CodexStreamParser.parse(#"{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}"#).first else {
            return XCTFail("no turn.completed")
        }
        XCTAssertEqual(usage.inputTokens, 200, "cache is not double counted")
        XCTAssertEqual(usage.cacheReadTokens, 800)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertNil(usage.reportedCostUSD, "Codex does not report cost")
        XCTAssertNil(usage.contextWindow)
    }

    func testErrors() {
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"turn.failed","error":{"message":"rate limit"}}"#), [.failed("rate limit")])
        XCTAssertEqual(CodexStreamParser.parse(#"{"type":"error","message":"stream error"}"#), [.failed("stream error")])
    }
}
