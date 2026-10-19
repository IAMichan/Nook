import Foundation

// Forking a session and switching it to another agent. See `ContextTransfer`.

extension WorkspaceManager {
    func shownPrompt(_ id: UUID, _ prompt: String) -> String { displayPrompt[id] ?? prompt }

    /// Can this session be forked or switched right now? Not while the agent works: its conversation is still changing.
    func canTransfer(_ id: UUID) -> Bool {
        guard let run = run(id) else { return false }
        return !run.status.isActive && !checkpointing.contains(id)
    }

    // MARK: Switch

    /// Moves the session to another agent. The old agent's conversation is kept; switching back resumes it and hands over
    /// only what it missed. Everything the new agent starts from is shown in the timeline.
    @discardableResult
    func switchProvider(_ id: UUID, to provider: RunProvider, profileID: String, model: String = "") -> Bool {
        guard canTransfer(id), let run = run(id), executable(provider) != nil,
              ProviderInstance.key(run.provider, run.profileID) != ProviderInstance.key(provider, profileID) else { return false }
        loadTimeline(id)
        let events = timeline(id)

        var sessions = run.providerSessions ?? [:]
        var cursors = run.handoffCursors ?? [:]
        let leaving = ProviderInstance.key(run.provider, run.profileID)
        let arriving = ProviderInstance.key(provider, profileID)
        if let session = run.providerSessionID { sessions[leaving] = session }
        // The agent we leave has taken part in everything so far.
        cursors[leaving] = events.count

        let nativeSession = sessions[arriving]
        let strategy = ContextTransfer.forSwitch(hasNativeSession: nativeSession != nil, cursor: cursors[arriving])
        var handoff: ContextHandoff.Rendered?
        switch strategy {
        case .native: break
        case .fullSummary: handoff = ContextHandoff.render(events: events, source: run.provider.displayName)
        case .delta(let since): handoff = ContextHandoff.render(events: events, from: since, source: run.provider.displayName)
        }

        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        let previous = run.provider
        let accountOnly = previous == provider
        update(id) {
            $0.provider = provider
            $0.profileID = profileID
            $0.model = model
            $0.resolvedModel = nil
            $0.providerSessionID = nativeSession
            $0.providerSessions = sessions
            $0.handoffCursors = cursors
            $0.pendingHandoff = handoff?.text
            if !provider.capabilities.policies.contains($0.permission) { $0.permission = settings.permission(for: provider) }
        }
        forkNext.remove(id)
        append(id, RunEvent(kind: .system, text: accountOnly ? tr("ws.event.switchedAccount", provider.displayName)
                                                              : tr("ws.event.switched", previous.displayName, provider.displayName)))
        if let handoff { appendHandoffNote(id, handoff) }
        return true
    }

    private func appendHandoffNote(_ id: UUID, _ handoff: ContextHandoff.Rendered) {
        append(id, RunEvent(kind: .system, text: tr("ws.event.handoff", handoff.included, handoff.omitted),
                            tool: "handoff", detail: handoff.text))
    }

    // MARK: Fork

