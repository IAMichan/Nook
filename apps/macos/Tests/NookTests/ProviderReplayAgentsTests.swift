import XCTest

/// Recorded Codex app-server, ACP (Kiro) and Pi sessions replayed through Nook's real clients (`CodexAppServerClient`,
/// `AcpClient`, `AgentProcess`) and mappers, with only the agent's process replaced (`ReplayTransport`). Each test drives
/// the client the way the workspace does (the same requests, built by the same functions, in the same order) and checks
/// what the session's timeline gets. The fixtures are hand-written: only the frames these clients read, in each agent's
/// protocol.
final class ProviderReplayAgentsTests: XCTestCase {
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private static let workspace = "<workspace>"

    private func transport(_ name: String) throws -> ReplayTransport {
        let url = Self.root.appendingPathComponent("Tests/Fixtures/ProviderReplay/\(name).ndjson")
        return ReplayTransport(try ProviderTranscript.parse(String(contentsOf: url, encoding: .utf8)))
    }

    private func spec(_ executable: String, _ arguments: [String] = []) -> LaunchSpec {
        LaunchSpec(executable: executable, arguments: arguments, extraEnvironment: [:], workingDirectory: "/tmp",
                   initialInput: [], keepsInputOpen: true)
    }

    /// Blocks until a request's answer is in (answers arrive on the client's queue, not on this thread).
    private func call(_ send: (@escaping (Result<JSONBox, CodexAppServerError>) -> Void) -> Void,
                      file: StaticString = #filePath, line: UInt = #line) throws -> JSONBox {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        send { result in
            box.set(result)
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success, let result = box.result else {
            XCTFail("no answer", file: file, line: line)
            throw CodexAppServerError.server("no answer")
        }
        return try result.get()
    }

    private func finish(_ transport: ReplayTransport, stop: () -> Void, exited: XCTestExpectation) {
        stop()
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(transport.mismatches, [], "Nook wrote what the agent expected")
        XCTAssertTrue(transport.isFinished, "the whole transcript was played")
    }

    // MARK: Codex app-server

    /// A Codex app-server session as the workspace opens it: `initialize`, `initialized`, `thread/start`.
    private func codex(_ name: String, model: String = "gpt-6-luna", react: @escaping @Sendable (CodexStreamEvent, CodexAppServerClient) -> Void = { _, _ in })
        throws -> (CodexAppServerClient, ReplayTransport, Collected<CodexStreamEvent>, XCTestExpectation, String) {
        let transport = try transport(name)
        let client = CodexAppServerClient(spec: spec("/usr/local/bin/codex", ["app-server"]), transport: transport,
                                          scheduler: ImmediateProcessScheduler())
        let events = Collected<CodexStreamEvent>()
        client.onMessage = { [unowned client] _, mapped in
            for event in mapped {
                events.add(event)
                react(event, client)
            }
        }
        let exited = expectation(description: "codex exited")
        client.onExit = { _, _ in exited.fulfill() }
        try client.start()
        _ = try call { client.request("initialize", CodexRPC.initializeParams(), completion: $0) }
        client.notify("initialized")
        let thread = try call {
            client.request("thread/start", CodexRPC.threadParams(cwd: Self.workspace, model: model, mcpServers: nil, resumeID: nil),
                           completion: $0)
        }
        let threadID = try XCTUnwrap((thread.dictionary["thread"] as? [String: Any])?["id"] as? String)
        client.threadID = threadID
        return (client, transport, events, exited, threadID)
    }

    private func startTurn(_ client: CodexAppServerClient, thread: String, text: String, model: String = "gpt-6-luna",
                           permission: PermissionPolicy = .bypass) throws -> String {
        let params = CodexRPC.turnStartParams(threadID: thread, text: text, cwd: Self.workspace, model: model, mode: .agent,
                                              permission: permission, planModel: nil)
        let response = try call { client.request("turn/start", params, completion: $0) }
        let turn = try XCTUnwrap((response.dictionary["turn"] as? [String: Any])?["id"] as? String)
        client.turnID = turn
        return turn
    }

    private func finished(_ events: Collected<CodexStreamEvent>) -> [String] {
        events.all.compactMap { if case .turnFinished(let status, _, _) = $0 { return status } else { return nil } }
    }

    private func messages(_ events: Collected<CodexStreamEvent>) -> [String] {
        events.all.compactMap { if case .messageCompleted(_, let text) = $0 { return text } else { return nil } }
    }

