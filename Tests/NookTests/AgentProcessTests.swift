import XCTest

final class AgentCommandTests: XCTestCase {
    private func input(_ provider: RunProvider, mode: ExecutionMode = .agent, permission: PermissionPolicy = .acceptEdits,
                       model: String = "", resume: String? = nil, instructions: String = "") -> AgentCommand.Input {
        AgentCommand.Input(provider: provider, executable: "/usr/local/bin/\(provider.rawValue)", prompt: "-doe iets", model: model,
                           mode: mode, permission: permission, instructions: instructions, workingDirectory: "/tmp/w",
                           resumeSessionID: resume, accountEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/x/.claude-werk"], runID: UUID())
    }

    func testClaudeArguments() {
        let spec = AgentCommand.spec(input(.claude, model: "opus", resume: "sess-1", instructions: "Gebruik tabs"))
        let args = spec.arguments
        XCTAssertEqual(Array(args.prefix(1)), ["-p"])
        XCTAssertTrue(args.contains("--verbose"), "stream-json in print mode requires --verbose")
        XCTAssertEqual(value(after: "--input-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--output-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--permission-prompt-tool", in: args), "stdio")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "acceptEdits")
        XCTAssertEqual(value(after: "--model", in: args), "opus")
        XCTAssertEqual(value(after: "--resume", in: args), "sess-1")
        XCTAssertEqual(value(after: "--append-system-prompt", in: args), "Gebruik tabs")
        XCTAssertFalse(args.contains("-doe iets"), "the prompt is sent via stdin, never as an argument")
        XCTAssertTrue(spec.keepsInputOpen)
        XCTAssertEqual(spec.initialInput.count, 1)
        XCTAssertNotNil(spec.extraEnvironment["NOOK_RUN_ID"])
        XCTAssertEqual(spec.extraEnvironment["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-werk")
    }

    func testClaudeForkOnlyWithResume() {
        var forked = input(.claude, resume: "sess-1")
        forked.forkSession = true
        let args = AgentCommand.spec(forked).arguments
        XCTAssertEqual(value(after: "--resume", in: args), "sess-1")
        XCTAssertTrue(args.contains("--fork-session"), "a taken-over conversation that is still running is copied, never written to twice")
        XCTAssertFalse(AgentCommand.spec(input(.claude, resume: "sess-1")).arguments.contains("--fork-session"))
        var fresh = input(.claude)
        fresh.forkSession = true
        XCTAssertFalse(AgentCommand.spec(fresh).arguments.contains("--fork-session"), "nothing to copy without a session")
    }

    func testClaudePermissionModes() {
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .plan, permission: .bypass), "plan")
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .agent, permission: .ask), "default")
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .agent, permission: .bypass), "bypassPermissions")
        XCTAssertNil(value(after: "--model", in: AgentCommand.spec(input(.claude)).arguments), "no model: agent default")
        XCTAssertNil(value(after: "--resume", in: AgentCommand.spec(input(.claude)).arguments))
    }

    func testCodexArguments() {
        let spec = AgentCommand.spec(input(.codex, model: "gpt-5-codex", resume: "th-1"))
        let args = spec.arguments
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("--json"))
        XCTAssertEqual(value(after: "--sandbox", in: args), "workspace-write")
        XCTAssertEqual(value(after: "--model", in: args), "gpt-5-codex")
        XCTAssertEqual(value(after: "resume", in: args), "th-1")
        XCTAssertEqual(Array(args.suffix(2)), ["--", "-doe iets"], "a prompt starting with a dash is never parsed as a flag")
        XCTAssertFalse(spec.keepsInputOpen)
        XCTAssertEqual(AgentCommand.codexSandbox(mode: .plan, permission: .bypass), "read-only")
        XCTAssertEqual(AgentCommand.codexSandbox(mode: .agent, permission: .bypass), "danger-full-access")
    }

    func testEnvironment() {
        let env = AgentCommand.environment(base: ["PATH": "/usr/bin", "HOME": "/Users/x", "NOOK_INTERNAL": "1"],
                                           executable: "/opt/tools/bin/claude", extra: ["NOOK_RUN_ID": "r"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/opt/tools/bin:"))
        XCTAssertTrue(env["PATH"]!.hasSuffix(":/usr/bin"))
        XCTAssertNil(env["NOOK_INTERNAL"], "a workspace session is a real agent session")
        XCTAssertEqual(env["NOOK_RUN_ID"], "r")
    }

    func testDisplayCommandHidesEnvironment() {
        var withKey = input(.claude)
        withKey.accountEnvironment["ANTHROPIC_API_KEY"] = "sk-ant-geheim"
        let spec = AgentCommand.spec(withKey)
        XCTAssertFalse(spec.displayCommand.contains("sk-ant"))
        XCTAssertFalse(spec.arguments.joined().contains("sk-ant"), "a key is never passed in arguments")
        XCTAssertTrue(spec.displayCommand.hasPrefix("claude -p"))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// A mock agent shell script: tests process handling, stdin, and output streaming without real Claude Code.
final class AgentProcessTests: XCTestCase {
    private var folder: String!

    override func setUpWithError() throws {
        folder = try TestData.tempFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func script(_ body: String) throws -> String {
        let path = folder + "/fake-agent.sh"
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    func testStreamsLinesAndAnswersOverStdin() throws {
        // Reads the first message, initializes session, requests permission, and awaits response.
        let path = try script("""
        read first
        echo '{"type":"system","subtype":"init","session_id":"fake-1","model":"fake"}'
        printf '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}\\n'
        read answer
        echo "$answer" | grep -q '"behavior":"allow"' && echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"fake-1","total_cost_usd":0.01,"usage":{"input_tokens":3,"output_tokens":4}}'
        read rest
        echo "$NOOK_RUN_ID" > "\(folder!)/run-id.txt"
        """)
        let runID = UUID()
        let spec = LaunchSpec(executable: path, arguments: [], extraEnvironment: ["NOOK_RUN_ID": runID.uuidString],
                              workingDirectory: folder, initialInput: [ClaudeStreamParser.userMessage("hoi")], keepsInputOpen: true)
        let process = AgentProcess(spec: spec)
        let lines = LineCollector()
        let exited = expectation(description: "done")
        let asked = expectation(description: "permission")
        let finished = expectation(description: "result")
        process.onLine = { line in
            lines.add(line)
            for event in ClaudeStreamParser.parse(line) {
                switch event {
                case .permissionRequest(let request, _, let input, _, _):
                    asked.fulfill()
                    process.send(ClaudeStreamParser.permissionResponse(requestID: request, allow: true, input: input))
                case .result:
                    finished.fulfill()
                    process.closeInput()
                default: break
                }
            }
        }
        process.onExit = { status, _ in
            XCTAssertEqual(status, 0)
            exited.fulfill()
        }
        try process.start()
        wait(for: [asked, finished, exited], timeout: 15, enforceOrder: true)
        XCTAssertEqual(lines.all.count, 3)
        let written = try String(contentsOfFile: folder + "/run-id.txt", encoding: .utf8)
        XCTAssertEqual(written.trimmingCharacters(in: .whitespacesAndNewlines), runID.uuidString)
    }

    func testPartialLastLineIsDelivered() throws {
        let path = try script("printf '{\"type\":\"thread.started\",\"thread_id\":\"t\"}'\n")
        let spec = LaunchSpec(executable: path, arguments: [], extraEnvironment: [:], workingDirectory: folder,
                              initialInput: [], keepsInputOpen: false)
        let process = AgentProcess(spec: spec)
        let lines = LineCollector()
        let exited = expectation(description: "done")
        process.onLine = { lines.add($0) }
        process.onExit = { _, _ in exited.fulfill() }
        try process.start()
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(lines.all.map { CodexStreamParser.parse($0) }.first, [.threadStarted("t")])
    }

    func testStopEndsALongRunningAgent() throws {
        let path = try script("echo started\nsleep 60\n")
        let spec = LaunchSpec(executable: path, arguments: [], extraEnvironment: [:], workingDirectory: folder,
                              initialInput: [], keepsInputOpen: true)
        let process = AgentProcess(spec: spec)
        let started = expectation(description: "started")
        let exited = expectation(description: "stopped")
        process.onLine = { if $0 == "started" { started.fulfill() } }
        process.onExit = { status, _ in
            XCTAssertNotEqual(status, 0)
            exited.fulfill()
        }
        try process.start()
        wait(for: [started], timeout: 10)
        process.stop(grace: 1)
        wait(for: [exited], timeout: 15)
        XCTAssertFalse(process.isRunning)
    }

    func testStderrTailIsReported() throws {
        let path = try script("echo 'Error: not logged in' >&2\nexit 3\n")
        let spec = LaunchSpec(executable: path, arguments: [], extraEnvironment: [:], workingDirectory: folder,
                              initialInput: [], keepsInputOpen: false)
        let process = AgentProcess(spec: spec)
        let exited = expectation(description: "done")
        let collected = LineCollector()
        process.onExit = { status, stderr in
            XCTAssertEqual(status, 3)
            collected.add(stderr)
            exited.fulfill()
        }
        try process.start()
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(collected.all.first?.contains("not logged in") ?? false)
    }
}

/// Thread-safe line collector.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class AgentTranscriptTests: XCTestCase {
    func testAntigravityPromptCleaning() {
        let envelope = """
        <USER_REQUEST>
        Zorg ervoor dat de animatie synchroon loopt.
        </USER_REQUEST>
        <ADDITIONAL_METADATA>
        The current local time is: 2026-10-16T15:35:32+02:00.
        </ADDITIONAL_METADATA>
        <USER_SETTINGS_CHANGE>
        The user changed setting Model Selection.
        </USER_SETTINGS_CHANGE>
        """
        XCTAssertEqual(AgentTranscript.cleanAntigravityPrompt(envelope), "Zorg ervoor dat de animatie synchroon loopt.")

        let plain = "Gewoon een directe prompt zonder tags."
        XCTAssertEqual(AgentTranscript.cleanAntigravityPrompt(plain), "Gewoon een directe prompt zonder tags.")
    }

    func testAntigravityTranscriptRecent() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("transcript.jsonl")
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-16T13:35:32Z","content":"<USER_REQUEST>\nToon transcript\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-16T13:35:33Z","input_tokens":100,"output_tokens":50,"tool_calls":[{"name":"run_command","args":{"CommandLine":"ls","Cwd":"/app"}}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-16T13:35:35Z","input_tokens":200,"output_tokens":30,"content":"Ik heb het gevonden."}"#
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)

        let messages = AgentTranscript.recent(path: file.path)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].fromUser)
        XCTAssertEqual(messages[0].text, "Toon transcript")
        XCTAssertFalse(messages[1].fromUser)
        XCTAssertFalse(messages[1].isThinking)
        XCTAssertEqual(messages[1].text, "Ik heb het gevonden.")
    }

    func testAntigravityTranscriptThinking() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("transcript.jsonl")
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-16T13:35:32Z","content":"Zoek de bug"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","thinking":"Eerst controleren we de status van git.","tool_calls":[{"name":"run_command"}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","thinking":"Nu inspecteren we de code in AgentTranscript.swift.","tool_calls":[{"name":"view_file"}]}"#,
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Ik heb de oorzaak ontdekt en opgelost."}"#
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)

        let messages = AgentTranscript.recent(path: file.path)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[0].fromUser)
        XCTAssertEqual(messages[0].text, "Zoek de bug")

        XCTAssertFalse(messages[1].fromUser)
        XCTAssertTrue(messages[1].isThinking)
        XCTAssertEqual(messages[1].kind, .thinking)
        XCTAssertEqual(messages[1].text, "Eerst controleren we de status van git.\n\nNu inspecteren we de code in AgentTranscript.swift.")

        XCTAssertFalse(messages[2].fromUser)
        XCTAssertFalse(messages[2].isThinking)
        XCTAssertEqual(messages[2].kind, .assistant)
        XCTAssertEqual(messages[2].text, "Ik heb de oorzaak ontdekt en opgelost.")
    }
}

final class AntigravityClientTests: XCTestCase {
    func testCommandDetection() {
        if AntigravityClient.isAvailable {
            let cmd = AntigravityClient.command()
            XCTAssertNotNil(cmd)
            XCTAssertFalse(cmd!.executable.isEmpty)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cmd!.executable))
        }
    }
}


