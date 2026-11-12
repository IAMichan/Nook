import Foundation

/// How Nook launches an agent: executable, arguments (as list, never via a shell), environment, and directory.
/// Where a kept agent lives. `offset`: attach to the keeper there, from that much of its output; nil starts a new one.
struct KeeperPlacement: Equatable, Sendable {
    var folder: String
    var script: String
    var offset: UInt64? = nil
}

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
    /// Runs through a keeper, so it outlives Nook (`SessionKeeper`).
    var keeper: KeeperPlacement? = nil

    /// For display: without environment and with long arguments truncated, so sensitive information is never shown.
    var displayCommand: String {
        let program = (executable as NSString).lastPathComponent
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
        /// Claude Code: resume only up to this conversation entry (`--resume-session-at`), for a rolled-back conversation.
        var resumeAt: String? = nil
        /// CLAUDE_CONFIG_DIR or CODEX_HOME for the chosen account; empty for the primary account.
        var accountEnvironment: [String: String]
        var runID: UUID
        /// Nook's workspace bridge (terminal, browser, pull requests) as an MCP server; nil leaves the agent as it is.
        var bridge: BridgeLaunch? = nil
        /// Claude Code knows `--thinking-display`: ask for summarized thinking, so newer models show it.
        var thinkingDisplay = false
        /// Claude Code's `ENABLE_TOOL_SEARCH` as Nook sets it (`ClaudeToolSearch`); nil leaves yours.
        var toolSearch: String? = nil
        /// The token suggestions you applied to Nook's sessions (Settings › Sessions › Tokens).
        var tuning = AgentTuning.Applied()
        /// The reasoning effort, sent the way the agent takes it at launch (`ProviderCapabilities.effort`,
        /// `effortArguments`); nil leaves the agent's own default.
        var effort: String? = nil
        /// The speed tier (`SpeedTiers`): Claude Code's fast mode in its settings, Codex's `service_tier`; nil is standard.
        var speedTier: String? = nil
        /// Claude Code's Ultracode (`Ultracode`): nil leaves your own setting.
        var ultracode: Bool? = nil
        /// An ACP agent you added: its command, run by `executable` (your login shell).
        var customAgent: CustomAgent? = nil
        /// Settings › Agents: no agent credits in commits and pull requests (`AgentCredits.commitsKey`).
        var omitAgentCredits = AgentCredits.omitsFromCommits
    }

    static func spec(_ input: Input) -> LaunchSpec {
        var environment = input.accountEnvironment
        environment["NOOK_RUN_ID"] = input.runID.uuidString
        environment.merge(SudoAskpass.launchEnvironment()) { _, new in new }
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
                // Newer models leave their thinking empty unless summaries are asked for; with Settings › Agents also no
                // Co-Authored-By trailer or "Generated with" line in commits and pull requests.
                "--settings", AgentCredits.claudeSettings(omit: input.omitAgentCredits,
                                                          env: input.toolSearch.map { ["ENABLE_TOOL_SEARCH": $0] } ?? [:],
                                                          extra: input.tuning.claudeSettings
                                                              .merging(SpeedTiers.claudeSettings(tier: input.speedTier)) { $1 }
                                                              .merging(Ultracode.claudeSettings(input.ultracode)) { $1 })
            ]
            if input.thinkingDisplay { arguments += ["--thinking-display", "summarized"] }
            if !input.model.isEmpty { arguments += ["--model", input.model] }
            arguments += effortArguments(input.provider, effort: input.effort)
            if let resume = input.resumeSessionID, !resume.isEmpty {
                arguments += ["--resume", resume]
                if input.forkSession { arguments.append("--fork-session") }
                if let at = input.resumeAt, !at.isEmpty { arguments += ["--resume-session-at", at] }
            }
            if let bridge = input.bridge { arguments += bridge.claudeArguments(runID: input.runID) }
            let instructions = AgentCredits.launchInstructions(input.instructions, bridgeNote: input.bridge?.note,
                                                               omit: input.omitAgentCredits)
            if !instructions.isEmpty { arguments += ["--append-system-prompt", instructions] }
            return LaunchSpec(executable: input.executable, arguments: arguments, extraEnvironment: environment,
                              workingDirectory: input.workingDirectory,
                              initialInput: [ClaudeStreamParser.userMessage(input.prompt)], keepsInputOpen: true)

        case .codex:
            var arguments = ["exec", "--json", "--skip-git-repo-check",
                             "--sandbox", codexSandbox(mode: input.mode, permission: input.permission),
                             "--cd", input.workingDirectory]
            if !input.model.isEmpty { arguments += ["--model", input.model] }
            // Detailed reasoning summaries: the timeline shows how Codex thinks, not only what it did.
            arguments += ["-c", "model_reasoning_summary=\"detailed\""]
            arguments += effortArguments(input.provider, effort: input.effort)
            arguments += SpeedTiers.codexExecArguments(tier: input.speedTier)
            if let bridge = input.bridge { arguments += bridge.codexArguments(runID: input.runID) }
            var prompt = input.prompt
            let instructions = AgentCredits.launchInstructions(input.instructions, bridgeNote: input.bridge?.note,
                                                               omit: input.omitAgentCredits)
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
            let instructions = AgentCredits.launchInstructions(input.instructions, bridgeNote: nil, omit: input.omitAgentCredits)
            // No separate system prompt in headless mode: instructions go before the first prompt, like Codex.
            if !instructions.isEmpty, input.resumeSessionID == nil { prompt = instructions + "\n\n" + prompt }
            // One argument with "=", so a prompt starting with a dash is never parsed as a flag.
            arguments.append("--prompt=" + prompt)
            return LaunchSpec(executable: input.executable, arguments: arguments, extraEnvironment: environment,
                              workingDirectory: input.workingDirectory, initialInput: [], keepsInputOpen: false)

        case .pi:
            return piSpec(input, environment: environment)

        case .opencode, .cursor, .grok, .antigravity, .acp:
            return acpSpec(input)
        }
    }

    /// Pi in RPC mode, one process per turn: it resumes the conversation from its session file, loads Nook's extension
    /// (approvals and the workspace bridge) and starts with the turn's commands on stdin (`PiRPC.turnInput`).
    static func piSpec(_ input: Input, environment base: [String: String]) -> LaunchSpec {
        var environment = base
        var arguments = ["--mode", "rpc"]
        if let resume = input.resumeSessionID, !resume.isEmpty { arguments += ["--session", resume] }
        if !input.model.isEmpty {
            if let model = PiRPC.splitModel(input.model) {
                arguments += ["--provider", model.provider, "--model", model.modelID]
            } else {
                arguments += ["--model", input.model]
            }
        }
        if let effort = input.effort, PiRPC.thinkingLevels.contains(effort) { arguments += effortArguments(input.provider, effort: effort) }
        let instructions = AgentCredits.launchInstructions(input.instructions, bridgeNote: input.bridge?.note, omit: input.omitAgentCredits)
        if !instructions.isEmpty { arguments += ["--append-system-prompt", instructions] }
        arguments += ["--extension", PiExtension.fileURL.path]
        environment[PiExtension.permissionVariable] = PiExtension.permissionValue(input.permission)
        if let bridge = input.bridge {
            environment.merge(bridge.environment(runID: input.runID)) { _, new in new }
            environment[PiExtension.bridgeVariable] = bridge.script
        }
        return LaunchSpec(executable: input.executable, arguments: arguments, extraEnvironment: environment,
                          workingDirectory: input.workingDirectory, initialInput: PiRPC.turnInput(for: input.prompt),
                          keepsInputOpen: true)
    }

    /// The launch arguments that carry a session's reasoning effort, the way its agent takes it (`EffortDelivery`). Empty
    /// without a level, for an agent that takes it over its session (ACP), and for a level that is not a plain word: a
    /// config override is parsed as TOML by Codex, so nothing else may reach it.
    static func effortArguments(_ provider: RunProvider, effort: String?) -> [String] {
        guard let effort, !effort.isEmpty else { return [] }
        switch provider.capabilities.effort {
        case .launchFlag(let flag):
            return [flag, effort]
        case .launchConfig(let key):
            let plain = effort.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            return plain && effort.allSatisfy(\.isASCII) ? ["-c", "\(key)=\"\(effort)\""] : []
        case .sessionOption:
            return []
        }
    }

    /// The ACP server command of an agent that only runs over ACP (see AcpAgent).
    static func acpSpec(_ input: Input) -> LaunchSpec {
        var environment = input.accountEnvironment
        environment["NOOK_RUN_ID"] = input.runID.uuidString
        environment.merge(SudoAskpass.launchEnvironment()) { _, new in new }
        // An ACP agent you added: your login shell runs its command line, so npx, uvx, nvm and asdf work as in Terminal.
        if input.provider == .acp, let agent = input.customAgent {
            environment.merge(agent.environment) { _, new in new }
            return LaunchSpec(executable: input.executable, arguments: ["-ilc", agent.shellLine], extraEnvironment: environment,
                              workingDirectory: input.workingDirectory, initialInput: [], keepsInputOpen: true)
        }
        return LaunchSpec(executable: input.executable, arguments: AcpLaunch.arguments(input.provider, permission: input.permission),
                          extraEnvironment: environment, workingDirectory: input.workingDirectory, initialInput: [],
                          keepsInputOpen: true)
    }

    static func geminiApprovalMode(mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "plan" }
        switch permission {
        case .ask: return "default"
        // Gemini CLI has no reviewer mode (`ProviderCapabilities` does not offer "auto"); an old setting edits only.
        case .acceptEdits, .auto: return "auto_edit"
        case .bypass: return "yolo"
        }
    }

    static func claudePermissionMode(mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "plan" }
        switch permission {
        case .ask: return "default"
        case .acceptEdits: return "acceptEdits"
        case .auto: return "auto"
        case .bypass: return "bypassPermissions"
        }
    }

    static func codexSandbox(mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "read-only" }
        switch permission {
        case .ask: return "read-only"
        // `codex exec` asks nobody, so a reviewer has nothing to review: "auto" keeps the workspace sandbox.
        case .acceptEdits, .auto: return "workspace-write"
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

    /// How far behind your own work an agent runs (a Unix nice value). An agent and everything it starts (compilers, test
    /// runs, dev servers) inherit it, so a few agents that build at once take the cores that are left over instead of the
    /// ones the windows, typing and Nook himself need. On an idle Mac it changes nothing: nice only counts when there is
    /// more work than cores. Several agents compiling at full priority once drove the load to 185 on 14 cores and froze
    /// the Mac and Nook with it.
    static let backgroundPriority: Int32 = 10
    static let niceTool = "/usr/bin/nice"

    /// The command that starts `executable` behind your own work: through `nice`, which replaces itself with the agent
    /// (same pid, so its process group and stop work as before). Unchanged where `nice` is missing.
    static func behindForeground(executable: String, arguments: [String],
                                 niceAvailable: Bool = FileManager.default.isExecutableFile(atPath: niceTool)) -> (executable: String, arguments: [String]) {
        guard niceAvailable else { return (executable, arguments) }
        return (niceTool, ["-n", String(backgroundPriority), executable] + arguments)
    }
}

