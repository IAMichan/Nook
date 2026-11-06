import Foundation

/// Claude Code kept alive between turns: after a turn the process waits on stdin, and the next
/// message goes straight to it, warm cache and all. A change of model, mode or rights (they are command-line flags),
/// a copy of the conversation, or ten quiet minutes start a fresh process that resumes the conversation instead.
extension WorkspaceManager {
    private static let claudeIdleSeconds: UInt64 = 10 * 60

    /// The flags a Claude Code process was started with; a process is reused only with the same ones.
    func claudeKey(_ run: WorkspaceRun) -> String {
        [run.model, run.mode.rawValue, run.permission.rawValue, run.instructions, bridge(for: run.id) == nil ? "" : "bridge", run.effort ?? "",
         AgentCredits.omitsFromCommits ? "no-credits" : ""]
            .joined(separator: "|")
    }

    /// After a turn: the process waits for the next message. A stopped turn closes it.
    func parkClaudeProcess(_ id: UUID, stopping: Bool) {
        guard let process = processes[id] else { return }
        processes[id] = nil
        // Settings changed during the turn: an empty key never matches, so the next message starts a fresh process.
        let changed = claudeChangedDuringTurn.remove(id) != nil
        guard !stopping, process.isRunning, let run = run(id) else {
            process.closeInput()
            noteSubagentsWorking(id)
            return
        }
        closeClaudeProcess(id)
        claudeIdle[id] = (process, changed ? "" : claudeKey(run))
        let seconds = idleSeconds(id, Self.claudeIdleSeconds)
        claudeIdleClose[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.closeClaudeProcess(id)
        }
        sendQueued(id)
    }

    /// Settings changed while a turn runs. An agent with `liveSettings` takes the model, mode and effort over at once:
    /// Claude Code the permission mode and the model (control requests on stdin; the rest by a fresh process after the
    /// turn), an ACP agent everything `applyAcpSettings` sets. The others read the rights live where they answer approvals
    /// in Nook, and the rest from their next turn.
    func applyLive(_ id: UUID, from old: WorkspaceRun, to new: WorkspaceRun) {
        guard new.provider.capabilities.liveSettings else { return }
        switch new.provider {
        case .claude:
            guard let process = processes[id], process.isRunning else { return }
            let oldMode = AgentCommand.claudePermissionMode(mode: old.mode, permission: old.permission)
            let newMode = AgentCommand.claudePermissionMode(mode: new.mode, permission: new.permission)
            if oldMode != newMode {
                process.send(ClaudeStreamParser.setPermissionModeRequest(id: "nook-mode-" + UUID().uuidString.prefix(8), mode: newMode))
            }
            if old.model != new.model {
                process.send(ClaudeStreamParser.setModelRequest(id: "nook-model-" + UUID().uuidString.prefix(8), model: new.model))
            }
            if oldMode != newMode || old.model != new.model || old.instructions != new.instructions || old.effort != new.effort {
                claudeChangedDuringTurn.insert(id)
            }
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp:
            guard old.model != new.model || old.mode != new.mode || old.permission != new.permission || old.effort != new.effort,
                  let client = acpClients[id], client.isRunning, client.sessionID != nil else { return }
            applyAcpSettings(id, client) {}
        case .codex:
            break
        }
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
        wakeSubagent[id] = nil
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)
        idle.process.send(ClaudeStreamParser.userMessage(prompt))
        return true
    }

    /// Work Claude Code started in the background (a command or subagent run in the background) finished after the turn,
    /// and Claude Code carries on by itself: the waiting process becomes a turn
    /// again, so what it does shows up live and ends like any other turn.
    func wakeParkedClaude(_ id: UUID) {
        guard processes[id] == nil, var run = run(id), let idle = claudeIdle[id], idle.process.isRunning else { return }
        claudeIdleClose[id]?.cancel()
        claudeIdleClose[id] = nil
        claudeIdle[id] = nil
        processes[id] = idle.process
        turns[id] = TurnState()
        let finished = wakeSubagent.removeValue(forKey: id)
        append(id, RunEvent(kind: .system, text: finished.map { tr("ws.wake.subagent", $0) } ?? tr("ws.wake.background"), tool: "wake"))
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = Date()
        replace(run)
    }

    /// A subagent's own thought, message or tool call: kept on the call that started it, for the Subagents panel.
    func noteSubagentStep(_ id: UUID, parent: String, _ step: SubagentStep) {
        guard let launch = timeline(id).last(where: { $0.callID == parent && Subagents.isLaunch($0) }) else { return }
        mutateEvent(id, launch.id) { $0.subagentSteps = SubagentStep.appending(step, to: $0.subagentSteps) }
    }

    /// Claude Code says a subagent it runs in the background started or ended (see `BackgroundTaskUpdate`): its row
    /// keeps running until then, and then settles with what it answered. The line where the agent picks up its result
    /// names it.
    func noteBackgroundSubagent(_ id: UUID, _ update: BackgroundTaskUpdate) {
        guard let event = Subagents.event(for: update, in: timeline(id)) else { return }
        defer { noteSubagentsWorking(id) }
        let title = Subagents.list([event]).first?.title ?? event.text
        guard let status = update.status else {
            if event.state != .running { mutateEvent(id, event.id) { $0.state = .running } }
            return
        }
        guard event.state == .running || event.state == nil else { return }
        mutateEvent(id, event.id) { event in
            event.state = status == .completed ? .done : .failed
            if let answer = update.result ?? update.summary, !answer.isEmpty { event.output = RunEvent.clip(answer) }
        }
        // The agent woke up for it already: its line says which one; otherwise the wake to come does.
        if let wake = TimelinePresentation.lastTurn(timeline(id)).first, wake.kind == .system, wake.tool == "wake",
           wake.text == tr("ws.wake.background"), Date().timeIntervalSince(wake.date) < 30 {
            mutateEvent(id, wake.id) { $0.text = tr("ws.wake.subagent", title) }
        } else if processes[id] == nil {
            wakeSubagent[id] = title
        }
        if !BackgroundWork.pending(after: timeline(id), before: false) { backgroundWork.remove(id) }
    }

    /// Works out whether the session still has subagents at work in the background. Only while its process lives: the
    /// subagents end with it, and their rows may keep saying they run (after Nook restarted, say).
    func noteSubagentsWorking(_ id: UUID) {
        let process = processes[id] ?? claudeIdle[id]?.process
        let working = process?.isRunning == true && Subagents.backgroundRunning(events[id] ?? [])
        guard working != subagentsWorking.contains(id) else { return }
        if working { subagentsWorking.insert(id) } else { subagentsWorking.remove(id) }
    }

    /// How long a waiting session stays open: ten minutes (each one is a process of a few hundred MB), or four hours while it has background work running
    ///, so the agent is still there to pick up the result.
    func idleSeconds(_ id: UUID, _ normal: UInt64) -> UInt64 {
        backgroundWork.contains(id) ? 4 * 60 * 60 : normal
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
        noteSubagentsWorking(id)
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
