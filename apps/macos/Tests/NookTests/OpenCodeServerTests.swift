import XCTest

/// OpenCode 2's server (`OpenCodeServe`, `OpenCodeEvent`): requests Nook builds and events it reads. The fixtures in
/// Tests/Fixtures/OpenCodeServer are event streams recorded from `opencode serve` 2.2.7 (free models, a scratch folder),
/// with paths, names and ids replaced.
final class OpenCodeServerTests: XCTestCase {
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("Tests/Fixtures/OpenCodeServer/\(name)"), encoding: .utf8)
    }

    /// The events of a recorded stream, read the way the stream reads them: in pieces of `chunk` characters.
    private func events(_ name: String, chunk: Int = 97) throws -> [OpenCodeEvent] {
        let text = try fixture(name)
        var parser = SSEParser()
        var frames: [SSEFrame] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
            frames += parser.feed(String(text[index..<end]))
            index = end
        }
        return frames.compactMap { OpenCodeEvent.decode($0.data) }
    }

    // MARK: Server

    func testTheServerAddressComesFromItsFirstLine() {
        XCTAssertEqual(OpenCodeServe.listeningURL(inLine: "Server listening on http://127.0.0.1:60163"),
                       URL(string: "http://127.0.0.1:60163"))
        XCTAssertNil(OpenCodeServe.listeningURL(inLine: "Server listening on http://0.0.0.0:4096"), "only loopback")
        XCTAssertNil(OpenCodeServe.listeningURL(inLine: "Server listening on http://127.0.0.1:0"))
        XCTAssertEqual(OpenCodeServe.arguments, ["serve", "--hostname", "127.0.0.1", "--port", "0"])
    }

    func testOnlyOpenCodeTwoUsesTheServer() {
        XCTAssertTrue(OpenCodeServe.supports(version: "2.2.7"))
        XCTAssertTrue(OpenCodeServe.supports(version: "2.0.18"))
        XCTAssertTrue(OpenCodeServe.supports(version: "opencode v2.3.0"))
        XCTAssertFalse(OpenCodeServe.supports(version: "2.0.17"))
        XCTAssertFalse(OpenCodeServe.supports(version: "1.14.19"))
        XCTAssertFalse(OpenCodeServe.supports(version: nil))
    }

    func testThePasswordIsRandomAndGoesAsBasicAuth() {
        let first = OpenCodeServe.makePassword()
        XCTAssertNotEqual(first, OpenCodeServe.makePassword())
        XCTAssertGreaterThanOrEqual(first.count, 40)
        XCTAssertFalse(first.contains("+") || first.contains("/") || first.contains("="))
        XCTAssertEqual(OpenCodeServe.authorization(password: "pw"), "Basic " + Data("opencode:pw".utf8).base64EncodedString())
        XCTAssertEqual(OpenCodeServe.removedEnvironment, ["OPENCODE_SERVER_PASSWORD"])
    }

    // MARK: Recorded streams

    func testAShellCommandAskedAndAllowed() throws {
        let events = try events("shell_permission_allowed.sse")
        XCTAssertEqual(events.first, .connected)
        let session = "ses_fixture0400000000000000000"
        XCTAssertTrue(events.contains(.executionStarted(session: session)))
        let permission = try XCTUnwrap(events.compactMap { if case .permission(let p) = $0 { return p } else { return nil } }.first)
        XCTAssertEqual(permission.sessionID, session)
        XCTAssertEqual(permission.action, "shell")
        XCTAssertEqual(permission.resources, ["ls"])
        XCTAssertEqual(permission.save, ["ls *"])
        XCTAssertEqual(permission.callID, "call_9badc53833e34908a6971726")
        XCTAssertTrue(events.contains(.toolStarted(session: session, call: "call_9badc53833e34908a6971726", name: "shell")))
        XCTAssertTrue(events.contains(.toolCalled(session: session, call: "call_9badc53833e34908a6971726", input: JSONBox(["command": "ls"]))))
        XCTAssertTrue(events.contains(.permissionSettled(session: session, request: permission.id)))
        let output = events.compactMap { event -> String? in
            if case .toolSucceeded(_, "call_9badc53833e34908a6971726", let output, _) = event { return output }
            return nil
        }
        XCTAssertEqual(output, ["readme.txt\n"])
        let steps = events.compactMap { event -> OpenCodeTokens? in
            if case .stepEnded(_, let tokens, _) = event { return tokens }
            return nil
        }
        XCTAssertEqual(steps.first, OpenCodeTokens(input: 15160, output: 38, reasoning: 81, cacheRead: 1664, cacheWrite: 0))
        XCTAssertEqual(steps.count, 2)
        // The answer streamed in deltas, then whole; the thinking too, as its own item.
        let answer = events.compactMap { event -> String? in
            if case .textDone(_, _, false, let text) = event { return text }
            return nil
        }
        XCTAssertEqual(answer.count, 1)
        XCTAssertTrue(answer[0].contains("readme.txt"))
        XCTAssertTrue(events.contains { if case .textDelta(_, _, true, _) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains(.executionEnded(session: session, .succeeded)))
        // What Nook does not read stays an event of its type, so the stream goes on.
        XCTAssertTrue(events.contains(.other(type: "session.inbox.delivered", session: session)))
        XCTAssertTrue(events.contains(.other(type: "project.updated", session: nil)))
    }

    func testAQuestionThenADenialWithAReason() throws {
        let events = try events("question_then_denied_with_reason.sse", chunk: 13)
        let session = "ses_fixture0300000000000000000"
        let form = try XCTUnwrap(events.compactMap { if case .form(let f) = $0 { return f } else { return nil } }.first)
        XCTAssertEqual(form.sessionID, session)
        XCTAssertNil(form.unsupported)
        XCTAssertEqual(form.callID, "chatcmpl-tool-b7570e70ad160e4c")
        XCTAssertEqual(form.questions, [RunQuestion(id: "q0", header: "Color preference", question: "Which color do you prefer?",
                                                    options: [RunQuestionOption(label: "Red", description: "Choose red"),
                                                              RunQuestionOption(label: "Blue", description: "Choose blue")],
                                                    multiSelect: false, allowsOther: true)])
        XCTAssertEqual(JSONBox(OpenCodeServe.formAnswer(form, answers: ["q0": ["Blue"]])), JSONBox(["answer": ["q0": "Blue"]]))
        XCTAssertTrue(events.contains(.formSettled(session: session, form: form.id)))
        // The question tool reports its own start; Nook shows the form instead of a step.
        XCTAssertTrue(events.contains(.toolStarted(session: session, call: "chatcmpl-tool-b7570e70ad160e4c", name: "question")))
        // Denied with a reason: the call fails with it, and the turn goes on to an answer.
        XCTAssertTrue(events.contains(.toolFailed(session: session, call: "chatcmpl-tool-8b78e3782d253c79", kind: "permission.rejected",
                                                  message: "Do not run shell commands; just tell me the color.")))
        let answer = events.compactMap { event -> String? in
            if case .textDone(_, _, false, let text) = event { return text }
            return nil
        }
        XCTAssertEqual(answer.last?.contains("blue"), true)
        XCTAssertTrue(events.contains(.executionEnded(session: session, .succeeded)))
    }

    func testEditsThenStop() throws {
        let events = try events("edits_then_interrupt.sse", chunk: 251)
        let session = "ses_fixture0100000000000000000"
        let edit = try XCTUnwrap(events.compactMap { event -> JSONBox? in
            if case .toolCalled(_, "chatcmpl-tool-a7365d4d324ecc4f", let input) = event { return input }
            return nil
        }.first)
        let mapped = OpenCodeTools.input(tool: "edit", edit.dictionary, directory: "/Users/me/project")
        XCTAssertEqual(mapped["file_path"] as? String, "/Users/me/project/notes.txt")
        XCTAssertEqual(mapped["old_string"] as? String, "alpha")
        XCTAssertEqual(mapped["new_string"] as? String, "beta")
        XCTAssertEqual(ToolSummary.describe(tool: "edit", input: mapped), "edit · notes.txt")
        let metadata = try XCTUnwrap(events.compactMap { event -> JSONBox? in
            if case .toolSucceeded(_, "chatcmpl-tool-a7365d4d324ecc4f", _, let metadata) = event { return metadata }
            return nil
        }.first)
        XCTAssertEqual(OpenCodeTools.changedPaths(tool: "edit", input: edit.dictionary, metadata: metadata.dictionary,
                                                  directory: "/Users/me/project"), ["/Users/me/project/notes.txt"])
        XCTAssertEqual(OpenCodeTools.name("edit"), "Edit")
        XCTAssertEqual(OpenCodeTools.name("write"), "Write")
        // Every agent's command reads "Shell" (`CanonicalTool`).
        XCTAssertEqual(OpenCodeTools.name("shell"), "Shell")
        // Stop: the running command ends as aborted, and the execution as interrupted.
        XCTAssertTrue(events.contains(.toolFailed(session: session, call: "chatcmpl-tool-8caacf7af79bb0a3", kind: "aborted",
                                                  message: "Tool execution interrupted")))
        XCTAssertTrue(events.contains(.executionEnded(session: session, .interrupted(reason: "user"))))
        XCTAssertEqual(OpenCodeServe.interrupted(["interrupted": true]), true)
        XCTAssertEqual(OpenCodeServe.interrupted(["interrupted": false]), false)
    }

    func testAFailedExecutionSaysWhy() throws {
        let events = try events("execution_failed.sse")
        XCTAssertTrue(events.contains(.executionEnded(session: "ses_fixture0200000000000000000",
                                                      .failed(kind: "provider.no-route", message: "Model unavailable: opencode/no-such-model"))))
    }

    func testABrokenFrameIsNoEvent() {
        XCTAssertNil(OpenCodeEvent.decode("not json"))
        XCTAssertNil(OpenCodeEvent.decode(#"{"data":{}}"#))
        XCTAssertEqual(OpenCodeEvent.decode(#"{"type":"session.brand.new","data":{"sessionID":"s"}}"#), .other(type: "session.brand.new", session: "s"))
        XCTAssertEqual(OpenCodeEvent.decode(#"{"type":"permission.asked","data":{"sessionID":"s"}}"#), .other(type: "permission.asked", session: "s"))
    }

    // MARK: Requests

    func testRightsBecomeRulesWithTheLastMatchWinning() {
        let ask = OpenCodeServe.rules(permission: .ask, mode: .agent, grants: [], bridgeServer: nil)
        XCTAssertEqual(ask.map(\.effect), ["ask", "ask", "ask"])
        XCTAssertEqual(ask.map(\.action), ["shell", "edit", "external_directory"])
        let edits = OpenCodeServe.rules(permission: .acceptEdits, mode: .agent, grants: [], bridgeServer: nil)
        XCTAssertEqual(edits.first { $0.action == "edit" }?.effect, "allow")
        XCTAssertEqual(edits.first { $0.action == "shell" }?.effect, "ask")
        XCTAssertEqual(OpenCodeServe.rules(permission: .bypass, mode: .agent, grants: [], bridgeServer: nil),
                       [OpenCodeServe.Rule(action: "*", resource: "*", effect: "allow")])
        // Plan mode bans edits after everything else allowed; the bridge comes last, only this session's own.
        let grant = OpenCodeServe.grants(action: "shell", save: ["ls *"])
        XCTAssertEqual(grant, [OpenCodeServe.Rule(action: "shell", resource: "ls *", effect: "allow")])
        let plan = OpenCodeServe.rules(permission: .bypass, mode: .plan, grants: grant, bridgeServer: "nook-abc")
        XCTAssertEqual(plan.map(\.json), [
            ["action": "*", "resource": "*", "effect": "allow"],
            ["action": "shell", "resource": "ls *", "effect": "allow"],
            ["action": "edit", "resource": "*", "effect": "deny"],
            ["action": "nook-*", "resource": "*", "effect": "deny"],
            ["action": "nook-abc_*", "resource": "*", "effect": "allow"],
        ])
        XCTAssertEqual(OpenCodeServe.grants(action: "edit", save: []), [OpenCodeServe.Rule(action: "edit", resource: "*", effect: "allow")])
        XCTAssertEqual(OpenCodeServe.agent(for: .plan), "plan")
        XCTAssertEqual(OpenCodeServe.agent(for: .agent), "build")
        let server = OpenCodeServe.bridgeServer(runID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
        XCTAssertEqual(server, "nook-6f9619ff8b86d011")
        XCTAssertLessThanOrEqual(server.count, 64)
    }

    func testADenialAlwaysCarriesWords() {
        XCTAssertEqual(JSONBox(OpenCodeServe.permissionReply(allow: true, reason: "ignored")), JSONBox(["decision": "once"]))
        XCTAssertEqual(JSONBox(OpenCodeServe.permissionReply(allow: false, reason: " use rg instead ")),
                       JSONBox(["decision": "reject", "message": "use rg instead"]))
        // Without a message OpenCode would end the whole execution.
        XCTAssertEqual(JSONBox(OpenCodeServe.permissionReply(allow: false, reason: "")),
                       JSONBox(["decision": "reject", "message": OpenCodeServe.declined]))
    }

    func testModelsAndTheirVariants() throws {
        let response = try JSONSerialization.jsonObject(with: Data(try fixture("models.json").utf8))
        let models = OpenCodeServe.models(response)
        XCTAssertEqual(models.count, 12)
        let flash = try XCTUnwrap(models.first { $0.id == "opencode/deepseek-v4.1-flash-free" })
        XCTAssertEqual(flash.name, "opencode/DeepSeek V4.1 Flash Free")
        XCTAssertEqual(flash.variants, ["low", "high", "max"])
        XCTAssertEqual(flash.contextWindow, 200_000)
        XCTAssertEqual(models.first { $0.id == "opencode/big-pickle" }?.variants, [])
        // `GET /api/model/default` answers one model, not a list.
        XCTAssertEqual(OpenCodeServe.models(["data": ["id": "big-pickle", "providerID": "opencode", "name": "Big Pickle"]]).map(\.id),
                       ["opencode/big-pickle"])

        XCTAssertEqual(JSONBox(OpenCodeServe.modelRef("opencode/deepseek-v4.1-flash-free", effort: "high") ?? [:]),
                       JSONBox(["providerID": "opencode", "id": "deepseek-v4.1-flash-free", "variant": "high"]))
        XCTAssertEqual(JSONBox(OpenCodeServe.modelRef("anthropic/claude-sonnet-5/thinking", effort: nil) ?? [:]),
                       JSONBox(["providerID": "anthropic", "id": "claude-sonnet-5/thinking"]))
        XCTAssertNil(OpenCodeServe.modelRef("", effort: "high"))
        XCTAssertNil(OpenCodeServe.modelRef("no-provider", effort: nil))
        let read = OpenCodeServe.model(["providerID": "opencode", "id": "big-pickle", "variant": "default"])
        XCTAssertEqual(read?.id, "opencode/big-pickle")
        XCTAssertNil(read?.variant)
    }

    func testSessionsAndCommands() {
        let info = OpenCodeServe.session(["data": ["id": "ses_1", "parentID": "ses_0", "location": ["directory": "/p"],
                                                   "model": ["providerID": "opencode", "id": "m", "variant": "high"],
                                                   "time": ["busy": 10, "idle": 12], "outcome": "interrupted"]])
        XCTAssertEqual(info, OpenCodeSessionInfo(id: "ses_1", parentID: "ses_0", directory: "/p", model: "opencode/m", variant: "high",
                                                 busy: false, outcome: "interrupted"))
        XCTAssertEqual(OpenCodeServe.session(["data": ["id": "ses_2", "time": ["busy": 20, "idle": 12]]])?.busy, true)
        XCTAssertNil(OpenCodeServe.session(["_tag": "SessionNotFoundError", "message": "gone"]))
        XCTAssertEqual(OpenCodeServe.errorMessage(["_tag": "SessionNotFoundError", "message": "gone"]), "gone")

        let commands = OpenCodeServe.commands(["data": [["name": "review", "description": "review changes"], ["name": "goal"],
                                                        ["name": "two words"], ["name": "review"]]])
        XCTAssertEqual(commands.map(\.name), ["review", "goal"])
        XCTAssertEqual(OpenCodeServe.command(in: "/compact", known: [])?.name, "compact")
        XCTAssertEqual(OpenCodeServe.command(in: " /goal ship the release ", known: commands)?.text, "ship the release")
        XCTAssertNil(OpenCodeServe.command(in: "/unknown do it", known: commands))
        XCTAssertNil(OpenCodeServe.command(in: "please /goal", known: commands))
    }

    func testPromptsAndNewSessions() {
        XCTAssertEqual(JSONBox(OpenCodeServe.promptBody(text: "look", files: ["/tmp/a b.png"])),
                       JSONBox(["text": "look", "files": [["uri": "file:///tmp/a%20b.png", "name": "a b.png"]]]))
        XCTAssertEqual(JSONBox(OpenCodeServe.promptBody(text: "hi", files: [])), JSONBox(["text": "hi"]))
        let body = OpenCodeServe.newSessionBody(directory: "/p", model: nil, agent: "build",
                                                rules: [OpenCodeServe.Rule(action: "*", resource: "*", effect: "allow")])
        XCTAssertEqual(JSONBox(body), JSONBox(["location": ["directory": "/p"], "agent": "build",
                                               "permissions": [["action": "*", "resource": "*", "effect": "allow"]]]))
        XCTAssertEqual(OpenCodeServe.locationQuery("/a+b"), [URLQueryItem(name: "location[directory]", value: "/a+b")])
    }

    func testFormsNookCannotShowAreMarked() {
        let external = OpenCodeForm(["id": "frm_1", "sessionID": "s", "fields": [["key": "k", "type": "external", "url": "https://x"]]])
        XCTAssertNotNil(external?.unsupported)
        let empty = OpenCodeForm(["id": "frm_2", "sessionID": "s", "fields": [[String: Any]]()])
        XCTAssertNotNil(empty?.unsupported)
        let multi = OpenCodeForm(["id": "frm_3", "sessionID": "s",
                                  "fields": [["key": "pick", "type": "multiselect", "title": "Which",
                                              "options": [["value": "a", "label": "Apple"], ["value": "b", "label": "Banana"]]]]])
        XCTAssertNil(multi?.unsupported)
        XCTAssertEqual(multi?.questions.first?.multiSelect, true)
        XCTAssertEqual(multi?.questions.first?.allowsOther, false)
        if let multi {
            XCTAssertEqual(JSONBox(OpenCodeServe.formAnswer(multi, answers: ["pick": ["Apple", "Banana"]])),
                           JSONBox(["answer": ["pick": ["a", "b"]]]))
        }
    }
}
