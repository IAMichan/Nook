import Foundation

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
        case .claude, .codex:
            return AgentRestart.resumesNatively(run.provider)
        case .gemini, .opencode, .cursor, .grok, .antigravity, .acp:
            // Its capabilities are in once a session is open on it.
            guard let client = acpClients[id], client.isRunning, client.sessionID != nil else {
                return AgentRestart.resumesNatively(run.provider)
            }
            return client.sessionCapabilities.continues
        }
    }
}
