import Foundation

/// Claude Code kept alive between turns: after a turn the process waits on stdin, and the next
/// message goes straight to it, warm cache and all. A change of model, mode or rights (they are command-line flags),
/// a copy of the conversation, or ten quiet minutes start a fresh process that resumes the conversation instead.
extension WorkspaceManager {
    private static let claudeIdleSeconds: UInt64 = 10 * 60

    /// The flags a Claude Code process was started with; a process is reused only with the same ones.
    func claudeKey(_ run: WorkspaceRun) -> String {
        [run.model, run.mode.rawValue, run.permission.rawValue, launchInstructions(run), bridge(for: run.id) == nil ? "" : "bridge", run.effort ?? "", run.speedTier ?? "", ultracode(run).map { $0 ? "ultracode" : "no-ultracode" } ?? "",
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
        case .codex, .pi:
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
        wakeLine[id] = nil
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
        let line = wakeLine.removeValue(forKey: id)
        append(id, RunEvent(kind: .system, text: line ?? tr("ws.wake.background"), tool: "wake"))
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

    /// Claude Code says work it runs in the background (see `BackgroundTaskUpdate`) started or ended: a subagent, or a
    /// command (`BackgroundCommands`). Its row keeps running until then, and then settles with what it answered. The
    /// line where the agent picks up its result names it.
    func noteBackgroundTask(_ id: UUID, _ update: BackgroundTaskUpdate) {
        let line: String
        if let event = Subagents.event(for: update, in: timeline(id)) {
            defer { noteSubagentsWorking(id) }
            guard let status = update.status else {
                if event.state != .running { mutateEvent(id, event.id) { $0.state = .running } }
                return
            }
            guard event.state == .running || event.state == nil else { return }
            mutateEvent(id, event.id) { event in
                event.state = status == .completed ? .done : .failed
                if let answer = update.result ?? update.summary, !answer.isEmpty { event.output = RunEvent.clip(answer) }
            }
            line = tr("ws.wake.subagent", Subagents.list([event]).first?.title ?? event.text)
        } else if let event = BackgroundCommands.event(for: update, in: timeline(id)) {
            defer { noteSubagentsWorking(id) }
            guard let status = update.status else {
                // Its call may still be at work: its result keeps it running (see `.toolResult`).
                mutateEvent(id, event.id) { $0.background = true }
                if event.state != .running, event.output != nil { mutateEvent(id, event.id) { $0.state = .running } }
                return
            }
            guard event.state == .running || event.state == nil || event.background != true else { return }
            mutateEvent(id, event.id) { event in
                event.background = true
                event.state = status == .failed ? .failed : .done
                if let summary = update.summary, !summary.isEmpty {
                    event.output = RunEvent.clip([event.output, summary].compactMap { $0 }.joined(separator: "\n\n"))
                }
            }
            line = tr("ws.wake.command", BackgroundCommands.list([event]).first.map { ToolSummary.oneLine($0.title, 80) } ?? event.text)
        } else {
            return
        }
        // The agent woke up for it already: its line says which one; otherwise the wake to come does.
        if let wake = TimelinePresentation.lastTurn(timeline(id)).first, wake.kind == .system, wake.tool == "wake",
           wake.text == tr("ws.wake.background"), Date().timeIntervalSince(wake.date) < 30 {
            mutateEvent(id, wake.id) { $0.text = line }
        } else if processes[id] == nil {
            wakeLine[id] = line
        }
        if !BackgroundWork.pending(after: timeline(id), before: false) { backgroundWork.remove(id) }
    }

    /// Works out whether the session still has subagents or commands at work in the background. Only while its process
    /// (or Codex's app-server) lives: they end with it, and their rows may keep saying they run (after Nook restarted, say).
    func noteSubagentsWorking(_ id: UUID) {
        let process = processes[id] ?? claudeIdle[id]?.process
        let alive = process?.isRunning == true || codexServers[id] != nil
        let list = events[id] ?? []
        let working = alive && (Subagents.backgroundRunning(list) || BackgroundCommands.running(list))
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
        settleBackgroundCommands(id)
    }

    /// The process that ran the session's background commands ended, and they with it: their rows stop running.
    func settleBackgroundCommands(_ id: UUID) {
        for event in timeline(id) where event.state == .running && BackgroundCommands.isCommand(event) {
            mutateEvent(id, event.id) { $0.state = .done }
        }
        noteSubagentsWorking(id)
        releaseHeldCompletion(id)
    }

    /// A completion held for a monitor (`WakeCompletion`) whose monitor ended without waking the agent once more (its
    /// process closed, or its end came while no turn followed): the alert it held goes out now, once.
    func releaseHeldCompletion(_ id: UUID) {
        guard heldWakeCompletions.contains(id), !BackgroundCommands.monitorRunning(timeline(id)),
              let run = run(id), run.status == .completed, processes[id] == nil else { return }
        heldWakeCompletions.remove(id)
        onTurnFinished?(run)
        deliverDelegatedResult(id)
    }

    /// Asks this Claude Code once whether it knows `--thinking-display`; until the answer is in, sessions start without it.
    func probeClaudeFlags(_ executable: String) {
        claudeThinkingDisplay[executable] = false
        Task { [weak self] in
            let help = await Task.detached(priority: .utility) {
                let environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: executable, extra: [:])
                return (try? ProcessRunner.run(executable, ["--help"], environment: environment, timeout: 15))?.stdout ?? ""
            }.value
            self?.claudeThinkingDisplay[executable] = help.contains("--thinking-display")
        }
    }
}
