import Foundation

/// Claude Code kept alive between turns: after a turn the process waits on stdin, and the next
/// message goes straight to it, warm cache and all. A change of model, mode or rights (they are command-line flags),
/// a copy of the conversation, or ten quiet minutes start a fresh process that resumes the conversation instead.
extension WorkspaceManager {
    private static let claudeIdleSeconds: UInt64 = 30 * 60

    /// The flags a Claude Code process was started with; a process is reused only with the same ones.
    func claudeKey(_ run: WorkspaceRun) -> String {
        [run.model, run.mode.rawValue, run.permission.rawValue, run.instructions, bridgeLaunch() == nil ? "" : "bridge"]
            .joined(separator: "|")
    }

    /// After a turn: the process waits for the next message. A stopped turn closes it.
    func parkClaudeProcess(_ id: UUID, stopping: Bool) {
        guard let process = processes[id] else { return }
        processes[id] = nil
        guard !stopping, process.isRunning, let run = run(id) else {
            process.closeInput()
            return
        }
        closeClaudeProcess(id)
        claudeIdle[id] = (process, claudeKey(run))
        claudeIdleClose[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.claudeIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.closeClaudeProcess(id)
        }
        sendQueued(id)
    }

    /// Sends the next message to the waiting process. False when there is none, or it was started with other settings.
    func continueClaudeProcess(_ id: UUID, prompt: String, showPrompt: Bool) -> Bool {
        guard var run = run(id), let idle = claudeIdle[id] else { return false }
        guard idle.process.isRunning, idle.key == claudeKey(run), !forkNext.contains(id) else {
            closeClaudeProcess(id)
            return false
        }
        claudeIdleClose[id]?.cancel()
        claudeIdleClose[id] = nil
        claudeIdle[id] = nil
        processes[id] = idle.process
        turns[id] = TurnState()
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)
        idle.process.send(ClaudeStreamParser.userMessage(prompt))
        return true
    }

    /// A process started ahead of your first message (see `prewarm`): it waits like one parked after a turn.
    func parkWarmClaude(_ id: UUID, _ process: AgentProcess, key: String) {
        closeClaudeProcess(id)
        claudeIdle[id] = (process, key)
        claudeIdleClose[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.claudeIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.closeClaudeProcess(id)
        }
    }

    func closeClaudeProcess(_ id: UUID) {
        claudeIdleClose[id]?.cancel()
        claudeIdleClose[id] = nil
        guard let idle = claudeIdle.removeValue(forKey: id) else { return }
        idle.process.closeInput()
        idle.process.stop(grace: 2)
    }

    /// Asks this Claude Code once whether it knows `--thinking-display`; until the answer is in, sessions start without it.
    func probeClaudeFlags(_ executable: String) {
        claudeThinkingDisplay[executable] = false
        Task { [weak self] in
            let known = await Task.detached(priority: .utility) {
                let environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: executable, extra: [:])
                return (try? ProcessRunner.run(executable, ["--help"], environment: environment, timeout: 15))?.stdout.contains("--thinking-display") == true
            }.value
            self?.claudeThinkingDisplay[executable] = known
        }
    }
}
