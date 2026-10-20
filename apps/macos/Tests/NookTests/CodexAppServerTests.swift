import XCTest

/// Codex through `codex app-server`: the messages Nook sends, and how Codex's notifications and requests become timeline
/// events. Shapes follow Codex's own generated schema.
final class CodexAppServerTests: XCTestCase {
    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testParse() {
        XCTAssertEqual(CodexRPC.parse(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#),
                       .response(id: 3, result: JSONBox(["thread": ["id": "t1"]]), error: nil))
        XCTAssertEqual(CodexRPC.parse(#"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"#),
                       .response(id: 4, result: nil, error: "Method not found"))
        XCTAssertEqual(CodexRPC.parse(#"{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"u1"}}}"#),
                       .notification(method: "turn/started", params: JSONBox(["threadId": "t1", "turn": ["id": "u1"]])))
        XCTAssertEqual(CodexRPC.parse(#"{"id":"r-9","method":"item/fileChange/requestApproval","params":{}}"#),
                       .request(id: .string("r-9"), method: "item/fileChange/requestApproval", params: JSONBox([String: Any]())))
        XCTAssertNil(CodexRPC.parse("not json"))
    }

    func testRequestsHaveNoJsonrpcField() {
        let line = CodexRPC.request(id: 1, method: "initialize", params: CodexRPC.initializeParams())
        XCTAssertTrue(line.hasSuffix("\n"))
        let message = object(line)
        XCTAssertNil(message["jsonrpc"], "codex app-server speaks JSON-RPC without the version field")
        XCTAssertEqual(message["method"] as? String, "initialize")
        let capabilities = (message["params"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(capabilities?["experimentalApi"] as? Bool, true)
        XCTAssertEqual(object(CodexRPC.notification(method: "initialized"))["method"] as? String, "initialized")
    }

    func testTurnStartPolicies() {
        func params(_ mode: ExecutionMode, _ permission: PermissionPolicy, model: String = "", planModel: String? = nil) -> [String: Any] {
            CodexRPC.turnStartParams(threadID: "t1", text: "hoi", cwd: "/w", model: model, mode: mode, permission: permission, planModel: planModel)
        }
        let edits = params(.agent, .acceptEdits)
        XCTAssertEqual(edits["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual((edits["sandboxPolicy"] as? [String: Any])?["type"] as? String, "workspaceWrite")
        XCTAssertEqual(edits["summary"] as? String, "detailed")
        XCTAssertEqual(edits["approvalsReviewer"] as? String, "user")
        XCTAssertNil(edits["model"], "no model: Codex's default")
        XCTAssertEqual(((edits["input"] as? [[String: Any]])?.first)?["text"] as? String, "hoi")

        let ask = params(.agent, .ask)
        XCTAssertEqual(ask["approvalPolicy"] as? String, "untrusted")
        XCTAssertEqual((ask["sandboxPolicy"] as? [String: Any])?["type"] as? String, "readOnly")

        let all = params(.agent, .bypass, model: "gpt-5-codex")
        XCTAssertEqual(all["approvalPolicy"] as? String, "never")
        XCTAssertEqual((all["sandboxPolicy"] as? [String: Any])?["type"] as? String, "dangerFullAccess")
        XCTAssertEqual(all["model"] as? String, "gpt-5-codex")

        let plan = params(.plan, .bypass, planModel: "gpt-5")
        XCTAssertEqual(plan["approvalPolicy"] as? String, "untrusted", "plan mode never writes, whatever the rights")
        XCTAssertEqual(((plan["collaborationMode"] as? [String: Any])?["mode"]) as? String, "plan")
        XCTAssertNil(params(.plan, .bypass)["collaborationMode"], "Codex's plan mode needs a model name")
    }

    func testThreadParamsCarryTheBridge() {
        let bridge: [String: Any] = ["nook": ["command": "/x/nook-mcp", "args": ["--agent", "codex"]]]
        let start = CodexRPC.threadParams(cwd: "/w", model: "", mcpServers: bridge, resumeID: nil)
        XCTAssertNil(start["threadId"])
        XCTAssertNotNil(((start["config"] as? [String: Any])?["mcp_servers"] as? [String: Any])?["nook"])
        let resume = CodexRPC.threadParams(cwd: "/w", model: "gpt-5", mcpServers: nil, resumeID: "th-1")
        XCTAssertEqual(resume["threadId"] as? String, "th-1")
        XCTAssertEqual(resume["excludeTurns"] as? Bool, true)
    }

    func testDecisionsAndAnswers() {
        let command = CodexApprovalRequest(rpcID: .int(5), kind: .command, itemID: "i1", command: "ls", cwd: "/w", reason: "")
        XCTAssertEqual(CodexRPC.decision(command, allow: true, always: false)["decision"] as? String, "accept")
        XCTAssertEqual(CodexRPC.decision(command, allow: true, always: true)["decision"] as? String, "acceptForSession")
        XCTAssertEqual(CodexRPC.decision(command, allow: false, always: false)["decision"] as? String, "decline")
        var legacy = command
        legacy.kind = .legacyCommand
        XCTAssertEqual(CodexRPC.decision(legacy, allow: true, always: false)["decision"] as? String, "approved")
        let answers = CodexRPC.answers(["q1": ["Ja"]])
        XCTAssertEqual(((answers["answers"] as? [String: Any])?["q1"] as? [String: Any])?["answers"] as? [String], ["Ja"])
        let response = object(CodexRPC.response(id: .string("r1"), result: ["decision": "accept"]))
        XCTAssertEqual(response["id"] as? String, "r1")
    }

    func testNotificationsBecomeEvents() {
        func events(_ line: String) -> [CodexStreamEvent] { CodexAppServerMapper.events(CodexRPC.parse(line)!) }
        XCTAssertEqual(events(#"{"method":"item/agentMessage/delta","params":{"itemId":"m1","delta":"Hal","threadId":"t","turnId":"u"}}"#),
                       [.messageDelta(id: "m1", text: "Hal")])
        XCTAssertEqual(events(#"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"r1","delta":"**Plan**","summaryIndex":0}}"#),
                       [.reasoningDelta(id: "r1", text: "**Plan**")])
        XCTAssertEqual(events(#"{"method":"item/completed","params":{"item":{"id":"r1","type":"reasoning","summary":["A","B"]}}}"#),
                       [.reasoningCompleted(id: "r1", text: "A\n\nB")])
        XCTAssertEqual(events(#"{"method":"item/started","params":{"item":{"id":"c1","type":"commandExecution","command":"npm test","status":"inProgress","commandActions":[],"cwd":"/w"}}}"#),
                       [.commandStarted(id: "c1", command: "npm test")])
        XCTAssertEqual(events(#"{"method":"item/commandExecution/outputDelta","params":{"itemId":"c1","delta":"ok\n"}}"#),
                       [.commandOutput(id: "c1", delta: "ok\n")])
        XCTAssertEqual(events(#"{"method":"item/completed","params":{"item":{"id":"c1","type":"commandExecution","command":"npm test","status":"declined","commandActions":[],"cwd":"/w"}}}"#),
                       [.commandFinished(id: "c1", command: "npm test", output: "", exitCode: 1)], "a declined command reads as failed")
        XCTAssertEqual(events(#"{"method":"item/completed","params":{"item":{"id":"f1","type":"fileChange","status":"completed","changes":[{"path":"/w/a.swift","diff":"","kind":{"type":"update"}}]}}}"#),
                       [.fileChanges(id: "f1", changes: [CodexFileChange(path: "/w/a.swift", kind: "update")])])
        XCTAssertEqual(events(#"{"method":"item/completed","params":{"item":{"id":"m1","type":"agentMessage","text":"Klaar."}}}"#),
                       [.messageCompleted(id: "m1", text: "Klaar.")])
        XCTAssertEqual(events(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"interrupted","items":[],"durationMs":4200}}}"#),
                       [.turnFinished(status: "interrupted", error: nil, durationSeconds: 4.2)])
        XCTAssertEqual(events(#"{"method":"error","params":{"error":{"message":"Overloaded"},"willRetry":true,"threadId":"t","turnId":"u"}}"#),
                       [.notice("Overloaded")], "a retried error is a notice, not a failure")
        let usage = events(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"modelContextWindow":272000,"last":{"inputTokens":1200,"cachedInputTokens":200,"outputTokens":80,"reasoningOutputTokens":10,"totalTokens":1280},"total":{"inputTokens":5000,"cachedInputTokens":1000,"outputTokens":300,"reasoningOutputTokens":20,"totalTokens":5300}}}}"#)
        XCTAssertEqual(usage, [.tokenUsage(CodexTokenUsage(last: TokenCounts(input: 1000, output: 80, cacheRead: 200, cacheWrite: 0),
                                                            total: TokenCounts(input: 4000, output: 300, cacheRead: 1000, cacheWrite: 0),
                                                            contextWindow: 272000))])
    }

    func testRequestsBecomeApprovalsAndQuestions() {
        func events(_ line: String) -> [CodexStreamEvent] { CodexAppServerMapper.events(CodexRPC.parse(line)!) }
        XCTAssertEqual(events(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"itemId":"c1","command":"rm -rf build","cwd":"/w","reason":"clean","startedAtMs":1,"threadId":"t","turnId":"u"}}"#),
                       [.approval(CodexApprovalRequest(rpcID: .int(7), kind: .command, itemID: "c1", command: "rm -rf build", cwd: "/w", reason: "clean"))])
        let question = events(#"{"id":8,"method":"item/tool/requestUserInput","params":{"itemId":"q","isBlocking":true,"threadId":"t","turnId":"u","questions":[{"id":"db","header":"Database","question":"Welke database?","options":[{"label":"Postgres","description":"Server"},{"label":"SQLite","description":"Bestand"}]}]}}"#)
        XCTAssertEqual(question, [.question(rpcID: .int(8), questions: [RunQuestion(id: "db", header: "Database", question: "Welke database?",
            options: [RunQuestionOption(label: "Postgres", description: "Server"), RunQuestionOption(label: "SQLite", description: "Bestand")],
            multiSelect: false, allowsOther: false)])])
        XCTAssertEqual(events(#"{"id":9,"method":"attestation/generate","params":{}}"#), [.unsupportedRequest(.int(9))],
                       "an unknown request is answered, so Codex never waits forever")
    }

    func testMcpToolApprovalBecomesAnApproval() {
        func events(_ line: String) -> [CodexStreamEvent] { CodexAppServerMapper.events(CodexRPC.parse(line)!) }
        let tool = events(#"{"id":11,"method":"mcpServer/elicitation/request","params":{"threadId":"t","turnId":"u","serverName":"bestanden-mappen","mode":"form","message":"Allow the bestanden-mappen MCP server to run tool \"move_file\"?","requestedSchema":{"type":"object","properties":{}},"_meta":{"codex_approval_kind":"mcp_tool_call","persist":["session","always"],"tool_title":"move_file","tool_params_display":[{"name":"source","value":"/a.txt"},{"name":"destination","value":"/b.txt"}]}}}"#)
        let expected = CodexApprovalRequest(rpcID: .int(11), kind: .mcpTool, itemID: "11", command: "", cwd: "",
                                            reason: "Allow the bestanden-mappen MCP server to run tool \"move_file\"?",
                                            server: "bestanden-mappen", tool: "move_file",
                                            arguments: ["source": "/a.txt", "destination": "/b.txt"], canRemember: true)
        XCTAssertEqual(tool, [.approval(expected)])
        XCTAssertEqual(CodexRPC.decision(expected, allow: true, always: false)["action"] as? String, "accept")
        XCTAssertNil(CodexRPC.decision(expected, allow: true, always: false)["_meta"])
        XCTAssertEqual((CodexRPC.decision(expected, allow: true, always: true)["_meta"] as? [String: Any])?["persist"] as? String, "session")
        XCTAssertEqual(CodexRPC.decision(expected, allow: false, always: false)["action"] as? String, "decline")

        let confirm = events(#"{"id":12,"method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"deploy","mode":"form","message":"Deploy to production?","requestedSchema":{"type":"object","properties":{}}}}"#)
        XCTAssertEqual(confirm, [.approval(CodexApprovalRequest(rpcID: .int(12), kind: .mcpTool, itemID: "12", command: "", cwd: "",
                                                                reason: "Deploy to production?", server: "deploy"))])
        XCTAssertEqual(events(#"{"id":13,"method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"x","mode":"form","message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}"#),
                       [.unsupportedRequest(.int(13))], "a form with fields to fill in is not a yes or no")
        XCTAssertEqual(events(#"{"id":14,"method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"x","mode":"url","message":"Sign in","url":"https://x","elicitationId":"e"}}"#),
                       [.unsupportedRequest(.int(14))])
        let untitled = events(#"{"id":15,"method":"mcpServer/elicitation/request","params":{"threadId":"t","serverName":"files","mode":"form","message":"Allow the files MCP server to run tool \"read_file\"?","requestedSchema":{"type":"object","properties":{}},"_meta":{"codex_approval_kind":"mcp_tool_call"}}}"#)
        guard case .approval(let request)? = untitled.first else { return XCTFail("expected an approval") }
        XCTAssertEqual(request.tool, "read_file", "without a title the tool comes from Codex's question")
        XCTAssertFalse(request.canRemember)
    }

    func testUnsupportedMeansFallBack() {
        XCTAssertTrue(CodexAppServerError.server("Method not found").meansUnsupported)
        XCTAssertTrue(CodexAppServerError.exited("error: unrecognized subcommand 'app-server'").meansUnsupported)
        XCTAssertFalse(CodexAppServerError.server("Not logged in").meansUnsupported)
    }
}
