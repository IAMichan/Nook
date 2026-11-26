import XCTest

/// An agent client whose handlers capture the client itself (the one-shot text generation answers a permission with it
/// and stops it from its exit handler) must still go away once its process exits: every client drops its handlers after
/// the exit. Before that, every generated title left a client and its process in memory for as long as Nook ran.
final class AgentClientLifetimeTests: XCTestCase {
    private let spec = LaunchSpec(executable: "/usr/local/bin/agent", arguments: [], extraEnvironment: [:], workingDirectory: "/tmp",
                                  initialInput: [], keepsInputOpen: true)

    private func exitingTransport() throws -> ReplayTransport {
        ReplayTransport(try ProviderTranscript.parse("""
        {"type":"exit","status":0}
        """))
    }

    /// Waits for the exit, then a moment more: the exit handler runs on the process's queue and lets go after it returns.
    private func settle(_ exited: XCTestExpectation) {
        wait(for: [exited], timeout: 5)
        let gone = expectation(description: "released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gone.fulfill() }
        wait(for: [gone], timeout: 5)
    }

    func testAnAcpClientWhoseHandlersCaptureItGoesAwayAfterItsProcessExits() throws {
        let exited = expectation(description: "exit")
        weak var released: AcpClient?
        let transport = try exitingTransport()
        try autoreleasepool {
            let client = AcpClient(spec: spec, transport: transport, scheduler: ImmediateProcessScheduler())
            released = client
            client.onMessage = { _, _ in client.respond(.int(1), [:]) }
            client.onExit = { _, _ in
                client.stop()
                exited.fulfill()
            }
            try client.start()
        }
        settle(exited)
        XCTAssertNil(released, "the client stays alive through its own handlers")
    }

    func testACodexClientWhoseHandlersCaptureItGoesAwayAfterItsProcessExits() throws {
        let exited = expectation(description: "exit")
        weak var released: CodexAppServerClient?
        let transport = try exitingTransport()
        try autoreleasepool {
            let client = CodexAppServerClient(spec: spec, transport: transport, scheduler: ImmediateProcessScheduler())
            released = client
            client.onMessage = { _, _ in client.stop() }
            client.onExit = { _, _ in
                client.stop()
                exited.fulfill()
            }
            try client.start()
        }
        settle(exited)
        XCTAssertNil(released, "the client stays alive through its own handlers")
    }

    func testAnAgentProcessWhoseHandlersCaptureItGoesAwayAfterItExits() throws {
        let exited = expectation(description: "exit")
        weak var released: AgentProcess?
        let transport = try exitingTransport()
        try autoreleasepool {
            let process = AgentProcess(spec: spec, transport: transport, scheduler: ImmediateProcessScheduler())
            released = process
            process.onLines = { _ in process.stop() }
            process.onExit = { _, _ in
                process.stop()
                exited.fulfill()
            }
            try process.start()
        }
        settle(exited)
        XCTAssertNil(released, "the process stays alive through its own handlers")
    }
}
