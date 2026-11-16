import Foundation

// What waits on you survives a restart of Nook (`RestartRequests`): questions come back answerable as a message,
// approvals say they expired, and queued messages stay queued. The same for every agent: it is built on the shared
// `questions`, `approvals` and `queued`, which every agent's handler fills.
extension WorkspaceManager {
    /// The most of an approval's summary kept for the note after a restart.
    private static let savedApprovalLength = 200

    /// The session list as it is written: with what waits on each session now.
    func durableRuns(_ snapshot: [WorkspaceRun]) -> [WorkspaceRun] {
        var asked: [UUID: [SavedQuestion]] = [:]
        for (id, list) in questions {
            let saved = list.compactMap(\.saved)
            if !saved.isEmpty { asked[id] = saved }
        }
        var waiting: [UUID: [String]] = [:]
        for (id, list) in approvals where !list.isEmpty {
            waiting[id] = list.map { pending in
                ToolSummary.oneLine([pending.tool, pending.summary].filter { !$0.isEmpty }.joined(separator: ": "),
                                    Self.savedApprovalLength)
            }
        }
        return RestartRequests.merged(snapshot, questions: asked, approvals: waiting, queues: queued)
    }

    /// A question or approval came or went: the list is saved with it, and a kept agent's output is not marked read past
    /// the request until it is answered (`KeptRuns.durableOffset`).
    func waitingChanged<Value>(_ now: Dictionary<UUID, Value>.Keys, _ before: Dictionary<UUID, Value>.Keys) {
        guard runsLoaded else { return }
        scheduleSave()
        for id in Set(now).union(before) { syncKeptHold(id) }
    }

    /// Puts back what waited on each session when Nook stopped. A kept agent that is still running asks again by itself
    /// (its output is read again from before the request), so only its queue comes back.
    func restoreWaiting(_ saved: [UUID: RestartRequests.Saved]) {
        for (id, entry) in saved {
            guard let run = run(id) else { continue }
            if var queue = entry.queue, queued[id] == nil {
                // A session still at work (a kept agent) sends it when its turn ends, as before the restart.
                if run.status.isActive { queue.resume() }
                setQueue(id, queue)
            }
            guard run.kept == nil else { continue }
            restoreRequests(id, questions: entry.questions, approvals: entry.approvals)
        }
    }

    /// The questions come back to be answered as a message; each approval leaves a note that it expired.
    func restoreRequests(_ id: UUID, questions saved: [SavedQuestion], approvals summaries: [String]) {
        let known = Set((questions[id] ?? []).map(\.id))
        let restored = saved.filter { !known.contains($0.id) }.map { PendingQuestion(restoring: $0, runID: id) }
        if !restored.isEmpty { questions[id, default: []].append(contentsOf: restored) }
        for summary in summaries {
            append(id, RunEvent(kind: .system, text: tr("ws.event.approvalExpiredRestart", summary), tool: "restart"))
        }
    }

    /// Leaves a question that nothing waits for (asked before a restart, or while the agent went on) unanswered.
    func dismissQuestion(_ runID: UUID, questionID: String) {
        guard let question = questions[runID]?.first(where: { $0.id == questionID }), question.answersAsMessage else { return }
        questions[runID]?.removeAll { $0.id == questionID }
        if questions[runID]?.isEmpty == true { questions[runID] = nil }
    }
}

// Restarting a session's agent: its process ends, and the next message starts it again in the same conversation, so
// skills, plugins and MCP servers added since are picked up. The decision is in `AgentRestart`.
extension WorkspaceManager {
    /// Only between turns: a running turn would be cut off (stop it first).
    func canRestartAgent(_ id: UUID) -> Bool {
        canTransfer(id)
    }

    /// Ends the agent's process for this session. Its conversation goes on with the next message: resumed by the agent
    /// itself where it can, otherwise from a summary of the timeline. Claude Code is started again right away (warm),
    /// the others with your next message.
    @discardableResult
    func restartAgent(_ id: UUID) -> Bool {
        guard canRestartAgent(id), let run = run(id) else { return false }
        let plan = AgentRestart.plan(hasConversation: run.providerSessionID != nil, canResume: canResumeNatively(id, run))
        closeClaudeProcess(id)
        closeCodexServer(id)
        closeAcpClient(id)
        closeOpenCodeSession(id)
        switch plan {
        case .fresh:
            append(id, RunEvent(kind: .system, text: tr("ws.event.restarted", run.provider.displayName)))
        case .resume:
            append(id, RunEvent(kind: .system, text: tr("ws.event.restartedResume", run.provider.displayName)))
        case .summary:
            // The agent cannot load its conversation again: a new one starts from what happened so far.
            update(id) { $0.providerSessionID = nil }
            append(id, RunEvent(kind: .system, text: tr("ws.event.restartedSummary", run.provider.displayName)))
            carryOverConversation(id, prompt: nil)
        }
        prewarm(id)
        return true
    }

    /// Whether this session's agent can resume its conversation once its process is gone. An ACP agent says so in its
    /// `initialize` answer, known while it runs; before that Nook does not know (nil).
    private func canResumeNatively(_ id: UUID, _ run: WorkspaceRun) -> Bool? {
        switch run.provider {
        case .claude, .codex, .pi:
            return AgentRestart.resumesNatively(run.provider)
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp:
            // OpenCode's own server reads a session back by its id.
            if openCodeLinks[id]?.sessionID != nil { return true }
            // Its capabilities are in once a session is open on it.
            guard let client = acpClients[id], client.isRunning, client.sessionID != nil else {
                return AgentRestart.resumesNatively(run.provider)
            }
            return client.sessionCapabilities.continues
        }
    }
}