    /// A new session that starts from this one: Claude Code forks its own conversation; any other agent starts from a
    /// summary. It works in the same folder (a fork never owns a worktree, so removing it cannot take the original's).
    @discardableResult
    func fork(_ id: UUID, keepingEvents keep: Int? = nil) -> UUID? {
        guard canTransfer(id), let source = run(id) else { return nil }
        loadTimeline(id)
        let all = timeline(id)
        // A fork from an earlier point keeps only the timeline up to there; the agent's own fork would copy the whole
        // conversation, so such a fork always starts from a summary.
        let partial = keep.map { $0 < all.count } ?? false
        let events = keep.map { Array(all.prefix(max(0, $0))) } ?? all
        let nativeFork = source.provider.capabilities.nativeFork && !partial
        let strategy = ContextTransfer.forFork(nativeFork: nativeFork, hasNativeSession: source.providerSessionID != nil)

        let newID = UUID()
        let now = Date()
        var copy = source
        copy.id = newID
        copy.title = tr("ws.fork.title", source.title)
        copy.status = .completed
        copy.statusDetail = nil
        copy.createdAt = now
        copy.updatedAt = now
        copy.archived = false
        copy.usage = RunUsage()
        copy.turnStartedAt = nil
        copy.reviewedAt = nil
        copy.checkpoints = nil
        copy.limitedAt = nil
        copy.limitResetAt = nil
        copy.autoResume = nil
        copy.continuations = nil
        copy.snoozedAt = nil
        copy.snoozedUntil = nil
        copy.delegation = nil
        copy.isolation = .folder
        copy.worktreePath = nil
        copy.baseBranch = nil
        copy.providerSessions = nil
        copy.handoffCursors = nil
        copy.pendingHandoff = nil
        copy.lineage = RunLineage(kind: .fork, parentID: id, atEvent: events.count)

        var handoff: ContextHandoff.Rendered?
        switch strategy {
        case .native:
            // The first turn resumes the conversation as a copy (`--fork-session`), so the original is never written to twice.
            forkNext.insert(newID)
        case .fullSummary, .delta:
            copy.providerSessionID = nil
            handoff = ContextHandoff.render(events: events, source: source.provider.displayName)
            copy.pendingHandoff = handoff?.text
        }
        runs.insert(copy, at: 0)
        self.events[newID] = events
        selectedRunID = newID
        append(newID, RunEvent(kind: .system, text: tr(strategy == .native ? "ws.event.forkedNative" : "ws.event.forkedSummary", source.title)))
        if let handoff { appendHandoffNote(newID, handoff) }
        scheduleSave()
        return newID
    }

    // MARK: One choice for agent, account and model

    /// What you picked in the agent menu of a session: a model from the next turn on, or another account or agent with a
    /// summary of what happened. Returns what it came to, so the menu can say why nothing changed.
    @discardableResult
    func applySelection(_ id: UUID, provider: RunProvider, profileID: String, model: String) -> SelectionTransition {
        guard let run = run(id) else { return .reject("busy") }
        // While a turn runs only the model changes (see `configure`); another agent or account waits until it is idle.
        if !canTransfer(id) {
            guard provider == run.provider, profileID == run.profileID else { return .reject("busy") }
            let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean != run.model else { return .reuse }
            configure(id, model: clean)
            update(id) { $0.resolvedModel = nil }
            return .applyOnNextTurn
        }
        let transition = SelectionTransition.decide(
            currentProvider: run.provider, currentProfile: run.profileID, currentModel: run.model,
            targetProvider: provider, targetProfile: profileID, targetModel: model,
            sameAccountHome: accountHome(run.profileID) == accountHome(profileID), available: executable(provider) != nil)
        switch transition {
        case .reuse, .reject: break
        case .applyOnNextTurn:
            update(id) {
                $0.profileID = profileID
                $0.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if run.model != model { $0.resolvedModel = nil }
            }
        case .createWithHandoff:
            if !switchProvider(id, to: provider, profileID: profileID, model: model) { return .reject("unavailable") }
        }
        return transition
    }

    // MARK: Merge back

    /// Sends what a fork found out to the session it came from, as one message: the summary of the
    /// fork's timeline since the point where it split off. The parent takes it up as soon as it is idle.
    @discardableResult
    func mergeBack(_ id: UUID) -> Bool {
        guard canTransfer(id), let fork = run(id), let lineage = fork.lineage,
              let parent = run(lineage.parentID), !parent.archived else { return false }
        loadTimeline(id)
        guard let handoff = ContextHandoff.render(
            events: timeline(id), from: lineage.atEvent, source: fork.title,
            header: "[Result of a fork] This is what the fork \"\(fork.title)\" of this session did since it split off (oldest first):",
            footer: "[End of the fork's result] Take over what is useful; check the files yourself before relying on it."
        ) else { return false }
        append(parent.id, RunEvent(kind: .system, text: tr("ws.event.mergedBackParent", fork.title)))
        if parent.canContinue, processes[parent.id] == nil, !checkpointing.contains(parent.id) {
            send(parent.id, text: handoff.text)
        } else {
            enqueue(parent.id, text: handoff.text)
        }
        append(id, RunEvent(kind: .system, text: tr("ws.event.mergedBack", parent.title)))
        return true
    }
}
