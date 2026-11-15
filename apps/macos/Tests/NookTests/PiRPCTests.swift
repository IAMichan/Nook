import XCTest

/// Pi's RPC mode (`PiRPC`, `PiStreamParser`, `AgentCommand.piSpec`): the lines Nook writes, the events it reads from a
/// recorded transcript, and the command that starts a turn.
final class PiRPCTests: XCTestCase {
    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Encoding

    func testCommandsAreOneLineEachEndingInLF() {
        for line in [PiRPC.getState(), PiRPC.prompt("hi"), PiRPC.abort(), PiRPC.compact(), PiRPC.confirmResponse(requestID: "a", confirmed: true)] {
            XCTAssertTrue(line.hasSuffix("\n"))
            XCTAssertEqual(line.count(where: { $0 == "\n" }), 1)
        }
        // Newlines and U+2028 inside the text stay escaped or literal inside one line, never a second frame.
        let line = PiRPC.prompt("one\ntwo\u{2028}three")
        XCTAssertEqual(line.count(where: { $0 == "\n" }), 1)
        XCTAssertEqual(object(line)["message"] as? String, "one\ntwo\u{2028}three")
    }

    func testPromptSteersOnlyWhenAsked() {
        XCTAssertEqual(object(PiRPC.prompt("go", steer: true))["streamingBehavior"] as? String, "steer")
        XCTAssertNil(object(PiRPC.prompt("go", steer: false))["streamingBehavior"])
    }

    func testCompactIsACommandNotAPrompt() {
        var input = PiRPC.turnInput(for: "/compact")
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(object(input[0])["type"] as? String, "get_state")
        XCTAssertEqual(object(input[1])["type"] as? String, "compact")
        input = PiRPC.turnInput(for: "/compact keep the tests")
        XCTAssertEqual(object(input[1])["customInstructions"] as? String, "keep the tests")
        input = PiRPC.turnInput(for: "fix the bug")
        XCTAssertEqual(object(input[1])["type"] as? String, "prompt")
        XCTAssertEqual(object(input[1])["message"] as? String, "fix the bug")
    }

    func testModelSlug() {
        XCTAssertEqual(PiRPC.splitModel("anthropic/claude-sonnet")?.provider, "anthropic")
        XCTAssertEqual(PiRPC.splitModel("openrouter/meta/llama")?.modelID, "meta/llama")
        XCTAssertNil(PiRPC.splitModel("sonnet"))
        XCTAssertNil(PiRPC.splitModel("/x"))
        XCTAssertNil(PiRPC.splitModel("x/"))
    }

    // MARK: Decoding a recorded turn

    private let transcript = [
        #"{"type":"response","id":"nook-state","command":"get_state","success":true,"data":{"sessionFile":"/Users/me/.pi/agent/sessions/a.jsonl","model":{"provider":"anthropic","id":"claude-sonnet","contextWindow":200000}}}"#,
        #"{"type":"response","command":"prompt","success":true}"#,
        #"{"type":"agent_start"}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"hm"}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"Hel"}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"Hello"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{"command":"ls"}}"#,
        #"{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash","result":{"content":[{"type":"text","text":"a\nb"}]},"isError":false}"#,
        #"{"type":"message_end","message":{"role":"assistant","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":1,"totalTokens":18,"cost":{"total":0.25}}}}"#,
        #"{"type":"agent_settled","aborted":false}"#,
    ]

    func testTranscriptBecomesEvents() {
        let events = transcript.flatMap(PiStreamParser.parse)
        XCTAssertEqual(events, [
            .session(file: "/Users/me/.pi/agent/sessions/a.jsonl", model: "anthropic/claude-sonnet", contextWindow: 200000),
            .started,
            .thinkingDelta("hm"),
            .textDelta("Hel"),
            .text("Hello"),
            .toolStarted(id: "t1", name: "bash", input: JSONBox(["command": "ls"])),
            .toolFinished(id: "t1", name: "bash", output: "a\nb", isError: false),
            .usage(PiUsage(input: 10, output: 5, cacheRead: 2, cacheWrite: 1, total: 18, costUSD: 0.25)),
            .settled(aborted: false),
        ])
    }

