import Foundation

// Forking a session and switching it to another agent. See `ContextTransfer`.

extension WorkspaceManager {
    func shownPrompt(_ id: UUID, _ prompt: String) -> String { displayPrompt[id] ?? prompt }

    /// Your message as the timeline shows it: without the context envelope, with the files and folders you attached as
    /// paths below your words (tiles above the bubble). A remote session's files are not on this Mac: they stay `@name`.
    func shownMessage(_ id: UUID, _ message: String) -> String {
        guard let run = run(id), !run.isRemote else { return ContextRefs.visible(message) }
        return ContextRefs.timeline(message, folder: run.workingDirectory)
    }

    /// Can this session be forked or switched right now? Not while the agent works: its conversation is still changing.
    func canTransfer(_ id: UUID) -> Bool {
        guard let run = run(id) else { return false }
        return !run.status.isActive && !checkpointing.contains(id)
    }

    // MARK: Switch

    /// Moves the session to another agent. The old agent's conversation is kept; switching back resumes it and hands over
    /// only what it missed. Everything the new agent starts from is shown in the timeline. A wait for the old account's
    /// usage limit ends here; with `resumeIfLimited` a session that limit stopped goes on at once on the new one.
    @discardableResult
    func switchProvider(_ id: UUID, to provider: RunProvider, profileID: String, model: String = "",
                        resumeIfLimited: Bool = false) -> Bool {
        guard canTransfer(id), let run = run(id), executable(provider) != nil,
              ProviderInstance.key(run.provider, run.profileID) != ProviderInstance.key(provider, profileID) else { return false }
        loadTimeline(id)
        let events = timeline(id)
        let before = switchEndpoint(run)

        var sessions = run.providerSessions ?? [:]
        var cursors = run.handoffCursors ?? [:]
        let leaving = ProviderInstance.key(run.provider, run.profileID)
        let arriving = ProviderInstance.key(provider, profileID)
        // A conversation still waiting for its first turn as a copy (`--fork-session`) is not this session's own yet:
        // switching back starts from a summary instead of writing to the original.
        if let session = run.providerSessionID, !forkNext.contains(id) { sessions[leaving] = session }
        // The agent we leave has taken part in everything so far.
        cursors[leaving] = events.count

        let nativeSession = sessions[arriving]
        let strategy = ContextTransfer.forSwitch(hasNativeSession: nativeSession != nil, cursor: cursors[arriving])
        var handoff: ContextHandoff.Rendered?
        switch strategy {
        case .native: break
        case .fullSummary: handoff = ContextHandoff.render(events: events, source: run.provider.displayName, session: bridge(for: id) == nil ? nil : id)
        case .delta(let since):
            handoff = ContextHandoff.render(events: events, from: since, source: run.provider.displayName, session: bridge(for: id) == nil ? nil : id)
        }

        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        let previous = run.provider
        let accountOnly = previous == provider
        update(id) {
            $0.provider = provider
            // A goal lives in the agent's own conversation.
            $0.goal = nil
            $0.profileID = profileID
            $0.model = model
            $0.resolvedModel = nil
            $0.providerSessionID = nativeSession
            $0.providerSessions = sessions
            $0.handoffCursors = cursors
            $0.pendingHandoff = handoff?.text
            // Another agent's conversation: what Nook followed of the old one does not apply to it.
            $0.conversation = nil
            $0.pendingRollback = nil
            $0.permission = $0.permission.steppedDown(within: provider.capabilities.policies)
        }
        forkNext.remove(id)
        if let now = self.run(id) {
            // "⇄ Context handoff  Claude Code Sonnet 5.5 → Codex GPT-5": a divider with both agents and their models; to
            // another account of the same agent, each logo carries its account's badge (as).
            var change = ModelSwitch(from: before, to: switchEndpoint(now))
            if accountOnly { change.accountHandoff = true }
            var event = RunEvent(kind: .system, text: accountOnly ? ModelSwitchText.plain(change)
                                     : tr("ws.event.switched", previous.displayName, provider.displayName),
                                 tool: "switch")
            event.change = change
            append(id, event)
        }
        if let handoff { appendHandoffNote(id, handoff) }
        // The limit belonged to the old account: its banner and its "Resume at reset" do not apply to the new one.
        let limited = run.limitedAt != nil
        clearUsageLimit(id)
        if limited && resumeIfLimited {
            append(id, RunEvent(kind: .system, text: tr("ws.limit.resumingSwitched")))
            send(id, text: UsageLimits.resumeMessage)
        }
        return true
    }

