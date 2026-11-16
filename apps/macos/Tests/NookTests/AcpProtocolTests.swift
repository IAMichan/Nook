import XCTest

/// How Nook's ACP client keeps to the protocol where agents differ from the schema: the generation read from the shape of
/// `initialize`, notifications without an id in the order Nook sent them, request ids inside 32 bits, text between frames,
/// a `session/load` that never answers, and config answers older than an update. Each case runs the real `AcpClient`
/// against a scripted agent (`ReplayTransport`).
final class AcpProtocolTests: XCTestCase {
    private func client(_ transcript: String, scheduler: ProcessScheduler = DispatchProcessScheduler()) throws -> (AcpClient, ReplayTransport) {
        let transport = ReplayTransport(try ProviderTranscript.parse(transcript))
        let spec = LaunchSpec(executable: "/usr/local/bin/agent", arguments: [], extraEnvironment: [:], workingDirectory: "/tmp",
                              initialInput: [], keepsInputOpen: true)
        let client = AcpClient(spec: spec, transport: transport, scheduler: scheduler)
        return (client, transport)
    }

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: 1. The generation comes from the shape

    func testVersionTwoInTheV1ShapeIsReadAsV1() {
        // Kiro 2.32 (and Antigravity) report version 2 with v1's agentCapabilities.
        let kiro: [String: Any] = ["protocolVersion": 2, "authMethods": [["id": "aws-builder-id"]],
                                   "agentCapabilities": ["loadSession": true, "promptCapabilities": ["image": true],
                                                         "sessionCapabilities": ["list": [String: Any](), "close": [String: Any](),
                                                                                 "delete": [String: Any]()]]]
        XCTAssertEqual(AcpRPC.generation(kiro), 1)
        let capabilities = AcpSessionCapabilities(initialize: kiro)
        XCTAssertEqual(capabilities, AcpSessionCapabilities(load: true, list: true, resume: false, images: true, delete: true, close: true))
        XCTAssertEqual(AcpRPC.authMethodIDs(kiro), ["aws-builder-id"])
    }

    func testAV2AnswerIsReadThroughItsCapabilities() {
        let v2: [String: Any] = ["protocolVersion": 2, "info": ["name": "agent", "version": "2"],
                                 "capabilities": ["session": ["prompt": ["image": [String: Any]()], "delete": [String: Any]()]]]
        XCTAssertEqual(AcpRPC.generation(v2), 2)
        XCTAssertEqual(AcpSessionCapabilities(initialize: v2),
                       AcpSessionCapabilities(load: true, list: true, resume: true, images: true, delete: true, close: true))
        let bare: [String: Any] = ["protocolVersion": 2, "info": ["name": "agent"], "capabilities": [String: Any]()]
        XCTAssertEqual(AcpSessionCapabilities(initialize: bare), AcpSessionCapabilities())
        // Nook still speaks v1 and asks for nothing it would not use (no `session.notices`).
        let params = AcpRPC.initializeParams()
        XCTAssertEqual(params["protocolVersion"] as? Int, 1)
        XCTAssertNil((params["clientCapabilities"] as? [String: Any])?["session"])
    }

    // MARK: 2. Notifications: no id, in order

    func testANotificationHasNoIDAndFollowsTheRequestBeforeIt() throws {
        let (client, transport) = try client("")
        client.request("session/prompt", ["sessionId": "s"]) { _ in }
        client.notify("session/cancel", ["sessionId": "s"])
        XCTAssertEqual(transport.written.count, 2)
        XCTAssertEqual(object(transport.written[0])["method"] as? String, "session/prompt")
        let cancel = object(transport.written[1])
        XCTAssertEqual(cancel["method"] as? String, "session/cancel")
        XCTAssertNil(cancel["id"], "an agent drops a notification that carries an id")
        XCTAssertEqual(cancel["jsonrpc"] as? String, "2.0")
    }

