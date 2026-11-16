import Foundation

// Side chats (`/btw`, `/side`): a question beside a session's work, in a session of its own that starts from the
// parent's last finished turn while the parent keeps running. The decisions are in `SideChat`.

extension WorkspaceManager {
    /// Whether a side chat can start from this session now. Unlike a fork, also while the agent works: the side chat
    /// takes only what its finished turns hold. Not from a side chat itself: its question goes in that side chat.
    func canOpenSideChat(_ id: UUID) -> Bool {
        guard let run = run(id), !run.archived else { return false }
        return run.lineage?.kind != .side
    }

    /// Opens a side chat beside `parentID` and selects it. Claude Code copies its own conversation (up to the last
    /// finished turn while one runs); any other agent starts from a summary of the timeline up to there. Its first turn
    /// asks before every change. With a question, that goes out as its first message.
    @discardableResult
    func openSideChat(_ parentID: UUID, question: String) -> UUID? {
        guard canOpenSideChat(parentID), let parent = run(parentID) else { return nil }
        loadTimeline(parentID)
        let all = timeline(parentID)
        let running = parent.status.isActive
        let cutoff = SideChat.cutoff(events: all, turnRunning: running)
        let events = Array(all.prefix(cutoff))
        let start = SideChat.start(provider: parent.provider, session: parent.providerSessionID, turnRunning: running,
                                   lastFinished: parent.checkpoints?.last?.conversation, forksNatively: forksNatively(parent))

        let newID = UUID()
        var side = branchCopy(of: parent, id: newID, title: tr("ws.side.title", parent.title),
                              lineage: RunLineage(kind: .side, parentID: parentID, atEvent: events.count))
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { side.task = clean }
        // The parent's pull request watch and task list stay the parent's.
        side.prWatch = nil
        side.tasks = nil
        side.goal = nil
        // A side chat asks before it changes anything, whatever the parent may do; you can raise it afterwards.
        let offered = parent.provider.capabilities.policies
        side.permission = offered.contains(.ask) ? .ask : (offered.first ?? .ask)
        var handoff: ContextHandoff.Rendered?
        switch start {
        case .nativeCopy:
            // The first turn resumes the conversation as a copy (`--fork-session`): the parent's is never written to.
            forkNext.insert(newID)
        case .nativeCopyAt(let session, let head):
            // A copy that ends where the last finished turn ended (`--resume-session-at`), as going back does.
            side.providerSessionID = session
            side.pendingRollback = PendingRollback(resumeSession: session, resumeAt: head)
            forkNext.insert(newID)
        case .summary:
            side.providerSessionID = nil
            handoff = ContextHandoff.render(events: events, source: parent.provider.displayName)
            side.pendingHandoff = handoff?.text
        }
        runs.insert(side, at: 0)
        self.events[newID] = events
        selectedRunID = newID
        append(newID, RunEvent(kind: .system, text: tr(start == .summary ? "ws.event.sideSummary" : "ws.event.sideNative", parent.title)))
        if let handoff { appendHandoffNote(newID, handoff) }
        scheduleSave()
        if !clean.isEmpty { send(newID, text: clean) }
        return newID
    }
}
