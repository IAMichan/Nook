import Foundation

/// A family that runs one agent process per turn (`AgentCommand`): Claude Code over stream-json, Pi over its RPC mode, and
/// the agents that only take a prompt as an argument (`codex exec`, Gemini CLI's headless mode). They share the launch
/// and the stop; they differ in what they say on the process's stdin.
@MainActor
protocol ProcessTurnDriver: TurnDriver {
    /// What asks the running turn to stop on stdin; nil when the process has no channel and ends on a signal.
    func interruptRequest() -> String?
    /// The answer to a permission request, written to the process's stdin. `notesReason`: the denial's reason shows in
    /// the timeline (the answer carries it to the agent).
    func answer(requestID: String, _ pending: PendingPermission, _ decision: WorkspaceManager.Decision,
                reason: String) -> (line: String, notesReason: Bool)
    /// Carries the turn on in a process still open from before (Claude Code parked between turns). `rollingBack`: the turn
    /// resumes an earlier point of the conversation, so an open process cannot take it. True when it went out there.
    func continueInProcess(_ id: UUID, prompt: String, showPrompt: Bool, rollingBack: Bool) -> Bool
}

extension ProcessTurnDriver {
    func launch(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        workspace.launchProcessTurn(id, prompt: prompt, executable: executable, showPrompt: showPrompt, driver: self)
    }

    func stop(_ id: UUID) -> Bool {
        workspace.stopProcessTurn(id, request: interruptRequest)
    }

    func decide(_ runID: UUID, requestID: String, _ decision: WorkspaceManager.Decision, reason: String) -> Bool {
        workspace.decideOverProcess(runID, requestID: requestID, decision, reason: reason, driver: self)
        return true
    }

    func prewarm(_ id: UUID, run: WorkspaceRun, executable: String) {}

    func continueInProcess(_ id: UUID, prompt: String, showPrompt: Bool, rollingBack: Bool) -> Bool { false }
}

