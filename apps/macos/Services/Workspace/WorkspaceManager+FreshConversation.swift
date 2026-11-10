import Foundation

// A new conversation in the same session: the agent's process ends and its next turn starts without the earlier
// conversation, while the timeline keeps everything. Used by a scheduled task set to "fresh conversation each run", so a
// session that gets a run every hour stays readable without the agent's context growing. The same for every agent and
// the same as `/clear` (`clearConversation`), with the reason added to the timeline.

extension WorkspaceManager {
    /// Only between turns; false when the session is busy or gone (quietly: a scheduled run then continues the
    /// conversation). `reason` goes in the timeline as a system line after the divider.
    @discardableResult
    func startFreshConversation(_ id: UUID, reason: String) -> Bool {
        guard canTransfer(id), clearConversation(id) else { return false }
        append(id, RunEvent(kind: .system, text: reason))
        return true
    }
}