    /// The agent does not know this conversation (it is gone from the agent, or the agent cannot load it): it starts a new
    /// one with the timeline so far as a summary, as a switch to another agent does. With `prompt` (a message on its way)
    /// the summary goes ahead of it and that is returned; without, it waits for the next message (`pendingHandoff`).
    @discardableResult
    func carryOverConversation(_ id: UUID, prompt: String?) -> String? {
        guard let run = run(id) else { return prompt }
        loadTimeline(id)
        var events = timeline(id)
        // The message on its way is already in the timeline: it goes once, after the summary.
        if prompt != nil, let last = events.lastIndex(where: { $0.kind == .user }) { events = Array(events[..<last]) }
        guard let handoff = ContextHandoff.render(events: events, source: run.provider.displayName,
                                                  session: bridge(for: id) == nil ? nil : id) else { return prompt }
        appendHandoffNote(id, handoff)
        guard let prompt else {
            update(id) { $0.pendingHandoff = handoff.text }
            return nil
        }
        return ContextHandoff.compose(handoff: handoff.text, message: prompt)
    }

    func appendHandoffNote(_ id: UUID, _ handoff: ContextHandoff.Rendered) {
        append(id, RunEvent(kind: .system, text: tr("ws.event.handoff", handoff.included, handoff.omitted),
                            tool: "handoff", detail: handoff.text))
    }

    // MARK: How much the timeline shows

    /// This session's own choice of how much of the work its timeline shows; nil follows Settings.
    func setTimelineDetail(_ id: UUID, _ detail: TimelineDetail?) {
        guard run(id)?.timelineDetail != detail else { return }
        update(id) { $0.timelineDetail = detail }
    }

    // MARK: Clear

