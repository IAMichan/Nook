import XCTest

/// Agent transcripts replayed through the real `AgentProcess` line handling and `ClaudeStreamParser`, with only the
/// process itself replaced (`ReplayTransport`). Fixtures live in Tests/Fixtures/ProviderReplay and are written by hand.
final class ProviderReplayTests: XCTestCase {
    private static let toolApprovalPrompt = "Add the line 'tea is ready' to notes/kitchen.txt, then tell me when it is done."

    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private func fixture(_ name: String) throws -> ProviderTranscript {
        let url = Self.root.appendingPathComponent("Tests/Fixtures/ProviderReplay/\(name).ndjson")
        return try ProviderTranscript.parse(String(contentsOf: url, encoding: .utf8))
    }

    private func spec(prompt: String, runID: UUID = UUID()) -> LaunchSpec {
        LaunchSpec(executable: "/usr/local/bin/claude", arguments: ["-p"], extraEnvironment: ["NOOK_RUN_ID": runID.uuidString],
                   workingDirectory: "/tmp", initialInput: [ClaudeStreamParser.userMessage(prompt)], keepsInputOpen: true)
    }

    /// Replays a transcript and reacts to the parsed events like the workspace does; returns once the agent exited.
    private func replay(_ transcript: ProviderTranscript, prompt: String, scheduler: ProcessScheduler = ImmediateProcessScheduler(),
                        trafficLog: ProviderTrafficLog? = nil, afterStart: ((AgentProcess) -> Void)? = nil,
                        react: @escaping @Sendable (ClaudeStreamEvent, AgentProcess) -> Void = { _, _ in },
                        beforeExit: ((ReplayTransport) -> Void)? = nil) throws -> ReplayOutcome {
        let transport = ReplayTransport(transcript)
        let process = AgentProcess(spec: spec(prompt: prompt), transport: transport, scheduler: scheduler, trafficLog: trafficLog)
        let outcome = ReplayOutcome()
        let exited = expectation(description: "exited")
        process.onLine = { [unowned process] line in
            for event in ClaudeStreamParser.parse(line) {
                outcome.add(event)
                react(event, process)
            }
        }
        process.onExit = { status, stderr in
            outcome.finish(status, stderr)
            exited.fulfill()
        }
        try process.start(baseEnvironment: [:])
        afterStart?(process)
        beforeExit?(transport)
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(transport.mismatches, [], "Nook wrote what the agent expected")
        XCTAssertTrue(transport.isFinished, "the whole transcript was played")
        outcome.written = transport.written
        outcome.signals = transport.signals
        return outcome
    }

    // MARK: Scenarios