    func testModelErrorFailsTheTurn() {
        let events = PiStreamParser.parse(#"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"overloaded"}}"#)
        XCTAssertEqual(events, [.failed("overloaded")])
    }

    func testRejectedPromptEndsTheTurn() {
        let events = PiStreamParser.parse(#"{"type":"response","command":"prompt","success":false,"error":"No model selected"}"#)
        XCTAssertEqual(events, [.failed("No model selected"), .settled(aborted: false)])
    }

    func testCompactWithoutARunReportsItsEnd() {
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"response","command":"compact","success":true}"#),
                       [.commandDone(command: "compact", error: nil)])
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"response","command":"compact","success":false,"error":"nothing to compact"}"#),
                       [.commandDone(command: "compact", error: "nothing to compact")])
    }

    func testDialogs() {
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"Allow bash?","message":"{}"}"#),
                       [.confirm(requestID: "u1", title: "Allow bash?", message: "{}")])
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"extension_ui_request","id":"u2","method":"select","title":"Pick","options":["a",""]}"#),
                       [.dialog(requestID: "u2", question: RunQuestion(id: "value", header: "", question: "Pick",
                                                                       options: [RunQuestionOption(label: "a", description: "")],
                                                                       multiSelect: false, allowsOther: false))])
        // An input or editor dialog takes your own text; a message under the title becomes the question.
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"extension_ui_request","id":"u3","method":"input","title":"Name","placeholder":"Your branch"}"#),
                       [.dialog(requestID: "u3", question: RunQuestion(id: "value", header: "Name", question: "Your branch",
                                                                       options: [], multiSelect: false, allowsOther: true))])
        XCTAssertEqual(PiRPC.dialogResponse(requestID: "u3", value: "main"),
                       #"{"id":"u3","type":"extension_ui_response","value":"main"}"# + "\n")
        XCTAssertEqual(PiRPC.dialogResponse(requestID: "u3", value: nil),
                       #"{"cancelled":true,"id":"u3","type":"extension_ui_response"}"# + "\n")
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"extension_ui_request","method":"notify","message":"hello"}"#), [.notice("hello")])
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"extension_ui_request","method":"setStatus","statusKey":"k"}"#), [])
    }

    func testGarbageAndUnknownEventsAreIgnored() {
        XCTAssertEqual(PiStreamParser.parse("not json"), [])
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"queue_update"}"#), [])
        XCTAssertEqual(PiStreamParser.parse(#"{"type":"agent_end"}"#), [.ended])
    }

    func testModelsReply() {
        let line = #"{"type":"response","id":"nook-models","command":"get_available_models","success":true,"data":{"models":[{"provider":"anthropic","id":"claude","name":"Claude","contextWindow":200000,"reasoning":true},{"provider":"anthropic","id":"claude"},{"provider":"","id":"x"},{"provider":"openai","id":"gpt"}]}}"#
        let models = PiModel.reply(in: line)
        XCTAssertEqual(models?.map(\.slug), ["anthropic/claude", "openai/gpt"])
        XCTAssertEqual(models?.first?.contextWindow, 200000)
        XCTAssertEqual(models?.first?.supportsThinking, true)
        XCTAssertNil(PiModel.reply(in: #"{"type":"response","id":"other","command":"get_state","success":true}"#))
    }

    // MARK: Launch

    private func input(model: String = "", permission: PermissionPolicy = .ask, resume: String? = nil, effort: String? = nil) -> AgentCommand.Input {
        AgentCommand.Input(provider: .pi, executable: "/usr/local/bin/pi", prompt: "do it", model: model, mode: .agent,
                           permission: permission, instructions: "", workingDirectory: "/work", resumeSessionID: resume,
                           accountEnvironment: ["PI_CODING_AGENT_DIR": "/acct"], runID: UUID(), effort: effort)
    }

    func testLaunchResumesTheSessionFileAndPicksTheModel() {
        let spec = AgentCommand.spec(input(model: "anthropic/claude-sonnet", resume: "/s/a.jsonl", effort: "high"))
        XCTAssertEqual(Array(spec.arguments.prefix(2)), ["--mode", "rpc"])
        XCTAssertTrue(spec.arguments.contains("--session") && spec.arguments.contains("/s/a.jsonl"))
        XCTAssertTrue(spec.arguments.contains("--provider") && spec.arguments.contains("anthropic"))
        XCTAssertTrue(spec.arguments.contains("--model") && spec.arguments.contains("claude-sonnet"))
        XCTAssertTrue(spec.arguments.contains("--thinking") && spec.arguments.contains("high"))
        XCTAssertTrue(spec.arguments.contains("--extension"))
        XCTAssertTrue(spec.keepsInputOpen)
        XCTAssertEqual(spec.extraEnvironment["PI_CODING_AGENT_DIR"], "/acct")
        XCTAssertEqual(spec.initialInput.count, 2)
    }

    func testPermissionReachesTheExtension() {
        XCTAssertEqual(AgentCommand.spec(input(permission: .ask)).extraEnvironment[PiExtension.permissionVariable], "ask")
        XCTAssertEqual(AgentCommand.spec(input(permission: .acceptEdits)).extraEnvironment[PiExtension.permissionVariable], "acceptEdits")
        XCTAssertEqual(AgentCommand.spec(input(permission: .bypass)).extraEnvironment[PiExtension.permissionVariable], "bypass")
        XCTAssertFalse(RunProvider.pi.capabilities.policies.contains(.auto), "Pi has no reviewer")
    }

    func testExtensionIsInstalledOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-ext-\(UUID().uuidString)/ext.ts")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(PiExtension.install(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), PiExtension.source)
        XCTAssertTrue(PiExtension.source.contains("tool_call"))
        XCTAssertTrue(PiExtension.source.contains(PiExtension.permissionVariable))
    }
}
