import Foundation

/// How Nook launches an agent: executable, arguments (as list, never via a shell), environment, and directory.
struct LaunchSpec: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    /// Only what Nook adds to your environment (PATH, account directory, NOOK_RUN_ID).
    var extraEnvironment: [String: String]
    var workingDirectory: String
    /// Lines sent to stdin immediately.
    var initialInput: [String]
    /// Does stdin stay open (for approvals and interruption)? Otherwise the agent gets /dev/null.
    var keepsInputOpen: Bool
    /// Variables of your environment the agent must not see (Antigravity: other Google accounts and projects).
    var removedEnvironment: [String] = []

    /// For display: without environment and with long arguments truncated, so sensitive information is never shown.
    var displayCommand: String {
        let program = URL(fileURLWithPath: executable).lastPathComponent
        let shown = arguments.map { argument -> String in
            let short = argument.count > 48 ? String(argument.prefix(45)) + "…" : argument
            return short.contains(" ") ? "\"\(short)\"" : short
        }
        return ([program] + shown).joined(separator: " ")
    }
}

/// Builds the command per agent. Testable in isolation: nothing runs here.
enum AgentCommand {
    struct Input: Sendable {
        var provider: RunProvider
        var executable: String
        var prompt: String
        var model: String
        var mode: ExecutionMode
        var permission: PermissionPolicy
        var instructions: String
        var workingDirectory: String
        /// To resume an earlier agent session.
        var resumeSessionID: String?
        /// Claude Code: resume as a copy of the conversation (`--fork-session`), leaving the original untouched.
        var forkSession = false
        /// CLAUDE_CONFIG_DIR or CODEX_HOME for the chosen account; empty for the primary account.
        var accountEnvironment: [String: String]
        var runID: UUID
        /// Nook's workspace bridge (terminal, browser, pull requests) as an MCP server; nil leaves the agent as it is.
        var bridge: BridgeLaunch? = nil
        /// Claude Code knows `--thinking-display`: ask for summarized thinking (T3Code's way), so newer models show it.
        var thinkingDisplay = false
    }