/// A single running agent process. Delivers stdout lines one by one on a dedicated queue.
/// It runs in a process group of its own (see `SpawnedProcess`), so stopping it also stops what it started.
/// Termination is always safe: graceful first (SIGINT), then forced after a few seconds.
/// The process sits behind `ProviderTransport`, so tests replay a recorded agent through the same line handling.
final class AgentProcess: @unchecked Sendable {
    let spec: LaunchSpec
    private let process: ProviderTransport
    private let scheduler: ProcessScheduler
    /// What went over stdio, when Settings › Workspace asks for it (see `ProviderTrafficLog`).
    let trafficLog: ProviderTrafficLog?
    private let queue = DispatchQueue(label: "nook.agent-process")
    private var buffer = Data()
    private var stderrTail = Data()
    private let lock = NSLock()
    private var finished = false
    private var stopping = false

    /// Every complete line from stdout.
    var onLine: (@Sendable (String) -> Void)?
    /// Batch of complete lines from a single stdout read chunk.
    var onLines: (@Sendable ([String]) -> Void)?
    /// The process has exited: exit code and the last lines of stderr.
    var onExit: (@Sendable (Int32, String) -> Void)?

    init(spec: LaunchSpec, transport: ProviderTransport? = nil, scheduler: ProcessScheduler = DispatchProcessScheduler(),
         trafficLog: ProviderTrafficLog? = nil) {
        self.spec = spec
        self.process = transport ?? spec.keeper.map {
            KeptTransport(folder: URL(fileURLWithPath: $0.folder), script: $0.script, offset: $0.offset)
        } ?? SpawnedProcess()
        consumed = spec.keeper?.offset ?? 0
        handled = consumed
        self.scheduler = scheduler
        self.trafficLog = trafficLog ?? ProviderTrafficLog.forLaunch(spec)
    }

