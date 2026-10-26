import Foundation

/// Going back to before a message: the files return to the checkpoint before it, and the agent's own conversation goes
/// back with them where the agent can (`ProviderCapabilities.canRollbackConversation`). The decisions are in
/// `ConversationRollback`; this follows the conversation live and carries a rollback out with the next turn.
extension WorkspaceManager {
    // MARK: Following the conversation

    /// Where the conversation stands now, for a checkpoint.
    func conversationMark(_ run: WorkspaceRun) -> ConversationMark {
        run.conversation?.mark ?? ConversationMark(session: run.providerSessionID, provider: run.provider)
    }

    func noteConversationSession(_ id: UUID, _ session: String, keepsHistory: Bool) {
        update(id) { run in
            var log = run.conversation ?? ConversationLog(provider: run.provider)
            log.noteSession(session, provider: run.provider, keepsHistory: keepsHistory)
            run.conversation = log
        }
    }

    /// The agent continues the conversation under a new session id (a resumed Claude Code chat gets one): keep the old
    /// id, so the transcript under it is recognised as this session and does not show up as a second chat.
    func rememberEarlierSession(_ id: UUID, replacedBy session: String) {
        guard let previous = run(id)?.providerSessionID, !previous.isEmpty, previous != session else { return }
        update(id) { run in
            var log = run.conversation ?? ConversationLog(session: previous, provider: run.provider)
            var earlier = log.earlierSessions ?? []
            if !earlier.contains(previous) { earlier.append(previous) }
            log.earlierSessions = earlier
            run.conversation = log
        }
    }