extension WorkspaceManager {
    func launchProcessTurn(_ id: UUID, prompt: String, executable: String, showPrompt: Bool, driver: ProcessTurnDriver) {
        guard var run = run(id) else { return }
        let capabilities = run.provider.capabilities
        var rollback: PendingRollback?
        switch capabilities.rollback {
        case .threadRollback:
            // Codex over `codex exec`: Nook cannot count this turn, and a waiting rollback cannot go out.
            dropUnusableRollback(id)
            markConversationInexact(id)
        case .resumeAt:
            // A rollback of Claude Code's conversation: this turn resumes a copy at the last message that stays.
            rollback = takeClaudeRollback(id)
            noteConversationTurn(id)
        case .none:
            break
        }
        // The lines above changed the stored session; carry on with that.
        if let latest = self.run(id) { run = latest }
        if driver.continueInProcess(id, prompt: prompt, showPrompt: showPrompt, rollingBack: rollback != nil) { return }
        let input = AgentCommand.Input(
            provider: run.provider,
            executable: executable,
            prompt: prompt,
            model: run.model,
            mode: run.mode,
            permission: run.permission,
            instructions: launchInstructions(run),
            workingDirectory: run.workingDirectory,
            resumeSessionID: rollback?.resumeSession ?? run.providerSessionID,
            forkSession: forkNext.contains(id) || rollback != nil,
            resumeAt: rollback?.resumeAt,
            accountEnvironment: accountEnvironment(run.profileID),
            runID: id,
            bridge: bridge(for: id),
            thinkingDisplay: capabilities.probesLaunchFlags && claudeThinkingDisplay[executable] == true,
            toolSearch: claudeToolSearch(run),
            tuning: appliedTuning(run),
            // Each agent takes it its own way (`ProviderCapabilities.effort`); `codex exec` as a config override.
            effort: run.effort,
            speedTier: speedTier(run),
            ultracode: ultracode(run)
        )
        // The flag probe runs Claude Code on this Mac: not for a session on another machine.
        if capabilities.probesLaunchFlags, !run.isRemote, claudeThinkingDisplay[executable] == nil { probeClaudeFlags(executable) }
        let spec = placed(AgentCommand.spec(input), for: run)
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        let process = AgentProcess(spec: spec)
        turns[id] = TurnState()
        bindTurn(process, id, provider: run.provider)
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        do {
            try process.start()
        } catch {
            turns[id] = nil
            replace(run)
            update(id) { $0.move(to: .failed, detail: tr("ws.error.launch", error.localizedDescription)) }
            append(id, RunEvent(kind: .error, text: tr("ws.error.launch", error.localizedDescription)))
            return
        }
        processes[id] = process
        if forkNext.remove(id) != nil { forkLaunched.insert(id) } else { forkLaunched.remove(id) }
        if rollback != nil { run.pendingRollback = nil }
        run.move(to: .running)
        run.turnStartedAt = turnStart(id)
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)
        append(id, RunEvent(kind: .system, text: spec.displayCommand, tool: "launch"))
    }

    /// Stops the turn's process. False when the session runs none.
    func stopProcessTurn(_ id: UUID, request makeRequest: () -> String?) -> Bool {
        guard let process = processes[id] else { return false }
        // Pressing Stop again changes nothing: the first one is still on its way.
        if turns[id]?.stopping == true { return true }
        turns[id]?.stopping = true
        // An agent that listens on stdin is asked to stop its turn; if it never answers, its input closes and then the
        // process ends. Without a channel the process ends right away.
        if let request = makeRequest() {
            process.send(request)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.processes[id] === process else { return }
                process.closeInput()
                process.stop()
            }
        } else {
            process.stop()
        }
        expireApprovals(id)
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopping")))
        return true
    }

    func decideOverProcess(_ runID: UUID, requestID: String, _ decision: Decision, reason: String, driver: ProcessTurnDriver) {
        guard let pending = approvals[runID]?.first(where: { $0.id == requestID }), let process = processes[runID] else {
            expireApproval(runID, requestID: requestID)
            return
        }
        let answer = driver.answer(requestID: requestID, pending, decision, reason: reason)
        process.send(answer.line)
        approvals[runID]?.removeAll { $0.id == requestID }
        recap?.decision(allowed: decision != .deny)
        mutateEvent(runID, pending.eventID) { $0.state = decision == .deny ? .denied : .allowed }
        if (approvals[runID]?.isEmpty ?? true), !waitsOnQuestion(runID) { update(runID) { $0.move(to: .running) } }
        onApprovalGone?(requestID)
        if answer.notesReason, !reason.isEmpty { append(runID, RunEvent(kind: .system, text: tr("ws.approval.deniedBecause", reason))) }
    }

    /// A turn's process tells this session what it writes and when it ends.
    func bindTurn(_ process: AgentProcess, _ id: UUID, provider: RunProvider) {
        process.onLines = { [weak self, weak process] lines in
            let end = process?.consumed ?? 0
            // Parsed here, on the process's own queue: the main thread only applies the events.
            let parsed = ParsedStreamLine.parse(lines, provider: provider)
            Task { @MainActor in
                guard let self else { return }
                for line in parsed { self.handle(parsed: line, for: id) }
                process?.markHandled(end)
            }
        }
        let token = ObjectIdentifier(process)
        process.onExit = { [weak self] status, stderr in
            Task { @MainActor in self?.processExited(id, status: status, stderr: stderr, process: token) }
        }
    }

    // MARK: Agent Output

    /// Applies one parsed line of a session's output (parsed off the main thread, `ParsedStreamLine`).
    func handle(parsed: ParsedStreamLine, for id: UUID) {
        guard run(id) != nil else { return }
        switch parsed {
        case .claude(let events):
            if processes[id] == nil, claudeIdle[id] != nil, events.contains(where: ClaudeStreamEvent.isWork) { wakeParkedClaude(id) }
            for event in events { handleClaude(event, id: id) }
        case .codex(let events):
            for event in events { handleCodex(event, id: id) }
        case .gemini(let events):
            for event in events { handleGemini(event, id: id) }
        case .pi(let events):
            for event in events { handlePi(event, id: id) }
        case .none:
            break // ACP sessions read their own messages (WorkspaceManager+Acp).
        }
    }

    /// `process` identifies the process that ended (not the process itself: it may be gone by the time this runs).
    func processExited(_ id: UUID, status: Int32, stderr: String, process: ObjectIdentifier? = nil) {
        // Quitting: `shutdown()` already settled every session; an exit now must not send queued messages or start a turn.
        guard !quitting else { return }
        // A Claude Code process that waited between turns ended (closed when idle, or gone): nothing else to do.
        if let process, let idle = claudeIdle[id]?.process, ObjectIdentifier(idle) == process {
            claudeIdle[id] = nil
            // Subagents it ran in the background ended with it.
            settleOpenWork(id, reason: .processExited)
            noteSubagentsWorking(id)
            return
        }
        // A process this session no longer runs: one closed on the way out (a switch to another agent or account, a
        // stop, `/clear`). Its end must not end the turn that runs now, which may not even be a process (an ACP agent,
        // Codex's server): that turn failed with "The agent stopped unexpectedly (code 0)".
        if let process, processes[id].map(ObjectIdentifier.init) != process { return }
        processes[id] = nil
        // A question can no longer be answered once the process is gone.
        questions[id] = nil
        pauseLive(id)
        let state = turns[id]
        turns[id] = nil
        expireApprovals(id)
        // Whatever was still running is settled: nothing may stay open after the process is gone.
        settleOpenWork(id, reason: state?.stopping == true ? .stopped : .processExited)
        noteSubagentsWorking(id)
        guard let state, !state.finished else {
            scheduleGitRefresh(id, delay: 0.2)
            sendQueued(id)
            return
        }
        if state.stopping {
            update(id) { $0.move(to: .stopped) }
            append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
            scheduleGitRefresh(id, delay: 0.2)
            sendPendingNow(id)
            return
        } else {
            let detail = Self.cleanError(state.lastError ?? stderr, status: status)
            update(id) { $0.move(to: .failed, detail: detail) }
            append(id, RunEvent(kind: .error, text: detail))
            noteFailure(id, text: state.lastError ?? stderr)
            turnDidFinish(id)
        }
        scheduleGitRefresh(id, delay: 0.2)
    }
}