    /// Stdout bytes taken as complete lines so far; on the output queue. Inside `onLines` it says where that batch ends.
    private(set) var consumed: UInt64 = 0
    /// Where the batch of lines handed to `onLines` (or `onLine`) starts; on the output queue, as `consumed`.
    private(set) var batchStart: UInt64 = 0
    private var handled: UInt64 = 0
    /// Where the output being handled now starts (`beginHandling`): a request it raises is read again from here.
    private var handlingFrom: UInt64 = 0
    /// Set while a request raised by the output waits for you (`holdForRequest`): progress is not written past it.
    private var hold: UInt64?
    private var progressWritten: Date?
    private var progressSoon = false
    /// The output Nook has really handled: where another Nook goes on.
    var handledOffset: UInt64 { lock.withLock { handled } }
    /// How far a Nook that crashed now could say the output was handled (`KeptRuns.durableOffset`).
    var durableOffset: UInt64 { lock.withLock { KeptRuns.durableOffset(handled: handled, hold: hold) } }
    var isKept: Bool { process is KeptTransport }

    /// Says where the output about to be handled starts; call on the main thread right before handling it.
    func beginHandling(from start: UInt64) { lock.withLock { handlingFrom = start } }

    /// The output up to `offset` is handled. A kept agent's progress is written into its keeper's folder now and then
    /// (`KeptRuns.Progress`), so a crash of Nook loses none of it.
    func markHandled(_ offset: UInt64) {
        let progress: KeptRuns.Progress? = lock.withLock {
            handled = max(handled, offset)
            return dueProgress(force: false)
        }
        if let progress { writeProgress(progress) }
    }