    func testCodexSimpleTurn() throws {
        let (client, transport, events, exited, thread) = try codex("codex_simple")
        _ = try startTurn(client, thread: thread, text: "Reply with just the words: lanterns are lit")
        events.wait { self.finished(events).count == 1 }
        XCTAssertEqual(messages(events), ["lanterns are lit"])
        XCTAssertEqual(finished(events), ["completed"])
        let deltas = events.all.compactMap { if case .messageDelta(_, let text) = $0 { return text } else { return nil } }
        XCTAssertEqual(deltas.joined(), "lanterns are lit", "the answer streamed before it completed")
        XCTAssertTrue(events.all.contains(.threadStarted(thread)))
        let usage = events.all.compactMap { if case .tokenUsage(let usage) = $0 { return usage } else { return nil } }.last
        XCTAssertEqual(usage?.contextWindow, 272_000)
        XCTAssertEqual(usage?.last.output, 9)
        XCTAssertEqual(usage?.last.cacheRead, 4_608, "cached input is kept apart from the input")
        XCTAssertEqual(usage?.last.input, 10_752)
        finish(transport, stop: client.stop, exited: exited)
    }

    func testCodexMultiTurn() throws {
        let (client, transport, events, exited, thread) = try codex("codex_multi_turn")
        _ = try startTurn(client, thread: thread, text: "Say only: the kettle is on")
        events.wait { self.finished(events).count == 1 }
        _ = try startTurn(client, thread: thread, text: "Say only: the tea is ready")
        events.wait { self.finished(events).count == 2 }
        XCTAssertEqual(messages(events), ["the kettle is on", "the tea is ready"])
        XCTAssertEqual(finished(events), ["completed", "completed"])
        finish(transport, stop: client.stop, exited: exited)
    }

    func testCodexTurnInterrupt() throws {
        let (client, transport, events, exited, thread) = try codex("codex_turn_interrupt")
        let turn = try startTurn(client, thread: thread,
                                 text: "Run `sleep 45` in the shell and wait for it, then say: the long wait is over")
        _ = try call { client.request("turn/interrupt", CodexRPC.interruptParams(threadID: thread, turnID: turn), completion: $0) }
        events.wait { self.finished(events).count == 1 }
        XCTAssertEqual(finished(events), ["interrupted"], "the workspace marks such a turn stopped")
        XCTAssertEqual(messages(events), [])
        finish(transport, stop: client.stop, exited: exited)
    }

    func testCodexMessageSteering() throws {
        let (client, transport, events, exited, thread) = try codex("codex_message_steering")
        let turn = try startTurn(client, thread: thread, text: "Say only: plan A stands")
        let steer = "Change of plan, say only: plan B it is"
        let steered = try call { client.request("turn/steer", CodexRPC.steerParams(threadID: thread, turnID: turn, text: steer), completion: $0) }
        XCTAssertEqual(steered.dictionary["turnId"] as? String, turn, "the steer went into the running turn")
        events.wait { self.finished(events).count == 1 }
        let mine = events.all.compactMap { if case .userMessage(let text, _) = $0 { return text } else { return nil } }
        // Codex echoes each message it takes in: the prompt, then the steer, in the same turn.
        XCTAssertEqual(mine, ["Say only: plan A stands", steer])
        XCTAssertEqual(messages(events), ["plan A stands", "plan B it is"])
        XCTAssertEqual(finished(events), ["completed"], "one turn, steered")
        finish(transport, stop: client.stop, exited: exited)
    }

    func testCodexToolApproval() throws {
        let asked = Collected<CodexApprovalRequest>()
        let (client, transport, events, exited, thread) = try codex("codex_tool_approval", model: "gpt-6-sol") { event, client in
            guard case .approval(let request) = event else { return }
            asked.add(request)
            client.respond(request.rpcID, CodexRPC.decision(request, allow: true, always: false))
        }
        _ = try startTurn(client, thread: thread,
                          text: "Put the text `hello from the replay` in greeting.txt at the project root, then tell me in one line what changed.",
                          model: "gpt-6-sol", permission: .acceptEdits)
        events.wait { self.finished(events).count == 1 }
        let request = try XCTUnwrap(asked.all.first)
        XCTAssertEqual(asked.all.count, 1)
        XCTAssertEqual(request.kind, .command)
        XCTAssertTrue(request.command.contains("greeting.txt"))
        XCTAssertFalse(request.reason.isEmpty, "the approval card says why")
        let commands = events.all.compactMap { event -> (String, Int?)? in
            if case .commandFinished(let id, _, _, let exit) = event { return (id, exit) } else { return nil }
        }
        XCTAssertEqual(commands.map(\.0), [request.itemID], "the approved command ran, as the row the request named")
        XCTAssertEqual(commands.first?.1, 0)
        XCTAssertEqual(finished(events), ["completed"])
        XCTAssertEqual(messages(events).count, 2, "a word before the command and the report after it")
        finish(transport, stop: client.stop, exited: exited)
    }