    static func spec(_ input: Input) -> LaunchSpec {
        var environment = input.accountEnvironment
        environment["NOOK_RUN_ID"] = input.runID.uuidString
        switch input.provider {
        case .claude:
            var arguments = [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                // Permission prompts arrive as control_request on stdout; Nook replies via stdin.
                "--permission-prompt-tool", "stdio",
                "--permission-mode", claudePermissionMode(mode: input.mode, permission: input.permission),
                // Newer models leave their thinking empty unless summaries are asked for (T3Code: showThinkingSummaries).
                "--settings", #"{"showThinkingSummaries":true}"#
            ]
            if input.thinkingDisplay { arguments += ["--thinking-display", "summarized"] }
            if !input.model.isEmpty { arguments += ["--model", input.model] }
            if let resume = input.resumeSessionID, !resume.isEmpty {
                arguments += ["--resume", resume]
                if input.forkSession { arguments.append("--fork-session") }
            }
            var instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if let bridge = input.bridge {
                arguments += bridge.claudeArguments(runID: input.runID)
                instructions = [instructions, BridgeLaunch.instructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            if !instructions.isEmpty { arguments += ["--append-system-prompt", instructions] }
            return LaunchSpec(executable: input.executable, arguments: arguments, extraEnvironment: environment,
                              workingDirectory: input.workingDirectory,
                              initialInput: [ClaudeStreamParser.userMessage(input.prompt)], keepsInputOpen: true)

        case .codex:
            var arguments = ["exec", "--json", "--skip-git-repo-check",
                             "--sandbox", codexSandbox(mode: input.mode, permission: input.permission),
                             "--cd", input.workingDirectory]
            if !input.model.isEmpty { arguments += ["--model", input.model] }
            // Detailed reasoning summaries, as T3Code asks for them: the timeline shows how Codex thinks, not only what it did.
            arguments += ["-c", "model_reasoning_summary=\"detailed\""]
            if let bridge = input.bridge { arguments += bridge.codexArguments(runID: input.runID) }
            var prompt = input.prompt
            var instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if input.bridge != nil {
                instructions = [instructions, BridgeLaunch.instructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            // Codex exec has no separate system prompt: instructions prepend the first prompt.
            if !instructions.isEmpty, input.resumeSessionID == nil { prompt = instructions + "\n\n" + prompt }
            if input.mode == .plan, input.resumeSessionID == nil {
                prompt = "Create a plan only; do not make any changes.\n\n" + prompt
            }
            if let resume = input.resumeSessionID, !resume.isEmpty { arguments += ["resume", resume] }
            // "--" so that a prompt starting with a dash is never parsed as a flag.
            arguments += ["--", prompt]
            return LaunchSpec(executable: input.executable, arguments: arguments, extraEnvironment: environment,
                              workingDirectory: input.workingDirectory, initialInput: [], keepsInputOpen: false)

        case .gemini:
            var arguments = ["--output-format", "stream-json",
                             "--approval-mode", geminiApprovalMode(mode: input.mode, permission: input.permission)]
            if !input.model.isEmpty { arguments += ["--model", input.model] }
            if let resume = input.resumeSessionID, !resume.isEmpty { arguments += ["--resume", resume] }
            var prompt = input.prompt
            let instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            // No separate system prompt in headless mode: instructions go before the first prompt, like Codex.
            if !instructions.isEmpty, input.resumeSessionID == nil { prompt = instructions + "\n\n" + prompt }
            // One argument with "=", so a prompt starting with a dash is never parsed as a flag.
            arguments.append("--prompt=" + prompt)
            return LaunchSpec(executable: input.executable, arguments: arguments, extraEnvironment: environment,
                              workingDirectory: input.workingDirectory, initialInput: [], keepsInputOpen: false)

        case .opencode, .cursor, .grok, .antigravity:
            return acpSpec(input)
        }
    }

    /// The ACP server command of an agent that only runs over ACP (see AcpAgent).
    static func acpSpec(_ input: Input) -> LaunchSpec {
        var environment = input.accountEnvironment
        environment["NOOK_RUN_ID"] = input.runID.uuidString
        return LaunchSpec(executable: input.executable, arguments: AcpLaunch.arguments(input.provider, permission: input.permission),
                          extraEnvironment: environment, workingDirectory: input.workingDirectory, initialInput: [],
                          keepsInputOpen: true)
    }

    static func geminiApprovalMode(mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "plan" }
        switch permission {
        case .ask: return "default"
        case .acceptEdits: return "auto_edit"
        case .bypass: return "yolo"
        }
    }

    static func claudePermissionMode(mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "plan" }
        switch permission {
        case .ask: return "default"
        case .acceptEdits: return "acceptEdits"
        case .bypass: return "bypassPermissions"
        }
    }

    static func codexSandbox(mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "read-only" }
        switch permission {
        case .ask: return "read-only"
        case .acceptEdits: return "workspace-write"
        case .bypass: return "danger-full-access"
        }
    }

    /// PATH with locations where Node and agents typically reside, even when Nook starts from Finder.
    static func environment(base: [String: String], executable: String, extra: [String: String]) -> [String: String] {
        var env = base
        let home = env["HOME"] ?? NSHomeDirectory()
        let paths = [URL(fileURLWithPath: executable).deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
        env["PATH"] = (paths + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        // Nook's internal thinking via Claude Code sets this; a workspace session is a real agent session.
        env["NOOK_INTERNAL"] = nil
        for (key, value) in extra { env[key] = value }
        return env
    }
}

/// A single running agent process. Delivers stdout lines one by one on a dedicated queue.
/// Termination is always safe: graceful first (SIGINT), then forced after a few seconds.
final class AgentProcess: @unchecked Sendable {
    let spec: LaunchSpec
    private let process = Process()
    private var input: FileHandle?
    private let queue = DispatchQueue(label: "nook.agent-process")
    private var buffer = Data()
    private var stderrTail = Data()
    private let lock = NSLock()
    private var finished = false

    /// Every complete line from stdout.
    var onLine: (@Sendable (String) -> Void)?
    /// Batch of complete lines from a single stdout read chunk.
    var onLines: (@Sendable ([String]) -> Void)?
    /// The process has exited: exit code and the last lines of stderr.
    var onExit: (@Sendable (Int32, String) -> Void)?

    init(spec: LaunchSpec) {
        self.spec = spec
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory, isDirectory: true)
        var environment = AgentCommand.environment(base: baseEnvironment, executable: spec.executable, extra: spec.extraEnvironment)
        for key in spec.removedEnvironment where spec.extraEnvironment[key] == nil { environment[key] = nil }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if spec.keepsInputOpen {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.queue.async { self.flushRemainder() }
            } else {
                self.queue.async { self.consume(data) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self.queue.async {
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 8_192 { self.stderrTail = self.stderrTail.suffix(8_192) }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // Wait briefly so remaining stdout lines are processed first.
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.flushRemainder()
                let tail = String(decoding: self.stderrTail, as: UTF8.self)
                self.markFinished()
                self.onExit?(process.terminationStatus, tail)
            }
        }
        // SIGPIPE would terminate Nook if the agent exits while writing.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        for line in spec.initialInput { send(line) }
    }

    /// Writes a line to stdin (a message, an answer to a permission prompt).
    func send(_ line: String) {
        lock.lock()
        let handle = finished ? nil : input
        lock.unlock()
        guard let handle, let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // The process has already exited; termination is reported via onExit.
        }
    }

    /// Closes stdin: the agent wraps up and exits.
    func closeInput() {
        lock.lock()
        let handle = input
        input = nil
        lock.unlock()
        try? handle?.close()
    }

    /// Graceful stop: SIGINT, then forced after `grace` seconds if still running.
    func stop(grace: TimeInterval = 4) {
        guard process.isRunning else { return }
        process.interrupt()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace + 4) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func markFinished() {
        lock.lock()
        finished = true
        let handle = input
        input = nil
        lock.unlock()
        try? handle?.close()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var batch: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { batch.append(line) }
        }
        guard !batch.isEmpty else { return }
        if let onLines {
            onLines(batch)
        } else if let onLine {
            for line in batch { onLine(line) }
        }
    }

    private func flushRemainder() {
        guard !buffer.isEmpty else { return }
        let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        guard !line.isEmpty else { return }
        if let onLines {
            onLines([line])
        } else {
            onLine?(line)
        }
    }
}
