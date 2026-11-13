import XCTest

final class CodexToolResultTests: XCTestCase {
    func testMcpCallsCarryTheirArgumentsAndResult() {
        let exec = #"{"type":"item.completed","item":{"id":"m1","type":"mcp_tool_call","server":"linear","tool":"list_issues","arguments":{"team":"NOOK"},"result":{"content":[{"type":"text","text":"3 issues"}]},"status":"completed"}}"#
        XCTAssertEqual(CodexStreamParser.parse(exec),
                       [.toolCall(id: "m1", name: "list_issues", detail: "linear", finished: true, failed: false,
                                  input: JSONBox(["team": "NOOK"]), output: "3 issues")])
        let failed = #"{"type":"item.completed","item":{"id":"m2","type":"mcp_tool_call","server":"linear","tool":"list_issues","error":{"message":"not signed in"},"status":"failed"}}"#
        XCTAssertEqual(CodexStreamParser.parse(failed),
                       [.toolCall(id: "m2", name: "list_issues", detail: "linear", finished: true, failed: true, output: "not signed in")])
        let started = #"{"type":"item.started","item":{"id":"m3","type":"mcp_tool_call","server":"linear","tool":"list_issues","status":"in_progress"}}"#
        XCTAssertEqual(CodexStreamParser.parse(started),
                       [.toolCall(id: "m3", name: "list_issues", detail: "linear", finished: false, failed: false)])
    }
}

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
        XCTAssertEqual(ClaudeStreamParser.parse(thinking), [.thinkingDelta("hm", starts: false)], "thinking streams live")
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
        XCTAssertEqual(events, [.subagentStep(parent: "toolu_parent", SubagentStep(kind: .text, text: "sub")),
                                .toolUse(id: "t2", name: "Read", input: JSONBox(["file_path": "/a"]), nested: true),
                                .subagentStep(parent: "toolu_parent", SubagentStep(kind: .tool,
                                                                                    text: ToolSummary.describe(tool: "Read", input: ["file_path": "/a"]),
                                                                                    tool: "Read"))],
                       "text and tokens from subagents do not count as top-level response; they go with the subagent")
    }

    func testNestedThinkingGoesWithTheSubagent() {
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"id":"m","content":[{"type":"thinking","thinking":"Check the tests first"},{"type":"thinking","thinking":""}]}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line),
                       [.subagentStep(parent: "toolu_parent", SubagentStep(kind: .thinking, text: "Check the tests first"))])
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

    func testPermissionRequestCarriesWhyItAsks() {
        func ask(_ request: String) -> PermissionAsk? {
            let line = #"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{},"tool_use_id":"t","#
                + request + "}}"
            guard case .permissionRequest(_, _, _, _, _, let ask)? = ClaudeStreamParser.parse(line).first else { return nil }
            return ask
        }
        XCTAssertEqual(ask(#""decision_reason":"\u001b[33mrm -rf\u001b[0m deletes\nfiles outside the project","decision_reason_type":"safetyCheck","classifier_approvable":false"#),
                       PermissionAsk(reason: "rm -rf deletes files outside the project", safetyCheck: true),
                       "colors and line breaks out; a safety check reads as dangerous")
        XCTAssertEqual(ask(#""decision_reason":"Matches ask rule Bash(git push:*)","decision_reason_type":"rule","suppress_always_allow_rule":true"#),
                       PermissionAsk(reason: "Matches ask rule Bash(git push:*)", noAlways: true))
        XCTAssertEqual(ask(#""decision_reason":"Permission mode is default","decision_reason_type":"mode""#), PermissionAsk(),
                       "the permission mode asking says nothing new")
        XCTAssertEqual(ask(#""decision_reason_type":"subcommandResults","classifier_approvable":true"#), PermissionAsk(safetyCheck: true),
                       "a safety check inside a compound command still counts")
        XCTAssertEqual(PermissionAsk.clean("\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07} ok"), "link ok")
        XCTAssertEqual(PermissionAsk.clean(String(repeating: "a", count: 500)).count, PermissionAsk.maxReason)
    }

    func testMcpServerQuestionThroughClaudeCode() {
        let confirm = #"{"type":"control_request","request_id":"e1","request":{"subtype":"elicitation","mcp_server_name":"deploy","message":"Deploy to production?","requested_schema":{"type":"object","properties":{}},"title":"Deploy"}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(confirm),
                       [.elicitation(ClaudeElicitation(requestID: "e1", server: "deploy", message: "Deploy to production?", title: "Deploy",
                                                       isConfirmation: true))])
        let form = #"{"type":"control_request","request_id":"e2","request":{"subtype":"elicitation","mcp_server_name":"x","message":"Name?","requested_schema":{"type":"object","properties":{"name":{"type":"string"}}}}}"#
        guard case .elicitation(let question)? = ClaudeStreamParser.parse(form).first else { return XCTFail("no question") }
        XCTAssertFalse(question.isConfirmation, "fields to fill in are no yes or no")
        let link = #"{"type":"control_request","request_id":"e3","request":{"subtype":"elicitation","mcp_server_name":"x","message":"Sign in","mode":"url","url":"https://x"}}"#
        guard case .elicitation(let page)? = ClaudeStreamParser.parse(link).first else { return XCTFail("no question") }
        XCTAssertFalse(page.isConfirmation)

        let accept = ClaudeStreamParser.elicitationResponse(requestID: "e1", accept: true)
        XCTAssertTrue(accept.contains(#""action":"accept""#) && accept.contains(#""request_id":"e1""#) && accept.contains(#""content":{}"#))
        XCTAssertTrue(ClaudeStreamParser.elicitationResponse(requestID: "e2", accept: false).contains(#""action":"decline""#))
    }

    func testStopOneBackgroundSubagent() {
        XCTAssertEqual(Subagents.taskID(launchNote: "Async agent launched successfully.\nagentId: a1b2 (use it to follow up)"), "a1b2")
        XCTAssertNil(Subagents.taskID(launchNote: "Done: the chats are audited."))
        let request = ClaudeStreamParser.stopTaskRequest(id: "r1", taskID: "a1b2")
        XCTAssertTrue(request.contains(#""subtype":"stop_task""#) && request.contains(#""task_id":"a1b2""#))
        XCTAssertTrue(RunProvider.claude.capabilities.stopsOneSubagent)
        XCTAssertFalse(RunProvider.codex.capabilities.stopsOneSubagent)
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

final class ConnectorSignInTests: XCTestCase {
    func testClaudeInitListsConnectorsThatNeedSignIn() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc","model":"m","mcp_servers":[{"name":"claude.ai Supabase","status":"needs-auth"},{"name":"nook","status":"connected"},{"name":"plugin:design:linear","status":"needs-auth"}]}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line), [.initialized(sessionID: "abc", model: "m"),
                                                       .connectorsNeedingSignIn(["claude.ai Supabase", "plugin:design:linear"])])
    }

    func testClaudeControlReplies() {
        let success = #"{"type":"control_response","response":{"subtype":"success","request_id":"nook-mcp-1","response":{"authUrl":"https://claude.ai/x","callbackExpected":false}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(success),
                       [.controlReply(requestID: "nook-mcp-1", response: JSONBox(["authUrl": "https://claude.ai/x", "callbackExpected": false]), error: nil)])
        let failure = #"{"type":"control_response","response":{"subtype":"error","request_id":"nook-mcp-2","error":"Server not found: x"}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(failure), [.controlReply(requestID: "nook-mcp-2", response: nil, error: "Server not found: x")])
    }

    func testClaudeRequests() {
        XCTAssertEqual(ClaudeStreamParser.mcpAuthenticateRequest(id: "r", server: "claude.ai Supabase"),
                       #"{"request":{"serverName":"claude.ai Supabase","subtype":"mcp_authenticate"},"request_id":"r","type":"control_request"}"# + "\n")
        XCTAssertTrue(ClaudeStreamParser.mcpStatusRequest(id: "s").contains(#""subtype":"mcp_status""#))
        XCTAssertTrue(ClaudeStreamParser.mcpReconnectRequest(id: "t", server: "x").contains(#""subtype":"mcp_reconnect""#))
    }

    func testCodexStatusList() {
        let response: [String: Any] = ["data": [["name": "linear", "authStatus": "notLoggedIn"], ["name": "github", "authStatus": "oAuth"],
                                                ["name": "local", "authStatus": "unsupported"]]]
        XCTAssertEqual(ConnectorSignIns.codex(response), ["linear"])
    }

    func testMergeKeepsWaitingAndSortsByTitle() {
        let current = [ConnectorSignIn(name: "claude.ai Supabase", waiting: true)]
        let merged = ConnectorSignIns.merged(["plugin:design:linear", "claude.ai Supabase", "claude.ai Asana", "plugin:design:linear"], into: current)
        XCTAssertEqual(merged.map(\.title), ["Asana", "linear", "Supabase"])
        XCTAssertEqual(merged.filter(\.waiting).map(\.name), ["claude.ai Supabase"])
    }

    func testConnectorsShowTheirLogo() {
        XCTAssertEqual(ConnectorSignIn(name: "claude.ai Google Calendar").iconDomain, "calendar.google.com")
        XCTAssertEqual(ConnectorSignIn(name: "plugin:engineering:linear").iconDomain, "linear.app")
        XCTAssertEqual(ConnectorSignIn(name: "plugin:sales:microsoft-365").iconDomain, "microsoft.com")
        XCTAssertEqual(ConnectorSignIn(name: "claude.ai Supabase").iconDomain, "supabase.com")
        XCTAssertEqual(ConnectorSignIn(name: "Hugging Face").iconDomain, "huggingface.co")
        XCTAssertNil(ConnectorSignIn(name: "my-own-server").iconDomain)
    }

    func testSessionsOfOneAgentAccountAndMachineShareSignIns() {
        let personal = ConnectorSignIns.account(provider: .claude, profileID: "", machine: nil)
        XCTAssertEqual(personal, ConnectorSignIns.account(provider: .claude, profileID: "", machine: nil))
        XCTAssertNotEqual(personal, ConnectorSignIns.account(provider: .claude, profileID: "work", machine: nil))
        XCTAssertNotEqual(personal, ConnectorSignIns.account(provider: .codex, profileID: "", machine: nil))
        XCTAssertNotEqual(personal, ConnectorSignIns.account(provider: .claude, profileID: "", machine: "buildbox"))
    }

    func testDismissedOnesHideUnlessWaiting() {
        let all = [ConnectorSignIn(name: "a"), ConnectorSignIn(name: "b", waiting: true), ConnectorSignIn(name: "c")]
        XCTAssertEqual(ConnectorSignIns.shown(all, dismissed: ["a", "b"]).map(\.name), ["b", "c"])
    }
}