    // MARK: ACP (Kiro)

    /// An ACP session as the workspace opens it: `initialize`, `session/new`, then the settings the run asks for.
    private func kiro(_ name: String, react: @escaping @Sendable (AcpEvent, AcpClient) -> Void = { _, _ in })
        throws -> (AcpClient, ReplayTransport, Collected<AcpEvent>, XCTestExpectation, String) {
        let transport = try transport(name)
        let client = AcpClient(spec: spec("/usr/local/bin/kiro-cli", ["acp"]), transport: transport, scheduler: ImmediateProcessScheduler())
        let events = Collected<AcpEvent>()
        client.onMessage = { [unowned client] _, mapped in
            for event in mapped {
                events.add(event)
                react(event, client)
            }
        }
        let exited = expectation(description: "kiro exited")
        client.onExit = { _, _ in exited.fulfill() }
        try client.start()
        let initialize = try call { client.request("initialize", AcpRPC.initializeParams(), completion: $0) }.dictionary
        // Kiro reports protocol version 2 in the v1 shape: Nook reads it as v1, with all its capabilities.
        XCTAssertEqual(initialize["protocolVersion"] as? Int, 2)
        XCTAssertEqual(AcpRPC.generation(initialize), 1)
        client.sessionCapabilities = AcpSessionCapabilities(initialize: initialize)
        XCTAssertEqual(client.sessionCapabilities, AcpSessionCapabilities(load: true, list: true, resume: false, images: true, delete: true, close: true))
        let session = try call {
            client.request("session/new", AcpRPC.sessionParams(cwd: Self.workspace, bridge: nil, loadID: nil), completion: $0)
        }.dictionary
        let sessionID = try XCTUnwrap(session["sessionId"] as? String)
        client.sessionID = sessionID
        client.sessionInfo = session
        // The run uses the agent's own model and mode: nothing to set before the prompt.
        XCTAssertEqual(AcpSessionSettings.steps(session: sessionID, info: session, model: "", appliedModel: AcpSessionSettings.currentModel(session),
                                                mode: AcpSessionSettings.mode(plan: false, info: session),
                                                appliedMode: AcpSessionSettings.currentMode(session)), [])
        XCTAssertEqual(AcpSessionSettings.currentMode(session), "vibe")
        return (client, transport, events, exited, sessionID)
    }

    private func prompt(_ client: AcpClient, _ session: String, _ text: String, after: (() -> Void)? = nil) throws -> String {
        let response = try call { completion in
            client.request("session/prompt", AcpRPC.promptParams(sessionID: session, text: text), completion: completion)
            after?()
        }
        return AcpRPC.stop(response.dictionary).reason
    }

    private func reply(_ events: Collected<AcpEvent>) -> String {
        events.all.compactMap { if case .messageChunk(let text) = $0 { return text } else { return nil } }.joined()
    }

    func testKiroSimpleTurn() throws {
        let (client, transport, events, exited, session) = try kiro("kiro_simple")
        XCTAssertEqual(try prompt(client, session, "Reply with just the words: lanterns are lit"), "end_turn")
        XCTAssertEqual(reply(events), "lanterns are lit")
        let commands = events.all.compactMap { if case .commands(let list) = $0 { return list } else { return nil } }.last
        XCTAssertFalse(commands?.isEmpty ?? true, "Kiro's own / commands reach the composer")
        finish(transport, stop: client.stop, exited: exited)
    }

    func testKiroMultiTurn() throws {
        let (client, transport, events, exited, session) = try kiro("kiro_multi_turn")
        XCTAssertEqual(try prompt(client, session, "Say only: the kettle is on"), "end_turn")
        let first = reply(events)
        XCTAssertTrue(first.contains("the kettle is on"))
        XCTAssertEqual(try prompt(client, session, "Say only: the tea is ready"), "end_turn")
        XCTAssertTrue(reply(events).dropFirst(first.count).contains("the tea is ready"))
        finish(transport, stop: client.stop, exited: exited)
    }