    func testNormalTurn() throws {
        let outcome = try replay(try fixture("claude_normal_turn"),
                                 prompt: "In one sentence, what does a lighthouse do?")
        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertEqual(outcome.events.compactMap { if case .initialized(let session, _) = $0 { return session } else { return nil } }.count, 1)
        XCTAssertTrue(outcome.events.contains(.text("A lighthouse guides ships safely past the coast at night.")))
        let results = outcome.results
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.isError, false)
        XCTAssertEqual(results.first?.text, "A lighthouse guides ships safely past the coast at night.")
        XCTAssertNotNil(results.first?.usage.outputTokens)
        XCTAssertEqual(outcome.written.count, 1, "only the prompt went to stdin")
    }

    func testToolApprovalRequestIsAnsweredOverStdin() throws {
        let asked = PermissionBox()
        let outcome = try replay(try fixture("claude_tool_approval"),
                                 prompt: Self.toolApprovalPrompt,
                                 react: { event, process in
            guard case .permissionRequest(let request, let tool, let input, _, let toolUseID, _) = event else { return }
            asked.set(tool: tool, toolUseID: toolUseID)
            process.send(ClaudeStreamParser.permissionResponse(requestID: request, allow: true, input: input))
        })
        XCTAssertEqual(asked.tool, "Bash")
        XCTAssertEqual(asked.toolUseID, "toolu_nook_kitchen_1")
        XCTAssertTrue(outcome.written.last?.contains("\"updatedInput\"") ?? false, "allow carries the tool's input back")
        // The tool ran after the approval, and the turn ended well.
        XCTAssertTrue(outcome.events.contains { if case .toolResult(id: "toolu_nook_kitchen_1", output: _, isError: false) = $0 { return true } else { return false } })
        XCTAssertEqual(outcome.results.map(\.isError), [false])
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testInterruptRequest() throws {
        let outcome = try replay(try fixture("claude_interrupt"),
                                 prompt: "Count slowly from one to a hundred, one number per line.",
                                 afterStart: { process in process.send(ClaudeStreamParser.interruptRequest(id: "interrupt-1")) })
        XCTAssertEqual(outcome.results, [], "the interrupted turn never finished")
        XCTAssertFalse(outcome.events.contains { if case .text = $0 { return true } else { return false } }, "no answer came")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testStopWhileAToolRuns() throws {
        let scheduler = ManualProcessScheduler()
        let sawTool = expectation(description: "tool started")
        let outcome = try replay(try fixture("claude_stop"), prompt: "Run sleep 30, then say done.", scheduler: scheduler,
                                 react: { event, process in
            guard case .toolUse = event else { return }
            process.stop()
            sawTool.fulfill()
        }, beforeExit: { _ in
            self.wait(for: [sawTool], timeout: 10)
            // SIGTERM, SIGKILL and the exit's delivery wait on the clock; nothing sleeps.
            XCTAssertTrue(scheduler.waitUntilScheduled(3))
            scheduler.advance(by: 8)
        })
        XCTAssertEqual(outcome.signals, [SIGINT], "the agent was gone before SIGTERM was due")
        XCTAssertEqual(outcome.exitStatus, 2)
        XCTAssertEqual(outcome.stderr, "Interrupted by user\n")
        XCTAssertEqual(outcome.results, [])
    }

    func testErrorResultThenRecovery() throws {
        let outcome = try replay(try fixture("claude_error_result"), prompt: "Give me a two-word name for a quiet reading corner.",
                                 react: { event, process in
            if case .result(let result) = event, result.isError {
                process.send(ClaudeStreamParser.userMessage("Signed in again, please retry."))
            }
        })
        XCTAssertEqual(outcome.results.map(\.isError), [true, false])
        XCTAssertTrue(outcome.results.first?.text.contains("401") ?? false)
        XCTAssertEqual(outcome.results.first?.apiErrorStatus, 401)
        XCTAssertEqual(outcome.results.last?.text, "Lantern Nook")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testStopEscalatesWithoutAProcess() throws {
        let transcript = try ProviderTranscript.parse("""
        {"type":"transcript_start","provider":"claude","scenario":"stubborn"}
        {"type":"expect_outbound","frame":{"type":"user"}}
        {"type":"expect_signal","signal":"SIGINT"}
        {"type":"expect_signal","signal":"SIGTERM"}
        {"type":"expect_signal","signal":"SIGKILL"}
        {"type":"exit","status":9}
        """)
        let scheduler = ManualProcessScheduler()
        let outcome = try replay(transcript, prompt: "hi", scheduler: scheduler, afterStart: { $0.stop(grace: 4) },
                                 beforeExit: { transport in
            XCTAssertEqual(transport.signals, [SIGINT])
            scheduler.advance(by: 4)
            XCTAssertEqual(transport.signals, [SIGINT, SIGTERM])
            scheduler.advance(by: 4)
            // The exit is delivered after a short delay, through the same clock.
            scheduler.advance(by: 1)
        })
        XCTAssertEqual(outcome.signals, [SIGINT, SIGTERM, SIGKILL])
        XCTAssertEqual(outcome.exitStatus, 9)
    }

    func testMismatchIsReported() throws {
        let transport = ReplayTransport(try ProviderTranscript.parse("""
        {"type":"expect_outbound","frame":{"type":"user","message":{"content":"expected"}}}
        {"type":"exit","status":0}
        """))
        try transport.start(.init(executable: "", arguments: [], environment: [:], workingDirectory: "", keepsInputOpen: true),
                            onStdout: { _ in }, onStderr: { _ in }, onExit: { _ in })
        try transport.write(Data(ClaudeStreamParser.userMessage("something else").utf8))
        XCTAssertEqual(transport.mismatches.count, 1)
        XCTAssertTrue(transport.isFinished)
    }

    // MARK: Transcript format

    func testFrameMatchingIsBySubset() {
        let frame = JSONBox(["type": "control_response", "response": ["request_id": "perm-1", "response": ["behavior": "allow"]]])
        let written = #"{"type":"control_response","response":{"subtype":"success","request_id":"perm-1","response":{"behavior":"allow","updatedInput":{"a":1}}}}"#
        XCTAssertTrue(ProviderTranscript.matches(written, frame: frame, line: nil))
        XCTAssertFalse(ProviderTranscript.matches(written.replacingOccurrences(of: "allow", with: "deny"), frame: frame, line: nil))
        XCTAssertFalse(ProviderTranscript.matches("not json", frame: frame, line: nil))
        // Arrays are compared whole.
        XCTAssertFalse(ProviderTranscript.matches(#"{"a":[1,2]}"#, frame: JSONBox(["a": [1]]), line: nil))
        XCTAssertTrue(ProviderTranscript.matches(#"{"a":[1,2]}"#, frame: JSONBox(["a": [1, 2]]), line: nil))
        XCTAssertTrue(ProviderTranscript.matches("plain text\n", frame: nil, line: "plain text"))
    }

    func testParseRejectsBrokenEntriesAndSkipsUnknownOnes() throws {
        XCTAssertThrowsError(try ProviderTranscript.parse("{\"type\":\"emit_inbound\"}"))
        XCTAssertThrowsError(try ProviderTranscript.parse("nonsense"))
        XCTAssertThrowsError(try ProviderTranscript.parse("{\"type\":\"expect_signal\",\"signal\":\"SIGFOO\"}"))
        let transcript = try ProviderTranscript.parse("""
        {"type":"transcript_start","provider":"codex","scenario":"x"}
        {"type":"note","text":"ignored"}
        {"type":"emit_inbound","line":"plain"}
        {"type":"exit","status":3}
        """)
        XCTAssertEqual(transcript.provider, "codex")
        XCTAssertEqual(transcript.entries, [.start(provider: "codex", scenario: "x"), .inbound("plain"), .exit(3)])
    }

    // MARK: Traffic log

    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-traffic-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testTrafficLogIsAReplayableFixture() throws {
        let url = temporaryFolder().appendingPathComponent("log.ndjson")
        let log = try XCTUnwrap(ProviderTrafficLog(url: url, provider: "claude"))
        let prompt = Self.toolApprovalPrompt
        let approve: @Sendable (ClaudeStreamEvent, AgentProcess) -> Void = { event, process in
            if case .permissionRequest(let request, _, let input, _, _, _) = event {
                process.send(ClaudeStreamParser.permissionResponse(requestID: request, allow: true, input: input))
            }
        }
        let recorded = try replay(try fixture("claude_tool_approval"), prompt: prompt, trafficLog: log, react: approve)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(#"{"#) && text.contains("transcript_start"))
        // The log, replayed, gives the same conversation.
        let again = try replay(try ProviderTranscript.parse(text), prompt: prompt, react: approve)
        XCTAssertEqual(again.events, recorded.events)
        XCTAssertEqual(again.exitStatus, recorded.exitStatus)
    }

    func testTrafficLogStopsAtItsLimit() throws {
        let url = temporaryFolder().appendingPathComponent("log.ndjson")
        let log = try XCTUnwrap(ProviderTrafficLog(url: url, provider: "claude", maxBytes: 400))
        for index in 0..<50 { log.inbound(#"{"type":"assistant","n":\#(index)}"#) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, 400 + 40)
        XCTAssertTrue(text.hasSuffix("{\"type\":\"truncated\"}\n"))
        XCTAssertEqual(text.components(separatedBy: "truncated").count, 2, "marked once")
        XCTAssertTrue(try ProviderTranscript.parse(text).entries.contains(.truncated))
    }

    func testTrafficLogIsOffByDefaultAndPerSession() throws {
        let defaults = scratchDefaults("nook-traffic-tests")
        let folder = temporaryFolder()
        let run = UUID()
        XCTAssertNil(ProviderTrafficLog.forLaunch(spec(prompt: "x", runID: run), defaults: defaults, directory: folder))
        defaults.set(true, forKey: ProviderTrafficLog.enabledKey)
        let log = try XCTUnwrap(ProviderTrafficLog.forLaunch(spec(prompt: "x", runID: run), defaults: defaults, directory: folder))
        XCTAssertTrue(log.url.lastPathComponent.hasPrefix(run.uuidString))
        var other = spec(prompt: "x")
        other.extraEnvironment = [:]
        XCTAssertNil(ProviderTrafficLog.forLaunch(other, defaults: defaults, directory: folder), "only processes of a session")
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTrafficLogRecordsBothDirectionsButNoEnvironment() throws {
        let url = temporaryFolder().appendingPathComponent("log.ndjson")
        let log = try XCTUnwrap(ProviderTrafficLog(url: url, provider: "claude"))
        var launch = spec(prompt: "hello")
        launch.extraEnvironment["ANTHROPIC_API_KEY"] = "sk-secret-value"
        let transcript = try ProviderTranscript.parse("""
        {"type":"expect_outbound","frame":{"type":"user"}}
        {"type":"emit_inbound","line":"not json"}
        {"type":"emit_stderr","text":"warn"}
        {"type":"exit","status":0}
        """)
        let process = AgentProcess(spec: launch, transport: ReplayTransport(transcript), scheduler: ImmediateProcessScheduler(),
                                   trafficLog: log)
        let exited = expectation(description: "exited")
        process.onExit = { _, _ in exited.fulfill() }
        try process.start(baseEnvironment: ["HOME": "/Users/someone"])
        wait(for: [exited], timeout: 10)
        let entries = try ProviderTranscript.parse(String(contentsOf: url, encoding: .utf8)).entries
        XCTAssertEqual(entries.count, 5)
        guard case .outbound(let frame, _) = entries[1] else { return XCTFail("the prompt is logged") }
        XCTAssertEqual(frame?.dictionary["type"] as? String, "user")
        XCTAssertEqual(Array(entries.suffix(3)), [.inbound("not json"), .stderr("warn"), .exit(0)])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("sk-secret-value"))
    }
}

/// Runs scheduled work at once.
struct ImmediateProcessScheduler: ProcessScheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) { work() }
}

/// What a replay produced, collected from the process's threads.
final class ReplayOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ClaudeStreamEvent] = []
    private(set) var exitStatus: Int32?
    private(set) var stderr = ""
    var written: [String] = []
    var signals: [Int32] = []

    var events: [ClaudeStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var results: [ClaudeTurnResult] {
        events.compactMap { if case .result(let result) = $0 { return result } else { return nil } }
    }

    func add(_ event: ClaudeStreamEvent) {
        lock.lock()
        collected.append(event)
        lock.unlock()
    }

    func finish(_ status: Int32, _ stderr: String) {
        lock.lock()
        exitStatus = status
        self.stderr = stderr
        lock.unlock()
    }
}

private final class PermissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (tool: String, toolUseID: String?)?
    var tool: String? { lock.lock(); defer { lock.unlock() }; return stored?.tool }
    var toolUseID: String? { lock.lock(); defer { lock.unlock() }; return stored?.toolUseID }
    func set(tool: String, toolUseID: String?) { lock.lock(); stored = (tool, toolUseID); lock.unlock() }
}
