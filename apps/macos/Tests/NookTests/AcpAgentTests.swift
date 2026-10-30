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
        let failed = events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t3","status":"failed","rawOutput":{"error":"file not found"}}}}"#)
        guard case .toolCallUpdate(let broken)? = failed.first else { return XCTFail("\(failed)") }
        XCTAssertEqual(broken.output, "file not found", "a failed call says why, from rawOutput when it has no content")
        XCTAssertEqual(AcpMapper.rawOutput("denied"), "denied")
        XCTAssertEqual(AcpMapper.rawOutput(["error": ["message": "outside the workspace"]]), "outside the workspace")
        XCTAssertEqual(AcpMapper.rawOutput(["lines": 3]), #"{"lines":3}"#)
        XCTAssertNil(AcpMapper.rawOutput([String: Any]()))
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"plan","entries":[{"content":"Tests","status":"completed","priority":"high"},{"content":"Fix","status":"pending","priority":"high"}]}}}"#),
                       [.plan([RunTaskStep(text: "Tests", status: .done), RunTaskStep(text: "Fix", status: .pending)])])
        XCTAssertEqual(events(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":53000,"size":200000,"cost":{"amount":0.42,"currency":"USD"}}}}"#),
                       [.usage(used: 53000, size: 200000, costUSD: 0.42)])
    }

    func testReadsSettleOnceTheAgentMovesOn() {
        func call(_ id: String, _ kind: String, _ status: String? = "in_progress") -> AcpToolCall {
            AcpToolCall(id: id, title: "Running view_file", kind: kind, status: status, input: nil, output: "", paths: [])
        }
        func done(_ id: String) -> AcpEvent { .toolCallUpdate(call(id, "", "completed")) }
        // Antigravity 1.3.0 as recorded: a read per step, each closed only when the turn ends.
        var reads = AcpOpenReads()
        XCTAssertEqual(reads.settle(after: .toolCall(call("a", "read"))), [])
        XCTAssertEqual(reads.settle(after: .usage(used: 1, size: 2, costUSD: nil)), [])
        XCTAssertEqual(reads.settle(after: .toolCall(call("b", "read"))), ["a"], "a later batch means the read came back")
        XCTAssertEqual(reads.settle(after: .messageChunk(" ")), [])
        XCTAssertEqual(reads.settle(after: .messageChunk("The first line")), ["b"])
        XCTAssertEqual(reads.settle(after: done("a")), [])

        // Reads announced together may run side by side; a command is never settled.
        reads = AcpOpenReads()
        XCTAssertEqual(reads.settle(after: .toolCall(call("c", "read"))), [])
        XCTAssertEqual(reads.settle(after: .toolCall(call("d", "read"))), [])
        XCTAssertEqual(reads.settle(after: .toolCall(call("e", "execute"))), [])
        XCTAssertEqual(reads.settle(after: done("c")), [])
        XCTAssertEqual(reads.settle(after: .thoughtChunk("Next")), ["d"])

        // A read the agent closed itself is not settled again.
        reads = AcpOpenReads()
        XCTAssertEqual(reads.settle(after: .toolCall(call("f", "read"))), [])
        XCTAssertEqual(reads.settle(after: done("f")), [])
        XCTAssertEqual(reads.settle(after: .messageChunk("Done")), [])
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

    // MARK: Session settings

    /// Antigravity's `session/new` reply: a model and a mode config option next to `models` and `modes`.
    private static let antigravitySession: [String: Any] = [
        "sessionId": "s1",
        "modes": ["currentModeId": "default", "availableModes": [["id": "default"], ["id": "auto_edit"], ["id": "yolo"]]],
        "configOptions": [
            ["id": "model", "category": "model", "type": "select", "currentValue": "gemini-3.8-flash-high",
             "options": [["value": "gemini-4-argon-medium", "name": "Gemini 4 Argon (Medium)"],
                         ["value": "gemini-3.8-flash-high", "name": "Gemini 3.8 Flash (High)"]]],
            ["id": "mode", "category": "mode", "type": "select", "currentValue": "default",
             "options": [["value": "default"], ["value": "auto_edit"], ["value": "yolo"]]]
        ],
        "models": ["currentModelId": "gemini-3.8-flash-high",
                   "availableModels": [["modelId": "gemini-4-argon-medium"], ["modelId": "gemini-3.8-flash-high"]]]
    ]

    func testSessionSettingsSetTheModelBeforeTheMode() {
        let info = Self.antigravitySession
        XCTAssertEqual(AcpSessionSettings.currentModel(info), "gemini-3.8-flash-high")
        XCTAssertEqual(AcpSessionSettings.currentMode(info), "default")
        let steps = AcpSessionSettings.steps(session: "s1", info: info, model: "gemini-4-argon-medium", appliedModel: "gemini-3.8-flash-high",
                                             mode: "yolo", appliedMode: "default")
        XCTAssertEqual(steps, [
            .init(method: "session/set_config_option", params: ["sessionId": "s1", "configId": "model", "value": "gemini-4-argon-medium"],
                  target: .model("gemini-4-argon-medium")),
            .init(method: "session/set_config_option", params: ["sessionId": "s1", "configId": "mode", "value": "yolo"], target: .mode("yolo"))
        ])
    }

    func testSessionSettingsSkipWhatIsAlreadySet() {
        let info = Self.antigravitySession
        XCTAssertEqual(AcpSessionSettings.steps(session: "s1", info: info, model: "gemini-3.8-flash-high", appliedModel: "gemini-3.8-flash-high",
                                                mode: "default", appliedMode: "default"), [])
        XCTAssertEqual(AcpSessionSettings.steps(session: "s1", info: info, model: "", appliedModel: nil, mode: nil, appliedMode: nil), [],
                       "no model chosen: the agent's own default stays")
        XCTAssertEqual(AcpSessionSettings.steps(session: "s1", info: info, model: "", appliedModel: nil, mode: "unknown", appliedMode: "default"),
                       [], "a mode the agent does not offer is not sent")
    }

    func testSessionSettingsWithoutConfigOptions() {
        let info: [String: Any] = [
            "modes": ["currentModeId": "code", "availableModes": [["id": "code"], ["id": "architect-plan"]]],
            "models": ["currentModelId": "a", "availableModels": [["modelId": "a"], ["modelId": "b"]]]
        ]
        XCTAssertEqual(AcpSessionSettings.mode(plan: true, info: info), "architect-plan")
        XCTAssertEqual(AcpSessionSettings.mode(plan: false, info: info), "code", "leaving Plan mode returns to the mode it started in")
        XCTAssertEqual(AcpSessionSettings.steps(session: "s", info: info, model: "b", appliedModel: "a", mode: "architect-plan", appliedMode: "code"), [
            .init(method: "session/set_model", params: ["sessionId": "s", "modelId": "b"], target: .model("b")),
            .init(method: "session/set_mode", params: ["sessionId": "s", "modeId": "architect-plan"], target: .mode("architect-plan"))
        ])
    }

    func testAgentLogLinesKeepOnlyErrors() {
        let lines = [
            "I1029 16:35:47.481079 8387203840 agent.py:109] Starting connection and creating conversation...",
            "W1029 16:35:51.682007 6195638272 proxy_server.py:225] Proxy client disconnected: [Errno 32] Broken pipe",
            "E1029 16:35:52.000001 6195638272 server.py:12] Quota exceeded for gemini-4-argon-high",
            "Traceback (most recent call last):"
        ]
        XCTAssertEqual(AgentLogLines.withoutLog(lines), ["Quota exceeded for gemini-4-argon-high", "Traceback (most recent call last):"])
    }
}