    func testKiroTurnInterrupt() throws {
        let (client, transport, events, exited, session) = try kiro("kiro_turn_interrupt")
        // Stop: `session/cancel` follows the prompt, and the prompt then ends as cancelled.
        let reason = try prompt(client, session,
                                "Run `sleep 45` in the shell and wait for it, then say: the long wait is over") {
            client.notify("session/cancel", ["sessionId": session])
        }
        XCTAssertEqual(reason, "cancelled", "the workspace marks such a turn stopped")
        XCTAssertFalse(reply(events).contains("the long wait is over"))
        let frames = transport.written.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let cancel = try XCTUnwrap(frames.first { $0["method"] as? String == "session/cancel" })
        XCTAssertNil(cancel["id"], "a notification carries no id")
        finish(transport, stop: client.stop, exited: exited)
    }

    func testKiroToolApproval() throws {
        let asked = Collected<AcpToolCall>()
        let (client, transport, events, exited, session) = try kiro("kiro_tool_approval") { event, client in
            guard case .permission(let rpcID, let call, let options) = event else { return }
            asked.add(call)
            // Under "Ask", a write is not allowed without you; you allow it once.
            XCTAssertFalse(AcpRPC.autoAllows(call, permission: .ask, mode: .agent))
            client.respond(rpcID, AcpRPC.permissionOutcome(options, allow: true, always: false))
        }
        XCTAssertEqual(try prompt(client, session, "Put the text `hello from the replay` in greeting.txt at the project root, then tell me in one line what changed."),
                       "end_turn")
        // The write itself, then Kiro's review of the changes.
        XCTAssertEqual(asked.all.map(\.title), ["Write File", "Review changes"])
        let calls = events.all.compactMap { event -> AcpToolCall? in
            switch event {
            case .toolCall(let call), .toolCallUpdate(let call): return call
            default: return nil
            }
        }
        XCTAssertEqual(calls.first?.kind, "edit")
        let done = try XCTUnwrap(calls.last { $0.status == "completed" })
        // Kiro names the diff's file as a file:// URL; the edit row gets the path.
        XCTAssertEqual(done.paths, ["<workspace>/greeting.txt"])
        XCTAssertEqual(done.diffs, [AcpDiff(path: "<workspace>/greeting.txt", oldText: "", newText: "hello from the replay")])
        XCTAssertEqual(done.editInput?.dictionary["file_path"] as? String, "<workspace>/greeting.txt")
        XCTAssertTrue(reply(events).contains("hello from the replay"))
        finish(transport, stop: client.stop, exited: exited)
    }

    // MARK: Pi

    /// One Pi process for one turn, as the workspace starts it (`AgentCommand.piSpec`): the events it wrote, and how it
    /// ended. A settled turn closes Pi's input, as `finishPiTurn` does.
    private func pi(_ name: String, prompt: String, resume: String? = nil,
                    react: @escaping @Sendable (PiStreamEvent, AgentProcess) -> Void = { _, _ in }) throws -> [PiStreamEvent] {
        let transport = try transport(name)
        let input = AgentCommand.Input(provider: .pi, executable: "/usr/local/bin/pi", prompt: prompt, model: "openrouter/deepseek/deepseek-v4-flash",
                                       mode: .agent, permission: .ask, instructions: "", workingDirectory: "/tmp",
                                       resumeSessionID: resume, accountEnvironment: [:], runID: UUID())
        let launch = AgentCommand.piSpec(input, environment: [:])
        XCTAssertEqual(Array(launch.arguments.prefix(2)), ["--mode", "rpc"])
        if let resume { XCTAssertTrue(launch.arguments.contains(resume), "the next turn resumes Pi's session file") }
        let process = AgentProcess(spec: launch, transport: transport, scheduler: ImmediateProcessScheduler())
        let events = Collected<PiStreamEvent>()
        let exited = expectation(description: "pi exited")
        process.onLine = { [unowned process] line in
            for event in PiStreamParser.parse(line) {
                events.add(event)
                react(event, process)
                if case .settled = event { process.closeInput() }
            }
        }
        process.onExit = { _, _ in exited.fulfill() }
        try process.start(baseEnvironment: [:])
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(transport.mismatches, [], "Nook wrote what Pi expected")
        XCTAssertTrue(transport.isFinished, "the whole transcript was played")
        return events.all
    }