    /// The output being handled raised a request (an approval, a question) that now waits for you.
    func holdForRequest() {
        lock.withLock { if hold == nil { hold = min(handlingFrom, handled) } }
    }

    /// No request waits any more: the progress moves on at once.
    func releaseHold() {
        let progress: KeptRuns.Progress? = lock.withLock {
            guard hold != nil else { return nil }
            hold = nil
            return dueProgress(force: true)
        }
        if let progress { writeProgress(progress) }
    }

    /// The progress is written with the next handled output, whenever the last write was (the end of a turn).
    func writeProgressSoon() { lock.withLock { progressSoon = true } }

    /// Call with the lock held.
    private func dueProgress(force: Bool) -> KeptRuns.Progress? {
        guard spec.keeper != nil, isKept else { return nil }
        let now = Date()
        guard KeptRuns.shouldWriteProgress(now: now, lastWritten: progressWritten, force: force || progressSoon) else { return nil }
        progressWritten = now
        progressSoon = false
        return KeptRuns.Progress(offset: KeptRuns.durableOffset(handled: handled, hold: hold), savedAt: now)
    }

    /// One queue for every kept agent: the writes are tiny, and in order.
    private static let progressQueue = DispatchQueue(label: "nook.kept-progress", qos: .utility)

    private func writeProgress(_ progress: KeptRuns.Progress) {
        guard let folder = spec.keeper?.folder else { return }
        Self.progressQueue.async { KeptRuns.writeProgress(progress, folder: URL(fileURLWithPath: folder)) }
    }

    /// Nook goes and the agent stays: only for an agent with a keeper. It reports no exit after this.
    func detach() {
        onExit = nil
        LiveAgentProcesses.shared.untrack(self)
        (process as? KeptTransport)?.detach()
    }

    var pid: Int32 { process.pid }
    var isRunning: Bool { process.isRunning }