    /// `/clear`: the session goes on in a new, empty conversation with the same agent, in the same folder and on the same
    /// branch. The agent forgets everything so far (every agent's conversation in this session, a summary waiting for
    /// the next turn, and how far each agent had followed the timeline); the timeline stays, with a divider where the
    /// new conversation starts. Not while the agent works: its conversation is still changing.
    @discardableResult
    func clearConversation(_ id: UUID) -> Bool {
        guard run(id) != nil else { return false }
        guard canTransfer(id) else {
            append(id, RunEvent(kind: .system, text: tr("ws.clear.busy")))
            return false
        }
        loadTimeline(id)
        closeCodexServer(id)
        closeClaudeProcess(id)
        closeAcpClient(id)
        forkNext.remove(id)
        append(id, RunEvent(kind: .system, text: tr("ws.event.cleared"), tool: "clear"))
        // What came before the divider is no agent's to pick up: a switch to another agent later hands over only what
        // follows it.
        let now = timeline(id).count
        update(id) { run in
            run.providerSessionID = nil
            run.providerSessions = nil
            run.handoffCursors = run.handoffCursors.map { $0.mapValues { _ in now } }
                ?? [ProviderInstance.key(run.provider, run.profileID): now]
            run.pendingHandoff = nil
            run.pendingRollback = nil
            run.conversation = nil
            run.goal = nil
            run.tasks = nil
            run.promptCache = nil
            run.usage.contextTokens = nil
        }
        scheduleSave()
        return true
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
        var copy = branchCopy(of: source, id: newID, title: tr("ws.fork.title", source.title),
                              lineage: RunLineage(kind: .fork, parentID: id, atEvent: events.count))

        var handoff: ContextHandoff.Rendered?
        switch strategy {
        case .native:
            // The first turn resumes the conversation as a copy (`--fork-session`), so the original is never written to twice.
            forkNext.insert(newID)
        case .fullSummary, .delta:
            copy.providerSessionID = nil
            handoff = ContextHandoff.render(events: events, source: source.provider.displayName,
                                            session: bridge(for: source.id) == nil ? nil : source.id)
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

    /// A new session that starts from `source` in the same folder, with nothing of its own yet: a fork or a side chat.
    /// It never owns a worktree, so removing it cannot take the original's.
    func branchCopy(of source: WorkspaceRun, id newID: UUID, title: String, lineage: RunLineage) -> WorkspaceRun {
        let now = Date()
        var copy = source
        copy.id = newID
        copy.title = title
        copy.status = .completed
        copy.statusDetail = nil
        copy.createdAt = now
        copy.updatedAt = now
        copy.archived = false
        copy.usage = RunUsage()
        copy.turnStartedAt = nil
        copy.reviewedAt = nil
        copy.checkpoints = nil
        copy.conversation = nil
        copy.pendingRollback = nil
        copy.limitedAt = nil
        copy.limitResetAt = nil
        copy.autoResume = nil
        copy.continuations = nil
        copy.snoozedAt = nil
        copy.snoozedUntil = nil
        copy.delegation = nil
        // A goal lives in the agent's own conversation; only a native fork takes that along.
        if !forkNext.contains(newID) { copy.goal = nil }
        copy.isolation = .folder
        copy.worktreePath = nil
        copy.baseBranch = nil
        copy.providerSessions = nil
        copy.handoffCursors = nil
        copy.pendingHandoff = nil
        copy.lineage = lineage
        return copy
    }

    // MARK: One choice for agent, account and model

    /// What you picked in the agent menu of a session: a model from the next turn on, or another account or agent with a
    /// summary of what happened. Returns what it came to, so the menu can say why nothing changed.
    @discardableResult
    func applySelection(_ id: UUID, provider: RunProvider, profileID: String, model: String,
                        resumeIfLimited: Bool = false) -> SelectionTransition {
        guard let run = run(id) else { return .reject("busy") }
        // "Auto" keeps the model in use (none on another agent) and lets the next turn pick (see `applyAutoModel`); any
        // other model is your own choice again.
        let auto = model.trimmingCharacters(in: .whitespacesAndNewlines) == AutoModel.id
        let model = auto ? (provider == run.provider ? run.model : "") : model
        if (run.autoModel == true) != auto { update(id) { $0.autoModel = auto ? true : nil } }
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
            let before = switchEndpoint(run)
            update(id) {
                $0.profileID = profileID
                $0.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if run.model != model { $0.resolvedModel = nil }
            }
            // Another account sharing this one's folder, or another model: marked in the timeline from the next turn.
            noteModelSwitch(id, from: before)
            refreshWarmSession(id)
        case .createWithHandoff:
            if !switchProvider(id, to: provider, profileID: profileID, model: model, resumeIfLimited: resumeIfLimited) {
                return .reject("unavailable")
            }
        }
        return transition
    }

    // MARK: Merge back

    /// Sends what a fork or a side chat found out to the session it came from, as one message: the summary of its
    /// timeline since the point where it split off. The parent takes it up as soon as it is idle.
    @discardableResult
    func mergeBack(_ id: UUID) -> Bool {
        guard canTransfer(id), let fork = run(id), let lineage = fork.lineage, lineage.bringsBack,
              let parent = run(lineage.parentID), !parent.archived else { return false }
        loadTimeline(id)
        let side = lineage.kind == .side
        let what = side ? "side chat" : "fork"
        guard let handoff = ContextHandoff.render(
            events: timeline(id), from: lineage.atEvent, source: fork.title,
            header: "[Result of a \(what)] This is what the \(what) \"\(fork.title)\" of this session did since it split off (oldest first):",
            footer: "[End of the \(what)'s result] Take over what is useful; check the files yourself before relying on it."
        ) else { return false }
        append(parent.id, RunEvent(kind: .system, text: tr(side ? "ws.event.sideBroughtBackParent" : "ws.event.mergedBackParent", fork.title)))
        if parent.canContinue, processes[parent.id] == nil, !checkpointing.contains(parent.id) {
            send(parent.id, text: handoff.text)
        } else {
            enqueue(parent.id, text: handoff.text)
        }
        append(id, RunEvent(kind: .system, text: tr(side ? "ws.event.sideBroughtBack" : "ws.event.mergedBack", parent.title)))
        return true
    }
}