    /// The conversation went on outside Nook under `session` (a resumed terminal chat): the next turn resumes that one,
    /// and the messages written there that this session does not show yet are added.
    func followContinuation(_ id: UUID, from previous: String, to session: String, messages: [AgentChatMessage]) {
        guard let run = run(id), !run.status.isActive, run.providerSessionID == previous else { return }
        loadTimeline(id)
        let known = Set((events[id] ?? []).filter { $0.kind == .user || $0.kind == .assistant }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        rememberEarlierSession(id, replacedBy: session)
        update(id) { $0.providerSessionID = session }
        noteConversationSession(id, session, keepsHistory: true)
        for message in messages where message.kind == .user || message.kind == .assistant {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !known.contains(text) else { continue }
            let kind: RunEvent.Kind = message.kind == .user ? .user : .assistant
            append(id, RunEvent(kind: kind, text: text, state: kind == .assistant ? .done : nil))
        }
    }

    func noteConversationTurn(_ id: UUID, turnID: String? = nil) {
        update(id) { run in
            var log = run.conversation ?? ConversationLog(session: run.providerSessionID, provider: run.provider)
            log.startTurn(id: turnID)
            run.conversation = log
        }
    }

    func noteConversationHead(_ id: UUID, _ uuid: String) {
        guard run(id)?.conversation?.head != uuid else { return }
        update(id) { run in
            var log = run.conversation ?? ConversationLog(session: run.providerSessionID, provider: run.provider)
            log.noteHead(uuid)
            run.conversation = log
        }
    }

    /// A turn Nook could not follow (Codex over `codex exec`): later rollbacks of this conversation are files only.
    func markConversationInexact(_ id: UUID) {
        guard run(id)?.conversation?.exact != false else { return }
        update(id) { run in
            var log = run.conversation ?? ConversationLog(session: run.providerSessionID, provider: run.provider)
            log.exact = false
            run.conversation = log
        }
    }

    // MARK: Rolling back

    /// Going back to before a message also rolls back this session's conversation: Claude Code, and Codex over app-server.
    func canRollbackConversation(_ id: UUID) -> Bool {
        guard let run = run(id), run.provider.capabilities.canRollbackConversation else { return false }
        if run.provider == .codex {
            guard settings.codexAppServer, let executable = launchExecutable(run) else { return false }
            return !codexExecOnly.contains(executable)
        }
        return true
    }

    /// After the files went back to `checkpoint` (at `index`): the conversation follows, the timeline shows what was undone,
    /// and the checkpoints past that point go. True when the conversation was rolled back too.
    func rollBackConversation(_ id: UUID, to checkpoint: RunCheckpoint, index: Int) -> Bool {
        guard let run = run(id) else { return false }
        let plan = canRollbackConversation(id)
            ? ConversationRollback.plan(provider: run.provider, mark: checkpoint.conversation, log: run.conversation,
                                        currentSession: run.providerSessionID)
            : .unavailable
        let trimmed = ConversationRollback.trim(run.checkpoints ?? [], keepingThrough: index)
        if !trimmed.removedRefs.isEmpty, let git = sessionGit(for: run) {
            let directory = run.workingDirectory
            let refs = trimmed.removedRefs
            let key = folderKey(run)
            Task { _ = try? await FolderLease.shared.run(key) { git.removeCheckpointRefs(directory, refs: refs) } }
        }
        let follows = plan != .unavailable
        if case .fresh = plan {
            // A new conversation: whatever process holds the old one goes, and the next turn starts from scratch.
            closeClaudeProcess(id)
            closeCodexServer(id)
        } else if case .claudeResume = plan {
            // The waiting Claude Code process remembers everything: the next turn resumes a copy instead.
            closeClaudeProcess(id)
        }
        update(id) { run in
            run.checkpoints = trimmed.kept
            guard follows else { return }
            run.pendingRollback = ConversationRollback.merge(run.pendingRollback, with: plan)
            if case .fresh = plan {
                run.providerSessionID = nil
                run.conversation = ConversationLog(provider: run.provider)
            } else if let mark = checkpoint.conversation {
                var log = run.conversation ?? ConversationLog(session: mark.session, provider: run.provider)
                log.rewind(to: mark)
                run.conversation = log
            }
        }
        if follows { markRolledBack(id, after: checkpoint.date) }
        return follows
    }

    /// The messages after the point you went back to show dimmed: the agent no longer remembers them.
    private func markRolledBack(_ id: UUID, after date: Date) {
        loadTimeline(id)
        guard var list = events[id] else { return }
        let ids = ConversationRollback.rolledBackIDs(list, after: date)
        guard !ids.isEmpty else { return }
        for index in list.indices where ids.contains(list[index].id) { list[index].rolledBack = true }
        events[id] = list
        scheduleEventSave(id)
    }

    /// Codex: drops the turns of a rollback from the thread before the next turn starts (`thread/rollback`, or
    /// `thread/revert` on a Codex that only knows that), then calls `next` with whether it worked.
    func applyCodexRollback(_ id: UUID, _ client: CodexAppServerClient, thread: String, next: @escaping (String?) -> Void) {
        guard let pending = run(id)?.pendingRollback, pending.threadID == thread, pending.numTurns > 0 else {
            next(nil)
            return
        }
        client.request("thread/rollback", CodexRPC.rollbackParams(threadID: thread, numTurns: pending.numTurns)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.update(id) { $0.pendingRollback = nil }
                    next(nil)
                case .failure(let error) where error.meansUnsupported && pending.beforeTurnID != nil:
                    client.request("thread/revert", CodexRPC.revertParams(threadID: thread, beforeTurnID: pending.beforeTurnID ?? "")) { [weak self] result in
                        Task { @MainActor in
                            guard let self else { return }
                            self.finishCodexRollback(id, result.failureMessage, next: next)
                        }
                    }
                case .failure(let error):
                    self.finishCodexRollback(id, error.localizedDescription, next: next)
                }
            }
        }
    }

    private func finishCodexRollback(_ id: UUID, _ failure: String?, next: (String?) -> Void) {
        update(id) { $0.pendingRollback = nil }
        // Codex still has the turns Nook already left out: its count no longer matches.
        if failure != nil { markConversationInexact(id) }
        next(failure)
    }

    /// Claude Code: the resume a waiting rollback asks for, used once by the next launch.
    func takeClaudeRollback(_ id: UUID) -> PendingRollback? {
        guard let pending = run(id)?.pendingRollback, !pending.isCodex, pending.resumeSession != nil, pending.resumeAt != nil else { return nil }
        return pending
    }

    /// A rollback that cannot go out the way this turn runs (Codex over `codex exec`): said once, then dropped.
    func dropUnusableRollback(_ id: UUID) {
        guard run(id)?.pendingRollback != nil else { return }
        update(id) { $0.pendingRollback = nil }
        markConversationInexact(id)
        append(id, RunEvent(kind: .error, text: tr("ws.revert.conversationFailed", tr("ws.revert.conversationExec"))))
    }
}

private extension Result where Failure == CodexAppServerError {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.localizedDescription }
        return nil
    }
}
