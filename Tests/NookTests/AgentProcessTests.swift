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
        XCTAssertTrue(args.contains("--verbose"), "stream-json in print-modus vraagt --verbose")
        XCTAssertEqual(value(after: "--input-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--output-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--permission-prompt-tool", in: args), "stdio")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "acceptEdits")
        XCTAssertEqual(value(after: "--model", in: args), "opus")
        XCTAssertEqual(value(after: "--resume", in: args), "sess-1")
        XCTAssertEqual(value(after: "--append-system-prompt", in: args), "Gebruik tabs")
        XCTAssertFalse(args.contains("-doe iets"), "de opdracht gaat via stdin, nooit als argument")
        XCTAssertTrue(spec.keepsInputOpen)
        XCTAssertEqual(spec.initialInput.count, 1)
        XCTAssertNotNil(spec.extraEnvironment["NOOK_RUN_ID"])
        XCTAssertEqual(spec.extraEnvironment["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-werk")
    }

    func testClaudePermissionModes() {
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .plan, permission: .bypass), "plan")
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .agent, permission: .ask), "default")
        XCTAssertEqual(AgentCommand.claudePermissionMode(mode: .agent, permission: .bypass), "bypassPermissions")
        XCTAssertNil(value(after: "--model", in: AgentCommand.spec(input(.claude)).arguments), "geen model: de standaard van de agent")
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
        XCTAssertEqual(Array(args.suffix(2)), ["--", "-doe iets"], "een opdracht met een streepje wordt nooit een optie")
        XCTAssertFalse(spec.keepsInputOpen)
        XCTAssertEqual(AgentCommand.codexSandbox(mode: .plan, permission: .bypass), "read-only")
        XCTAssertEqual(AgentCommand.codexSandbox(mode: .agent, permission: .bypass), "danger-full-access")
    }

    func testEnvironment() {
        let env = AgentCommand.environment(base: ["PATH": "/usr/bin", "HOME": "/Users/x", "NOOK_INTERNAL": "1"],
                                           executable: "/opt/tools/bin/claude", extra: ["NOOK_RUN_ID": "r"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/opt/tools/bin:"))
        XCTAssertTrue(env["PATH"]!.hasSuffix(":/usr/bin"))
        XCTAssertNil(env["NOOK_INTERNAL"], "een werkruimte-sessie is een echte agent-sessie")
        XCTAssertEqual(env["NOOK_RUN_ID"], "r")
    }

    func testDisplayCommandHidesEnvironment() {
        var withKey = input(.claude)
        withKey.accountEnvironment["ANTHROPIC_API_KEY"] = "sk-ant-geheim"
        let spec = AgentCommand.spec(withKey)
        XCTAssertFalse(spec.displayCommand.contains("sk-ant"))
        XCTAssertFalse(spec.arguments.joined().contains("sk-ant"), "een sleutel staat nooit in de argumenten")
        XCTAssertTrue(spec.displayCommand.hasPrefix("claude -p"))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// Een nep-agent als shellscript: zo testen we het proces, stdin en de regels zonder echte Claude Code.
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
        // Leest het eerste bericht, meldt een sessie, vraagt toestemming en wacht op het antwoord.
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
        let exited = expectation(description: "klaar")
        let asked = expectation(description: "toestemming")
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
        let exited = expectation(description: "klaar")
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
        let started = expectation(description: "gestart")
        let exited = expectation(description: "gestopt")
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
        let exited = expectation(description: "klaar")
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

/// Verzamelt regels vanaf een andere thread.
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
