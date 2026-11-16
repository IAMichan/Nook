import XCTest

/// An agent's server that hangs on opening a session (`initialize`, a thread or session, a turn's start) fails the
/// request once its deadline passes (`RPCDeadline`), instead of leaving the turn "working" until you stop it. A late
/// answer is dropped. Runs the real Codex and ACP clients against a scripted agent (`ReplayTransport`).
final class RPCDeadlineTests: XCTestCase {
    private let spec = LaunchSpec(executable: "/usr/local/bin/agent", arguments: [], extraEnvironment: [:], workingDirectory: "/tmp",
                                  initialInput: [], keepsInputOpen: true)

    func testAnACPRequestWithoutAnAnswerFailsAtItsDeadlineAndALateAnswerIsDropped() throws {
        let scheduler = ManualProcessScheduler()
        let transport = ReplayTransport(try ProviderTranscript.parse("""
        {"type":"expect_outbound","frame":{"id":1,"method":"initialize"}}
        {"type":"expect_outbound","frame":{"id":2,"method":"session/new"}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":1,"result":{"late":true}}}
        {"type":"emit_inbound","frame":{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s"}}}
        """))
        let client = AcpClient(spec: spec, transport: transport, scheduler: scheduler)
        let orphans = ReplayLines()
        client.onOrphanAnswer = { orphans.add($0.json) }
        try client.start()

        let failed = expectation(description: "initialize timed out")
        client.request("initialize", [:], timeout: RPCDeadline.initialize) { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error, .timedOut("initialize"))
                XCTAssertTrue(error.isTimeout)
                XCTAssertFalse(error.meansUnsupported, "a hang is not an agent too old for the protocol")
                failed.fulfill()
            }
        }
        scheduler.advance(by: RPCDeadline.initialize - 1)
        XCTAssertEqual(scheduler.scheduledCount, 1, "still waiting before the deadline")
        scheduler.advance(by: 1)
        wait(for: [failed], timeout: 5)

        let opened = expectation(description: "the next request is answered")
        client.request("session/new", [:], timeout: RPCDeadline.openSession) { result in
            XCTAssertEqual((try? result.get())?.dictionary["sessionId"] as? String, "s")
            opened.fulfill()
        }
        wait(for: [opened], timeout: 5)
        // Its deadline passes after the answer: nothing happens twice.
        scheduler.advance(by: RPCDeadline.openSession)
        XCTAssertEqual(orphans.all, [], "the late answer is not taken for a kept turn's end")
        XCTAssertEqual(transport.mismatches, [])
    }

    func testACodexRequestWithoutAnAnswerFailsAtItsDeadline() throws {
        let scheduler = ManualProcessScheduler()
        let transport = ReplayTransport(try ProviderTranscript.parse("""
        {"type":"expect_outbound","frame":{"id":1,"method":"initialize"}}
        """))
        let client = CodexAppServerClient(spec: spec, transport: transport, scheduler: scheduler)
        try client.start()
        let results = ReplayCounter()
        let failed = expectation(description: "initialize timed out")
        client.request("initialize", [:], timeout: RPCDeadline.initialize) { result in
            results.increment()
            if case .failure(.timedOut("initialize")) = result { failed.fulfill() }
        }
        scheduler.advance(by: RPCDeadline.initialize)
        wait(for: [failed], timeout: 5)
        scheduler.advance(by: RPCDeadline.initialize)
        XCTAssertEqual(results.value, 1, "a request fails once")
    }

    func testARequestWithoutADeadlineWaitsForItsAnswer() throws {
        let scheduler = ManualProcessScheduler()
        let transport = ReplayTransport(try ProviderTranscript.parse("""
        {"type":"expect_outbound","frame":{"id":1,"method":"session/prompt"}}
        """))
        let client = AcpClient(spec: spec, transport: transport, scheduler: scheduler)
        try client.start()
        let results = ReplayCounter()
        client.request("session/prompt", [:]) { _ in results.increment() }
        scheduler.advance(by: 24 * 3600)
        XCTAssertEqual(results.value, 0, "a turn takes as long as the work does")
    }
}
