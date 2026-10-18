import XCTest

/// Agents over ACP (Gemini CLI, OpenCode, Cursor, Grok): how they start, the messages Nook sends, and how session
/// updates and permission requests become timeline events. Shapes follow the ACP v1 schema.
final class AcpAgentTests: XCTestCase {
    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testLaunchArgumentsMatchTheRegistry() {
        XCTAssertEqual(AcpLaunch.arguments(.gemini, permission: .ask), ["--acp"])
        XCTAssertEqual(AcpLaunch.arguments(.opencode, permission: .ask), ["acp"])
        XCTAssertEqual(AcpLaunch.arguments(.cursor, permission: .acceptEdits), ["acp"])
        XCTAssertEqual(AcpLaunch.arguments(.grok, permission: .ask), ["agent", "stdio"])
        XCTAssertEqual(AcpLaunch.arguments(.grok, permission: .bypass), ["agent", "--always-approve", "stdio"])
        XCTAssertTrue(RunProvider.opencode.usesACP && RunProvider.cursor.usesACP && RunProvider.grok.usesACP && RunProvider.gemini.usesACP)
        XCTAssertFalse(RunProvider.claude.usesACP || RunProvider.codex.usesACP)
    }

    func testMessagesCarryJsonrpc() {
        let message = object(AcpRPC.request(id: 1, method: "initialize", params: AcpRPC.initializeParams()))
        XCTAssertEqual(message["jsonrpc"] as? String, "2.0")
        let params = message["params"] as? [String: Any]
        XCTAssertEqual(params?["protocolVersion"] as? Int, 1)
        XCTAssertEqual(((params?["clientCapabilities"] as? [String: Any])?["terminal"]) as? Bool, false,
                       "Nook does not run terminals for the agent")
        XCTAssertEqual(object(AcpRPC.notification(method: "session/cancel", params: ["sessionId": "s"]))["method"] as? String, "session/cancel")
    }

    func testSessionParamsCarryTheBridge() {
        let new = AcpRPC.sessionParams(cwd: "/w", bridge: (command: "/x/nook-mcp", args: ["--agent", "grok"], env: ["NOOK_RUN_ID": "r1"]), loadID: nil)
        XCTAssertNil(new["sessionId"])
        let server = (new["mcpServers"] as? [[String: Any]])?.first
        XCTAssertEqual(server?["name"] as? String, "nook")
        XCTAssertEqual(server?["command"] as? String, "/x/nook-mcp")
        XCTAssertEqual((server?["env"] as? [[String: String]])?.first?["name"], "NOOK_RUN_ID")
        let load = AcpRPC.sessionParams(cwd: "/w", bridge: nil, loadID: "s-1")
        XCTAssertEqual(load["sessionId"] as? String, "s-1")
        XCTAssertEqual((load["mcpServers"] as? [Any])?.count, 0, "mcpServers is required, empty when there is no bridge")
        XCTAssertEqual(((AcpRPC.promptParams(sessionID: "s", text: "hoi")["prompt"] as? [[String: Any]])?.first)?["text"] as? String, "hoi")
    }

    func testPermissionOutcomes() {
        let options = [AcpPermissionOption(id: "a1", name: "Allow", kind: "allow_once"),
                       AcpPermissionOption(id: "a2", name: "Always", kind: "allow_always"),
                       AcpPermissionOption(id: "r1", name: "Reject", kind: "reject_once")]
        func chosen(_ allow: Bool, _ always: Bool, _ list: [AcpPermissionOption] = []) -> String? {
            ((AcpRPC.permissionOutcome(list.isEmpty ? options : list, allow: allow, always: always)["outcome"] as? [String: Any])?["optionId"]) as? String
        }
        XCTAssertEqual(chosen(true, false), "a1")
        XCTAssertEqual(chosen(true, true), "a2")
        XCTAssertEqual(chosen(false, false), "r1")
        XCTAssertEqual(chosen(true, true, [options[0]]), "a1", "no always option: allow this once")
        let cancelled = AcpRPC.permissionOutcome([], allow: true, always: false)["outcome"] as? [String: Any]
        XCTAssertEqual(cancelled?["outcome"] as? String, "cancelled")
    }