    private func texts(_ events: [PiStreamEvent]) -> [String] {
        events.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
    }

    private func sessionFile(_ events: [PiStreamEvent]) -> String? {
        events.compactMap { if case .session(let file, _, _) = $0 { return file } else { return nil } }.first ?? nil
    }

    func testPiSimpleTurn() throws {
        let events = try pi("pi_simple", prompt: "Reply with just the words: lanterns are lit")
        guard case .session(let file, let model, let window)? = events.first(where: { if case .session = $0 { return true } else { return false } })
        else { return XCTFail("get_state tells the session") }
        XCTAssertNotNil(file)
        XCTAssertEqual(model, "openrouter/deepseek/deepseek-v4-flash")
        XCTAssertNotNil(window)
        XCTAssertEqual(texts(events), ["lanterns are lit"])
        XCTAssertTrue(events.contains { if case .thinking(let text) = $0 { return text.contains("lanterns are lit") } else { return false } })
        let usage = events.compactMap { if case .usage(let usage) = $0 { return usage } else { return nil } }
        XCTAssertFalse(usage.isEmpty, "the turn's tokens are counted")
        XCTAssertEqual(events.last, .settled(aborted: false))
        XCTAssertFalse(events.contains { if case .failed = $0 { return true } else { return false } })
    }

    func testPiMultiTurnIsOneProcessPerTurn() throws {
        let first = try pi("pi_multi_turn_1", prompt: "Say only: the kettle is on")
        XCTAssertEqual(texts(first), ["the kettle is on"])
        let file = try XCTUnwrap(sessionFile(first))
        let second = try pi("pi_multi_turn_2", prompt: "Say only: the tea is ready", resume: file)
        XCTAssertEqual(texts(second), ["the tea is ready"])
        XCTAssertEqual(sessionFile(second), file, "the same session goes on")
    }

    func testPiMessageSteering() throws {
        let steer = "Change of plan, say only: plan B it is"
        let events = try pi("pi_message_steering", prompt: "Say only: plan A stands") { event, process in
            // Your message while Pi works goes into its turn, as the workspace's `steer` sends it.
            if event == .started { process.send(PiRPC.prompt(steer, steer: true)) }
        }
        let mine = events.compactMap { if case .userMessage(let text) = $0 { return text } else { return nil } }
        XCTAssertEqual(mine, ["Say only: plan A stands", steer], "Pi took both messages in, in order")
        XCTAssertEqual(texts(events).last, "plan B it is")
        XCTAssertEqual(events.filter { $0 == .started }.count, 1, "one run, steered")
    }

    func testPiTurnInterrupt() throws {
        let events = try pi("pi_turn_interrupt",
                            prompt: "Run `sleep 45` in the shell and wait for it, then say: the long wait is over") { event, process in
            // Stop while the command runs, as the workspace's Stop sends it (`PiRPCTurnDriver.interruptRequest`).
            if case .toolStarted = event { process.send(PiRPC.abort()) }
        }
        let finished = events.compactMap { event -> (String, Bool)? in
            if case .toolFinished(_, let name, _, let isError) = event { return (name, isError) } else { return nil }
        }
        XCTAssertEqual(finished.map(\.0), ["bash"])
        XCTAssertEqual(texts(events), [])
        // Pi ends a stopped turn with an error of its own; the workspace leaves it out of a stopped turn's timeline.
        XCTAssertTrue(events.contains(.failed("This operation was aborted")))
        XCTAssertTrue(events.contains { if case .settled = $0 { return true } else { return false } })
    }
}

/// Events collected from a client's queue, with a wait for a condition on them.
final class Collected<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [Element] = []

    func add(_ item: Element) {
        condition.lock()
        items.append(item)
        condition.broadcast()
        condition.unlock()
    }

    var all: [Element] {
        condition.lock()
        defer { condition.unlock() }
        return items
    }

    /// Waits up to ten seconds for `done`, checked whenever an element arrives.
    func wait(file: StaticString = #filePath, line: UInt = #line, until done: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            condition.lock()
            condition.wait(until: Date().addingTimeInterval(0.05))
            condition.unlock()
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<JSONBox, CodexAppServerError>?
    func set(_ result: Result<JSONBox, CodexAppServerError>) { lock.withLock { stored = result } }
    var result: Result<JSONBox, CodexAppServerError>? { lock.withLock { stored } }
}