    func start(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // Nook is quitting: nothing new starts that the quit would then have to wait for.
        guard !LiveAgentProcesses.shared.quitting else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED)) }
        var environment = AgentCommand.environment(base: baseEnvironment, executable: spec.executable, extra: spec.extraEnvironment)
        for key in spec.removedEnvironment where spec.extraEnvironment[key] == nil { environment[key] = nil }
        // Behind your own work, with everything it starts (`AgentCommand.backgroundPriority`).
        let command = AgentCommand.behindForeground(executable: spec.executable, arguments: spec.arguments)
        let options = SpawnedProcess.Options(executable: command.executable, arguments: command.arguments, environment: environment,
                                             workingDirectory: spec.workingDirectory, keepsInputOpen: spec.keepsInputOpen)
        // SIGPIPE would terminate Nook if the agent exits while writing.
        signal(SIGPIPE, SIG_IGN)
        try process.start(options, onStdout: { [weak self] data in
            guard let self else { return }
            if data.isEmpty {
                self.queue.async { self.flushRemainder() }
            } else {
                self.queue.async { self.consume(data) }
            }
        }, onStderr: { [weak self] data in
            guard let self, !data.isEmpty else { return }
            self.queue.async {
                self.trafficLog?.stderr(String(decoding: data, as: UTF8.self))
                self.stderrTail.append(data)
                if self.stderrTail.count > 8_192 { self.stderrTail = self.stderrTail.suffix(8_192) }
            }
        }, onExit: { [weak self] status in
            guard let self else { return }
            // Wait briefly so remaining stdout lines are processed first.
            self.scheduler.schedule(after: 0.3) {
                self.queue.async {
                    self.flushRemainder()
                    self.trafficLog?.exit(status)
                    let tail = String(decoding: self.stderrTail, as: UTF8.self)
                    LiveAgentProcesses.shared.remove(self)
                    LiveAgentProcesses.shared.untrack(self)
                    self.markFinished()
                    self.onExit?(status, tail)
                }
            }
        })
        // A kept agent outlives Nook on purpose; every other one is stopped and waited for when Nook quits.
        if !isKept { LiveAgentProcesses.shared.add(self) }
        LiveAgentProcesses.shared.track(self)
        for line in spec.initialInput { send(line) }
    }

    /// Writes a line to stdin (a message, an answer to a permission prompt).
    func send(_ line: String) {
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done, let data = line.data(using: .utf8) else { return }
        trafficLog?.outbound(line)
        do {
            try process.write(data)
        } catch {
            // The process has already exited; termination is reported via onExit.
        }
    }

    /// Closes stdin: the agent wraps up and exits.
    func closeInput() {
        trafficLog?.closedInput()
        process.closeInput()
    }

    /// Graceful stop of the agent and everything in its group: SIGINT, SIGTERM after `grace` seconds, SIGKILL four
    /// seconds later. The group is signalled even when the agent itself already exited, so what it started goes too.
    /// Called with the agent's pid right before it is stopped: the app lets the commands it paused go on first
    /// (`AgentGovernor`), so they hear the stop instead of holding still.
    nonisolated(unsafe) static var beforeStop: (@Sendable (Int32) -> Void)?

    func stop(grace: TimeInterval = 4) {
        lock.lock()
        let first = !stopping
        stopping = true
        lock.unlock()
        guard first, process.isRunning else { return }
        Self.beforeStop?(pid)
        // The keeper sees it through, also when Nook quits right after this.
        if let kept = process as? KeptTransport {
            trafficLog?.signal(SIGINT)
            kept.stopForGood()
            return
        }
        // An exited leader stays unreaped until the last signal, so its group id cannot be given to another program.
        process.hold()
        trafficLog?.signal(SIGINT)
        process.signalGroup(SIGINT)
        let process = process
        scheduler.schedule(after: grace) {
            process.signalGroup(SIGTERM)
        }
        scheduler.schedule(after: grace + 4) {
            process.signalGroup(SIGKILL)
            process.release()
        }
    }

    // MARK: Quit

    /// Nook quits: SIGINT to the group unless a stop is already under way (a second interrupt makes some agents leave
    /// without saving), and the group stays signallable until Nook is gone. `QuitShutdown` escalates from here.
    func beginQuit() {
        lock.lock()
        let first = !stopping
        stopping = true
        lock.unlock()
        guard !isKept else { return }
        process.hold()
        guard first else { return }
        trafficLog?.signal(SIGINT)
        process.signalGroup(SIGINT)
    }

    /// Whether the agent or anything it started still runs.
    var groupIsAlive: Bool { process.groupIsAlive }

    /// SIGTERM or SIGKILL to the whole group, for `QuitShutdown`.
    func signalQuit(_ signal: Int32) {
        trafficLog?.signal(signal)
        process.signalGroup(signal)
    }

    /// The quit's wait is over: the leader may be reaped.
    func endQuit() {
        guard !isKept else { return }
        process.release()
    }

    private func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
        process.closeInput()
    }

    private func consume(_ data: Data) {
        // What is left in the buffer holds no newline, so only the new bytes need searching for the first one; the
        // consumed lines are dropped in one go at the end. Removing each line on its own shifted the rest of the buffer
        // every time, and rescanning a long line from its start for every chunk made both quadratic in the output size.
        var from = buffer.endIndex
        buffer.append(data)
        var start = buffer.startIndex
        var batch: [String] = []
        while let newline = buffer[from...].firstIndex(of: 0x0A) {
            let lineData = buffer[start..<newline]
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { batch.append(line) }
            start = newline + 1
            from = start
        }
        batchStart = consumed
        consumed += UInt64(buffer.distance(from: buffer.startIndex, to: start))
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        guard !batch.isEmpty else { return }
        if let trafficLog { for line in batch { trafficLog.inbound(line) } }
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
        trafficLog?.inbound(line)
        if let onLines {
            onLines([line])
        } else {
            onLine?(line)
        }
    }
}