    func testWritesFromManyThreadsStayWholeAndInIDOrder() throws {
        let (client, transport) = try client("")
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 3) {
                client.notify("session/cancel", ["sessionId": "s"])
            } else {
                client.request("session/prompt", ["sessionId": "s", "n": index]) { _ in }
            }
        }
        let frames = transport.written.map(object)
        XCTAssertEqual(frames.count, 200, "every line arrived whole")
        let ids = frames.compactMap { $0["id"] as? Int }
        XCTAssertEqual(ids, Array(1...ids.count), "requests reach the agent in the order of their ids")
    }

    // MARK: 3. Request ids fit in 32 bits

    func testRequestIDsStayInsideInt32() {
        XCTAssertEqual(AcpRPC.nextRequestID(after: 1), 2)
        XCTAssertEqual(AcpRPC.nextRequestID(after: Int(Int32.max) - 1), Int(Int32.max))
        XCTAssertEqual(AcpRPC.nextRequestID(after: Int(Int32.max)), 1, "wraps before the Kotlin ACP SDK would reject it")
        XCTAssertEqual(AcpRPC.nextRequestID(after: Int(Int32.max) + 5), 1)
        for _ in 0..<100 {
            let first = AcpRPC.reattachedFirstID()
            XCTAssertTrue((1_000_001...2_000_001).contains(first))
        }
    }

    // MARK: 4. Text between frames

    func testTextBetweenFramesIsSkippedAndABrokenFrameIsReported() throws {
        let (client, transport) = try client("""
        {"type":"expect_outbound","frame":{"id":1,"method":"initialize"}}
        {"type":"emit_inbound","line":"Open the following link to authenticate the ACP server: https://example.com/x"}
        {"type":"emit_inbound","line":"{\\"jsonrpc\\":\\"2.0\\",\\"id\\":1,\\"res"}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}}
        """)
        let texts = ReplayLines()
        let broken = ReplayLines()
        client.onText = { texts.add($0) }
        client.onBrokenFrame = { broken.add($0) }
        try client.start()
        let answered = expectation(description: "initialize answered")
        client.request("initialize", AcpRPC.initializeParams()) { result in
            XCTAssertEqual((try? result.get())?.dictionary["protocolVersion"] as? Int, 1)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(texts.all.count, 2, "both lines that are not JSON-RPC reach onText (Antigravity's sign-in link)")
        XCTAssertEqual(broken.all, [#"{"jsonrpc":"2.0","id":1,"res"#], "only the broken frame is reported")
        XCTAssertEqual(client.brokenFrames, 1)
        XCTAssertEqual(transport.mismatches, [])
    }

    // MARK: 5. A load that never answers

    func testALoadIsDoneOnceItsReplayGoesQuiet() throws {
        let scheduler = ManualProcessScheduler()
        let (client, transport) = try client("""
        {"type":"expect_outbound","frame":{"id":1,"method":"session/load"}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}}}}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}}
        {"type":"expect_outbound","frame":{"id":2,"method":"session/prompt"}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":1,"result":{"late":true}}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}}
        """, scheduler: scheduler)
        let orphans = ReplayLines()
        client.onOrphanAnswer = { orphans.add($0.json) }
        try client.start()
        client.replaying = true
        let loads = ReplayCounter()
        let loaded = expectation(description: "load done")
        client.load("session/load", ["sessionId": "s"]) { result in
            XCTAssertNotNil(try? result.get())
            loads.increment()
            loaded.fulfill()
        }
        // The two replayed updates arrive; one quiet check waits for them to stop.
        XCTAssertTrue(scheduler.waitUntilScheduled(1))
        scheduler.advance(by: AcpRPC.loadReplayQuiet)
        if loads.value == 0 { scheduler.advance(by: AcpRPC.loadReplayQuiet) }
        wait(for: [loaded], timeout: 5)
        client.replaying = false

        // The agent's late answer to the load is dropped; the next request is answered as usual.
        let prompted = expectation(description: "prompt answered")
        client.request("session/prompt", ["sessionId": "s"]) { result in
            XCTAssertEqual((try? result.get())?.dictionary["stopReason"] as? String, "end_turn")
            prompted.fulfill()
        }
        wait(for: [prompted], timeout: 5)
        XCTAssertEqual(loads.value, 1)
        XCTAssertEqual(orphans.all, [], "the late answer is not taken for a kept turn's end")
        XCTAssertEqual(transport.mismatches, [])
    }

    func testALoadWithoutAReplayWaitsForItsAnswer() throws {
        let scheduler = ManualProcessScheduler()
        let (client, _) = try client("""
        {"type":"expect_outbound","frame":{"id":1,"method":"session/load"}}
        """, scheduler: scheduler)
        try client.start()
        client.replaying = true
        let loads = ReplayCounter()
        client.load("session/load", ["sessionId": "s"]) { _ in loads.increment() }
        scheduler.advance(by: 30)
        XCTAssertEqual(scheduler.scheduledCount, 0, "nothing replayed: no quiet check")
        XCTAssertEqual(loads.value, 0)
    }

    // MARK: 7. A config answer older than an update

    func testAConfigAnswerAfterAnUpdateIsSuperseded() throws {
        let update = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","category":"model","type":"select","currentValue":"b","options":[{"value":"b"}]}]}}}"#
        let (client, transport) = try client("""
        {"type":"expect_outbound","frame":{"id":1,"method":"session/set_config_option"}}
        {"type":"emit_inbound","frame":\(update)}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":1,"result":{"configOptions":[]}}}
        {"type":"expect_outbound","frame":{"id":2,"method":"session/set_config_option"}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":2,"result":{"configOptions":[]}}}
        {"type":"emit_inbound","frame":\(update)}
        """)
        try client.start()
        let first = expectation(description: "first")
        client.request("session/set_config_option", ["sessionId": "s", "configId": "model", "value": "b"], tracksConfig: true) { result, superseded in
            XCTAssertNotNil(try? result.get())
            XCTAssertTrue(superseded, "the update came while the request was on its way")
            first.fulfill()
        }
        wait(for: [first], timeout: 5)
        let second = expectation(description: "second")
        client.request("session/set_config_option", ["sessionId": "s", "configId": "model", "value": "b"], tracksConfig: true) { _, superseded in
            XCTAssertFalse(superseded, "an update after the answer does not make it older")
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(transport.mismatches, [])
    }

    // MARK: Paths

    func testADiffNamedByAFileURLBecomesAPath() throws {
        let update: [String: Any] = ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
                                     "content": [["type": "diff", "path": "file:///Users/me/a%20b.txt", "oldText": "", "newText": "x"]],
                                     "locations": [["path": "/Users/me/a b.txt"]]]
        let message = CodexRPCMessage.notification(method: "session/update", params: JSONBox(["sessionId": "s", "update": update]))
        guard case .toolCallUpdate(let call)? = AcpMapper.events(message).first else { return XCTFail("a tool call update") }
        XCTAssertEqual(call.paths, ["/Users/me/a b.txt"])
        XCTAssertEqual(call.diffs.first?.path, "/Users/me/a b.txt")
        XCTAssertEqual(AcpMapper.filePath("/plain/path"), "/plain/path")
        XCTAssertEqual(AcpMapper.filePath("file://<workspace>/x.txt"), "<workspace>/x.txt")
    }
}

/// Collected from the client's queue.
final class ReplayLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

final class ReplayCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