    func testRightsDecideWhatRunsWithoutAsking() {
        func call(_ kind: String) -> AcpToolCall { AcpToolCall(id: "t", title: "", kind: kind, status: nil, input: nil, output: "", paths: []) }
        XCTAssertTrue(AcpRPC.autoAllows(call("read"), permission: .ask, mode: .agent))
        XCTAssertFalse(AcpRPC.autoAllows(call("edit"), permission: .ask, mode: .agent))
        XCTAssertTrue(AcpRPC.autoAllows(call("edit"), permission: .acceptEdits, mode: .agent))
        XCTAssertFalse(AcpRPC.autoAllows(call("execute"), permission: .acceptEdits, mode: .agent))
        XCTAssertTrue(AcpRPC.autoAllows(call("execute"), permission: .bypass, mode: .agent))
        XCTAssertFalse(AcpRPC.autoAllows(call("edit"), permission: .bypass, mode: .plan), "plan mode only reads")
    }

    func testUpdatesBecomeEvents() {
        func events(_ line: String) -> [AcpEvent] { AcpMapper.events(AcpRPC.parse(line)!) }
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hal"}}}}"#),
                       [.messageChunk("Hal")])
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"**Plan**"}}}}"#),
                       [.thoughtChunk("**Plan**")])
        let tool = events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit App.swift","kind":"edit","status":"pending","content":[{"type":"diff","path":"/w/App.swift","newText":"x"}],"rawInput":{"file_path":"/w/App.swift"}}}}"#)
        guard case .toolCall(let call)? = tool.first else { return XCTFail("\(tool)") }
        XCTAssertEqual(call.id, "t1")
        XCTAssertEqual(call.toolName, "edit")
        XCTAssertEqual(call.paths, ["/w/App.swift"])
        XCTAssertEqual(call.status, "pending")
        let update = events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"ok"}}]}}}"#)
        guard case .toolCallUpdate(let done)? = update.first else { return XCTFail("\(update)") }
        XCTAssertEqual(done.status, "completed")
        XCTAssertEqual(done.output, "ok")
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"plan","entries":[{"content":"Tests","status":"completed","priority":"high"},{"content":"Fix","status":"pending","priority":"high"}]}}}"#),
                       [.plan(["☑ Tests", "☐ Fix"])])
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":53000,"size":200000,"cost":{"amount":0.42,"currency":"USD"}}}}"#),
                       [.usage(used: 53000, size: 200000, costUSD: 0.42)])
    }

    func testRequests() {
        func events(_ line: String) -> [AcpEvent] { AcpMapper.events(AcpRPC.parse(line)!) }
        let permission = events(#"{"jsonrpc":"2.0","id":5,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t2","title":"npm test","kind":"execute"},"options":[{"optionId":"o1","name":"Allow","kind":"allow_once"}]}}"#)
        guard case .permission(let rpc, let call, let options)? = permission.first else { return XCTFail("\(permission)") }
        XCTAssertEqual(rpc, .int(5))
        XCTAssertEqual(call.toolName, "shell")
        XCTAssertEqual(options.map(\.kind), ["allow_once"])
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","id":6,"method":"fs/read_text_file","params":{"path":"/etc/passwd"}}"#), [.unsupportedRequest(.int(6))],
                       "Nook never reads files for the agent")
    }

    func testStopReasonAndUsage() {
        let stop = AcpRPC.stop(["stopReason": "end_turn", "usage": ["totalTokens": 130, "inputTokens": 100, "outputTokens": 20, "thoughtTokens": 10, "cachedReadTokens": 40]])
        XCTAssertEqual(stop.reason, "end_turn")
        XCTAssertEqual(stop.usage.inputTokens, 100)
        XCTAssertEqual(stop.usage.outputTokens, 30, "thought tokens count as output")
        XCTAssertEqual(stop.usage.cacheReadTokens, 40)
        XCTAssertEqual(AcpRPC.stop([:]).reason, "end_turn")
    }
}
