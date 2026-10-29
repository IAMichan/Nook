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
        var planned = info
        planned["modes"] = ["currentModeId": "architect-plan", "availableModes": [["id": "code"], ["id": "architect-plan"]]]
        XCTAssertEqual(AcpSessionSettings.mode(plan: false, info: planned, starting: "code"), "code",
                       "the session's options follow the agent into plan mode; leaving it goes back to where it started")
        XCTAssertEqual(AcpSessionSettings.steps(session: "s", info: info, model: "b", appliedModel: "a", mode: "architect-plan", appliedMode: "code"), [
            .init(method: "session/set_model", params: ["sessionId": "s", "modelId": "b"], target: .model("b")),
            .init(method: "session/set_mode", params: ["sessionId": "s", "modeId": "architect-plan"], target: .mode("architect-plan"))
        ])
    }

    private static let thinkingSession: [String: Any] = [
        "configOptions": [
            ["id": "model", "category": "model", "type": "select", "currentValue": "pro",
             "options": [["value": "pro", "name": "Pro"], ["value": "flash", "name": "Flash"]]],
            ["id": "reasoning", "category": "thought_level", "type": "select", "currentValue": "medium",
             "options": [["group": "Levels", "name": "Levels",
                          "options": [["value": "low", "name": "Low"], ["value": "medium", "name": "Medium"],
                                      ["value": "max", "name": "Maximum"]]]]],
            ["id": "mode", "category": "mode", "type": "select", "currentValue": "code",
             "options": [["value": "code"], ["value": "plan"]]]
        ]
    ]

    func testSessionSettingsSetTheEffortBetweenModelAndMode() {
        let info = Self.thinkingSession
        XCTAssertEqual(AcpSessionSettings.currentEffort(info), "medium")
        XCTAssertEqual(AcpSessionSettings.effortLevels(info), [AgentModel(id: "low", name: "Low"),
                                                               AgentModel(id: "medium", name: "Medium", isDefault: true),
                                                               AgentModel(id: "max", name: "Maximum")])
        let steps = AcpSessionSettings.steps(session: "s", info: info, model: "flash", appliedModel: "pro", effort: "max",
                                             appliedEffort: "medium", mode: "plan", appliedMode: "code")
        XCTAssertEqual(steps.map(\.target), [.model("flash"), .effort("max"), .mode("plan")])
        XCTAssertEqual(steps[1].params, ["sessionId": "s", "configId": "reasoning", "value": "max"])
        XCTAssertEqual(steps[1].method, "session/set_config_option")
    }

    func testSessionSettingsSkipAnEffortTheAgentDoesNotOffer() {
        let info = Self.thinkingSession
        XCTAssertEqual(AcpSessionSettings.steps(session: "s", info: info, model: "", appliedModel: nil, effort: "medium",
                                                appliedEffort: "medium", mode: nil, appliedMode: nil), [], "already set")
        XCTAssertEqual(AcpSessionSettings.steps(session: "s", info: info, model: "", appliedModel: nil, effort: "xhigh",
                                                appliedEffort: "medium", mode: nil, appliedMode: nil), [], "not one of its levels")
        XCTAssertEqual(AcpSessionSettings.steps(session: "s", info: Self.antigravitySession, model: "", appliedModel: nil, effort: "high",
                                                appliedEffort: nil, mode: nil, appliedMode: nil), [], "no thought_level option")
        XCTAssertNil(AcpSessionSettings.currentEffort(Self.antigravitySession))
        XCTAssertEqual(AcpSessionSettings.effortLevels(Self.antigravitySession), [])
    }

    func testConfigOptionsReplaceTheSessionsOptions() {
        let changed: [[String: Any]] = [
            ["id": "reasoning", "category": "thought_level", "type": "select", "currentValue": "high",
             "options": [["value": "high", "name": "High"]]]
        ]
        let info = AcpSessionSettings.updating(Self.thinkingSession, configOptions: changed)
        XCTAssertEqual(AcpSessionSettings.currentEffort(info), "high")
        XCTAssertEqual(AcpSessionSettings.effortLevels(info).map(\.id), ["high"])
        XCTAssertEqual(AcpSessionSettings.currentEffort(AcpSessionSettings.updating(Self.thinkingSession, configOptions: nil)), "medium")
    }

    func testSessionStateUpdates() {
        func events(_ update: [String: Any]) -> [AcpEvent] {
            AcpMapper.events(.notification(method: "session/update", params: JSONBox(["sessionId": "s", "update": update])))
        }
        let commands = events(["sessionUpdate": "available_commands_update", "availableCommands": [
            ["name": "web", "description": "Search the web", "input": ["hint": "query"]],
            ["name": "/compact", "description": ""],
            ["name": "two words"],
            ["name": "web"]
        ]])
        XCTAssertEqual(commands, [.commands([AgentSlashCommand(name: "web", detail: "Search the web", takesInput: true),
                                             AgentSlashCommand(name: "compact", detail: nil, takesInput: false)])])
        XCTAssertEqual(events(["sessionUpdate": "current_mode_update", "currentModeId": "plan"]), [.currentMode("plan")])
        let options = events(["sessionUpdate": "config_option_update", "configOptions": [["id": "model"]]])
        XCTAssertEqual(options.count, 1)
        XCTAssertTrue(options.allSatisfy(\.isSessionState))
        XCTAssertTrue(commands.allSatisfy(\.isSessionState))
        XCTAssertFalse(AcpEvent.messageChunk("hi").isSessionState)
        XCTAssertFalse(commands.contains(where: \.isWakeEvidence), "an offer is not work")
    }

    func testErrorsThatNookAnswersItself() {
        XCTAssertTrue(AgentErrorText.needsSignIn("Authentication required"))
        XCTAssertTrue(AgentErrorText.needsSignIn("Error: not logged in. Run login first."))
        XCTAssertFalse(AgentErrorText.needsSignIn("Authenticate called with method oauth"), "a log line is not the error")
        XCTAssertTrue(AgentErrorText.sessionGone("Session not found: 3f2a"))
        XCTAssertTrue(AgentErrorText.sessionGone("no rollout found for thread id 019a"))
        XCTAssertTrue(AgentErrorText.sessionGone("Unknown session abc"))
        XCTAssertFalse(AgentErrorText.sessionGone("Model not found"), "only the conversation being gone starts a new one")
        XCTAssertFalse(AgentErrorText.sessionGone("network timeout"))
        XCTAssertEqual(AcpRPC.authMethodIDs(["authMethods": [["id": "oauth-personal", "name": "Google"], ["id": "gemini-api-key"], ["name": "x"]]]),
                       ["oauth-personal", "gemini-api-key"])
        XCTAssertEqual((AcpRPC.cancelledOutcome["outcome"] as? [String: String])?["outcome"], "cancelled")
    }

    func testGeminiChatLogReadsTheJsonlForm() throws {
        let lines = [
            #"{"sessionId":"s1","projectHash":"abc","startTime":"2026-10-29T10:00:00.000Z","lastUpdated":"2026-10-29T10:00:00.000Z","kind":"main"}"#,
            #"{"id":"u1","timestamp":"2026-10-29T10:00:01.000Z","type":"user","content":[{"text":"Fix the login"}]}"#,
            #"{"id":"g1","timestamp":"2026-10-29T10:00:02.000Z","type":"gemini","content":"","model":"gemini-3-pro","toolCalls":[{"id":"t1","name":"read_file","args":{}}]}"#,
            #"{"$patch":{"id":"g1","content":"Done.","toolCalls":[{"id":"t1","result":[{"text":"ok"}]}]}}"#,
            #"{"id":"u2","type":"user","content":"and the logout"}"#,
            #"{"id":"g2","type":"gemini","content":"Working"}"#,
            #"{"$rewindTo":"u2"}"#,
            #"{"$set":{"lastUpdated":"2026-10-29T10:05:00.000Z","directories":["/Users/me/app"]}}"#
        ]
        let chat = try XCTUnwrap(GeminiChatLog.read(Data(lines.joined(separator: "\n").utf8)))
        XCTAssertEqual(chat.messages.compactMap { $0["id"] as? String }, ["u1", "g1"], "a rewind drops that message and what follows")
        XCTAssertEqual(chat.messages[1]["content"] as? String, "Done.", "a patch fills in the content")
        XCTAssertNotNil((chat.messages[1]["toolCalls"] as? [[String: Any]])?.first?["result"])
        XCTAssertEqual(chat.metadata["sessionId"] as? String, "s1")
        XCTAssertEqual(chat.metadata["lastUpdated"] as? String, "2026-10-29T10:05:00.000Z")
        XCTAssertEqual(GeminiChatLog.folder(chat: chat, file: URL(fileURLWithPath: "/x/.gemini/tmp/app/chats/a.jsonl"),
                                            runtimeDirectory: URL(fileURLWithPath: "/x/.gemini")), "/Users/me/app")
        let messages = AgentTranscript.gemini(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(messages.first?.text, "Fix the login")
    }

    func testGeminiChatLogStillReadsTheJsonForm() throws {
        let json = #"{"sessionId":"s0","messages":[{"id":"a","type":"user","content":"hi"}]}"#
        XCTAssertEqual(try XCTUnwrap(GeminiChatLog.read(Data(json.utf8))).messages.count, 1)
        XCTAssertNil(GeminiChatLog.read(Data("not json".utf8)))
        XCTAssertTrue(GeminiChatLog.isLog(path: "/Users/me/.gemini/tmp/app/chats/session-2026-10-29T10-00-abcd1234.jsonl"))
        XCTAssertFalse(GeminiChatLog.isLog(path: "/Users/me/.claude/projects/x/abc.jsonl"))
    }

    func testSessionCapabilities() {
        let all = AcpSessionCapabilities(initialize: ["agentCapabilities": [
            "loadSession": true, "sessionCapabilities": ["list": [String: Any](), "resume": [String: Any](), "fork": [String: Any]()]
        ]])
        XCTAssertEqual(all, AcpSessionCapabilities(load: true, list: true, resume: true))
        XCTAssertEqual(all.continueMethod, "session/resume", "resume continues without replaying what Nook keeps")
        let loadOnly = AcpSessionCapabilities(initialize: ["agentCapabilities": ["loadSession": true, "sessionCapabilities": ["list": NSNull()]]])
        XCTAssertEqual(loadOnly, AcpSessionCapabilities(load: true), "null is not offered")
        XCTAssertEqual(loadOnly.continueMethod, "session/load")
        XCTAssertFalse(AcpSessionCapabilities(initialize: [:]).continues)
    }

    func testListedSessions() {
        let page = AcpListedSession.page([
            "sessions": [
                ["sessionId": "ses_1", "cwd": "/Users/me/app", "title": "Fix login", "updatedAt": "2026-10-29T10:00:00.000Z"],
                ["sessionId": "ses_2", "cwd": "/Users/me/web", "updatedAt": "2026-10-28T09:00:00Z"],
                ["sessionId": "", "cwd": "/x"],
                ["sessionId": "ses_3"]
            ],
            "nextCursor": "c2"
        ])
        XCTAssertEqual(page.sessions.map(\.id), ["ses_1", "ses_2"], "a session without id or folder is left out")
        XCTAssertEqual(page.sessions.first?.title, "Fix login")
        XCTAssertNotNil(page.sessions.first?.updated)
        XCTAssertNotNil(page.sessions.last?.updated, "seconds without fractions read too")
        XCTAssertEqual(page.next, "c2")
        XCTAssertNil(AcpListedSession.page(["sessions": [], "nextCursor": ""]).next)
        XCTAssertEqual(AcpRPC.listParams(cursor: nil).count, 0)
        XCTAssertEqual(AcpRPC.listParams(cursor: "c2")["cursor"] as? String, "c2")
    }

    func testReplayBecomesMessages() {
        func update(_ kind: String, _ text: String) -> [AcpEvent] {
            AcpMapper.events(.notification(method: "session/update", params: JSONBox(["sessionId": "s", "update": [
                "sessionUpdate": kind, "content": ["type": "text", "text": text]
            ]])))
        }
        var replay = AcpReplay()
        for event in update("user_message_chunk", "Fix ") + update("user_message_chunk", "the login")
            + update("agent_message_chunk", "Done") + update("agent_message_chunk", ".") + update("agent_thought_chunk", "hm") {
            replay.add(event)
        }
        XCTAssertEqual(replay.finished.map(\.text), ["Fix the login", "Done."])
        XCTAssertEqual(replay.finished.map(\.side), [.user, .agent])
    }

    func testPicturesGoAsImagesOrLinks() {
        let png = URL(fileURLWithPath: "/tmp/shot.png")
        let heic = URL(fileURLWithPath: "/tmp/photo.heic")
        let read: (URL) -> Data? = { _ in Data([1, 2, 3]) }
        let taking = AcpRPC.attachments([png, heic], images: true, read: read)
        XCTAssertEqual(taking[0]["type"] as? String, "image")
        XCTAssertEqual(taking[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(taking[0]["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(taking[1]["type"] as? String, "resource_link", "a type models do not read goes as its file")
        let linking = AcpRPC.attachments([png], images: false, read: read)
        XCTAssertEqual(linking[0]["type"] as? String, "resource_link")
        XCTAssertEqual(linking[0]["uri"] as? String, "file:///tmp/shot.png")
        XCTAssertEqual(linking[0]["name"] as? String, "shot.png")
        let prompt = AcpRPC.promptParams(sessionID: "s", text: "hi", attachments: linking)["prompt"] as? [[String: Any]]
        XCTAssertEqual(prompt?.count, 2)
        XCTAssertTrue(AcpSessionCapabilities(initialize: ["agentCapabilities": ["promptCapabilities": ["image": true]]]).images)
    }

    func testEditsBecomeTheInputEditRowsRead() throws {
        let one = AcpMapper.events(.notification(method: "session/update", params: JSONBox(["sessionId": "s", "update": [
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Edit", "kind": "edit",
            "content": [["type": "diff", "path": "/w/a.swift", "oldText": "let a = 1", "newText": "let a = 2"]]
        ]])))
        guard case .toolCall(let call) = try XCTUnwrap(one.first) else { return XCTFail("a tool call") }
        let input = try XCTUnwrap(call.editInput?.object as? [String: Any])
        XCTAssertEqual(input["old_string"] as? String, "let a = 1")
        XCTAssertEqual(input["new_string"] as? String, "let a = 2")
        XCTAssertEqual(EditLines.of(tool: call.toolName, input: input), EditLines(added: 1, removed: 1))
        XCTAssertNotNil(EditPatch.make(tool: call.toolName, input: input))
        var two = call
        two.diffs.append(AcpDiff(path: "/w/new.swift", oldText: nil, newText: "a\nb"))
        let several = try XCTUnwrap(two.editInput?.object as? [String: Any])
        XCTAssertEqual((several["edits"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(EditLines.of(tool: two.toolName, input: several), EditLines(added: 3, removed: 1),
                       "several places, and a new file, count as one edit")
        XCTAssertNil(AcpToolCall(id: "x", title: "", kind: "read", status: nil, input: nil, output: "", paths: []).editInput)
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
