import Foundation

// A new conversation in the same session: the agent's process ends and its next turn starts without the earlier
// conversation, while the timeline keeps everything. The same for every agent.
//
// - `/clear` (typed, or picked from the `/` list, on the Mac or the phone) does not clear at once: it arms the session, and
//   your next message starts the new conversation. The strip above the composer says so and takes it back
//   ("Keep this conversation"). Armed while the agent works, that message waits in line marked fresh and goes after the
//   turn; it is never taken into the running turn.
// - A scheduled task set to "fresh conversation each run" starts one before its prompt, so a session that gets a run every
//   hour stays readable without the agent's context growing.
// - When a turn fails because the agent lost its conversation or the conversation no longer fits its context, Nook starts a
//   new one by itself: the timeline so far goes ahead of the same message as a summary (`ContextHandoff`), once.

extension WorkspaceManager {
    /// Only between turns; false when the session is busy or gone (quietly: a scheduled run then waits for the turn and
    /// starts the new conversation itself). `reason` goes in the timeline as a system line after the divider.
    @discardableResult
    func startFreshConversation(_ id: UUID, reason: String) -> Bool {
        guard canTransfer(id), clearConversation(id, quietly: true) else { return false }
        append(id, RunEvent(kind: .system, text: reason))
        return true
    }

    // MARK: /clear

    /// `/clear`: your next message in this session starts a new conversation.
    func armFreshConversation(_ id: UUID) {
        guard run(id) != nil else { return }
        freshArmed.insert(id)
    }

    /// "Keep this conversation": `/clear` is taken back before a message went.
    func keepConversation(_ id: UUID) {
        freshArmed.remove(id)
    }

    /// Whether this message of yours starts a new conversation: `/clear` itself, or any message after it. Such a message
    /// goes through `submit`, never into a running turn.
    func startsFreshConversation(_ id: UUID, text: String) -> Bool {
        freshArmed.contains(id) || FreshConversation.isCommand(text)
    }

    /// True once per `/clear`: the message being sent takes it.
    func takeFreshArm(_ id: UUID) -> Bool {
        freshArmed.remove(id) != nil
    }

    // MARK: Recovery

    /// The failure of the turn that just ended is one a new conversation fixes, and it was not that second try already.
    /// A second try that fails again is told as it is (and the next failure may try again).
    func conversationRecovery(_ id: UUID, error: String?) -> FreshConversation.Recovery? {
        guard recoveringConversation.remove(id) == nil else { return nil }
        guard let error, let run = run(id), run.providerSessionID != nil, run.canContinue, turnPrompts[id] != nil else { return nil }
        return FreshConversation.recovery(for: error)
    }

    /// Starts a new conversation with the agent and sends the turn's words again, with the timeline so far ahead of them.
    func recoverConversation(_ id: UUID, _ recovery: FreshConversation.Recovery) {
        guard let run = run(id), let prompt = turnPrompts[id] else { return }
        recoveringConversation.insert(id)
        // The agent's open process still holds the conversation that failed.
        closeClaudeProcess(id)
        closeCodexServer(id)
        closeAcpClient(id)
        forkNext.remove(id)
        update(id) {
            $0.providerSessionID = nil
            $0.pendingHandoff = nil
            $0.usage.contextTokens = nil
        }
        let key = recovery == .full ? "ws.fresh.recoveredFull" : "ws.fresh.recoveredGone"
        append(id, RunEvent(kind: .system, text: tr("ws.event.cleared"), tool: "clear"))
        append(id, RunEvent(kind: .system, text: tr(key, run.provider.displayName)))
        let carried = carryOverConversation(id, prompt: prompt) ?? prompt
        if !sendHidden(id, text: carried) { recoveringConversation.remove(id) }
    }
}
