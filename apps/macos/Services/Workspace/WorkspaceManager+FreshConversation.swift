import Foundation

// A new conversation in the same session: the agent's process ends and its next turn starts without the earlier
// conversation, while the timeline keeps everything. Used by a scheduled task set to "fresh conversation each run", so a
// session that gets a run every hour stays readable without the agent's context growing. The same for every agent: each
// one starts a new conversation when the session has no conversation id of its own.

extension WorkspaceManager {
    /// Only between turns; false when the session is busy or gone. `reason` goes in the timeline as a system line.
    @discardableResult
    func startFreshConversation(_ id: UUID, reason: String) -> Bool {
        guard let run = run(id), !run.status.isActive else { return false }
        closeClaudeProcess(id)
        closeCodexServer(id)
        closeAcpClient(id)
        update(id) {
            $0.providerSessionID = nil
            $0.conversation = ConversationLog(provider: $0.provider)
            $0.pendingHandoff = nil
        }
        append(id, RunEvent(kind: .system, text: reason))
        return true
    }
}
