import Foundation

// The rows of the Agents list, worked out from the sessions Nook runs, the ones it only sees and the earlier ones. Moved
// out of `AgentsTab`, so the auto-settle rules and the pull request sync (`SessionTidier`) see the same rows while no list
// is on screen: the main window closed, the notch off, or another tab open.

/// The list's rows: what works or waits, the earlier sessions, and the conversations that are busy (which cannot
/// stay marked as finished). Worked out by `AgentsTab` for what it draws, and by `SessionTidier` while no list is on screen.
struct AgentListEntries {
    let running: [AgentListItem]
    let earlier: [AgentListItem]
    let busyKeys: Set<String>
    /// The sub-threads that live inside their parent's view instead of as rows (`SubThreadListing`), each with the
    /// row that stands in for it while it is open.
    var standIn: [String: String] = [:]

    /// The row for `id`: its own, or for a sub-thread its nearest listed ancestor's.
    func rowID(_ id: String) -> String { standIn[id] ?? id }
}


@MainActor
extension AppModel {
    /// The running and earlier sessions the list builds its rows from, as `AgentsTab` picks them: a process Nook only sees
    /// when its conversation can be read, earlier sessions of connected accounts only, at most sixty of them.
    func agentListSources() -> (live: [AgentSession], past: [PastSession], transcripts: [String: PastSession]) {
        let lists: (transcripts: [String: PastSession], past: [PastSession]) = demoMode
            ? (transcripts: [:], past: []) : detectedTranscriptsAndPast()
        let live = agentSessions.filter { demoMode || !$0.isDetected || lists.transcripts[$0.id] != nil }
        let connected = Set(profiles.all.filter(isConnected).map(\.id))
        let past = demoMode ? [] : Array(lists.past.lazy
            .filter { self.profile(for: $0).map { connected.contains($0.id) } ?? false }.prefix(60))
        return (live, past, lists.transcripts)
    }

    /// The list's rows; `selected` is the open session, which never reads as unseen.
    func agentListEntries(live: [AgentSession], past: [PastSession], transcripts: [String: PastSession],
                          selected: String) -> AgentListEntries {
        AgentListBuilder(app: self, selected: selected).entries(live: live, past: past, transcripts: transcripts)
    }

    /// All of it at once, for work that runs without the list (`SessionTidier`).
    func agentListEntries(selected: String) -> AgentListEntries {
        let sources = agentListSources()
        return agentListEntries(live: sources.live, past: sources.past, transcripts: sources.transcripts, selected: selected)
    }
}

@MainActor
private struct AgentListBuilder {
    let app: AppModel
    let selected: String

    func entries(live: [AgentSession], past: [PastSession], transcripts: [String: PastSession]) -> AgentListEntries {
        let runs = app.demoMode ? [] : WorkspaceRunsSection.recent(app.workspace)
        // How many models each first session of a comparison has: counted once, not once per run.
        var comparisons: [UUID: Int] = [:]
        for run in app.workspace.runs where run.lineage?.kind == .comparison {
            if let parent = run.lineage?.parentID { comparisons[parent, default: 0] += 1 }
        }
        let all = runs.map { item($0, comparisons: comparisons) } + live.map { item($0, transcript: transcripts[$0.id]) }
        let busyKeys = Set(all.filter(\.isBusy).map(\.finishKey))
        let (built, standIn) = Self.subThreadsUnderParents(all, runs: app.workspace.runs)
        let earlier = past.map { item($0) }.filter { !busyKeys.contains($0.finishKey) }
        return AgentListEntries(running: sorted(built), earlier: earlier, busyKeys: busyKeys, standIn: standIn)
    }

    /// The list stays flat. A delegated task or side chat has no row while its parent has one (the parent's
    /// Lineage control lists it); the parent's row stands in for it while it is open, and shows the approval it waits for,
    /// and for a side chat its question too. A fork or a comparison keeps a row of its own, at the same level.
    private static func subThreadsUnderParents(_ items: [AgentListItem], runs: [WorkspaceRun])
        -> (items: [AgentListItem], standIn: [String: String]) {
        var links: [String: SubThreadLink] = [:]
        for run in runs {
            guard let parent = run.parentRunID, let relation = run.subThreadRelation else { continue }
            links["run:" + run.id.uuidString] = SubThreadLink(parent: "run:" + parent.uuidString, relation: relation)
        }
        let hidden = SubThreadListing.hidden(links, listed: Set(items.map(\.id)))
        var open: [String: SubThreadRequest] = [:]
        for item in items where links[item.id] != nil {
            if item.status == .waiting { open[item.id] = .approval } else if item.status == .input { open[item.id] = .question }
        }
        let flagged = SubThreadListing.requests(links, open: open)
        let shown = items.filter { !hidden.contains($0.id) }.map { item -> AgentListItem in
            var item = item
            // Flat: no row sits under another one.
            item.parentID = nil
            switch flagged[item.id] {
            case .approval?: item.status = .waiting
            case .question? where item.status != .waiting: item.status = .input
            default: break
            }
            return item
        }
        var standIn: [String: String] = [:]
        for id in hidden { standIn[id] = SubThreadListing.rowID(for: id, links: links, hidden: hidden) }
        return (shown, standIn)
    }

    /// Waiting for you first, then working, then the rest; newest first within each.
    private func sorted(_ items: [AgentListItem]) -> [AgentListItem] {
        func rank(_ status: AgentListItem.Status) -> Int {
            switch status {
            case .waiting: return 0
            case .input: return 1
            case .failed: return 2
            case .limited: return 3
            case .working: return 4
            case .idle: return 5
            case .finished: return 6
            }
        }
        return items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.status), rank(b.element.status))
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func account(_ profile: AgentProfile?) -> AccountTag? {
        AccountTag.badge(profile, app: app)
    }

    private func accountName(_ profile: AgentProfile?) -> String {
        guard !app.demoMode, let profile else { return "" }
        return AccountLabel.name(profile, app: app)
    }

    private func item(_ run: WorkspaceRun, comparisons: [UUID: Int]) -> AgentListItem {
        // One answer to "what does this need from you" (approval, question, limit, snooze), shared with the notch.
        let attention = app.workspace.attention(run, unseen: unseen("run:" + run.id.uuidString, run.updatedAt),
                                                includeSnooze: false)
        let status: AgentListItem.Status
        switch attention {
        case .approval: status = .waiting
        case .input: status = .input
        case .failed: status = .failed
        case .limited: status = .limited
        case .working: status = .working
        case .ready, .idle: status = .idle
        case .finished: status = .finished
        }
        return AgentListItem(
            id: "run:" + run.id.uuidString,
            folder: run.projectName,
            title: run.title,
            branch: run.branch ?? (run.isRemote ? nil : GitHead.branch(for: run.workingDirectory)),
            agent: run.provider.displayName,
            account: account(app.profile(for: run)),
            status: status,
            // Working also covers subagents that outlive their turn: the badge counts on from the turn that started them.
            started: attention == .working ? (run.turnStartedAt ?? run.createdAt) : run.updatedAt,
            path: run.workingDirectory,
            finishKey: FinishedSessions.key(run: run),
            unseen: attention == .ready,
            snoozedUntil: run.snoozedUntil,
            snoozedAt: run.snoozedAt,
            limitedAt: run.limitedAt,
            limitResetAt: run.limitResetAt,
            machine: run.remote?.name ?? MachineName.local,
            machineID: run.remote?.machineID,
            model: run.resolvedModel ?? run.model,
            accountName: accountName(app.profile(for: run)),
            // A session Nook delegated to or forked from another one, or a later model of a comparison.
            parentID: (run.delegation?.parentID ?? run.lineage?.parentID).map { "run:" + $0.uuidString },
            firstPrompt: run.task,
            comparison: comparisons[run.id] ?? 0,
            forked: run.lineage?.kind == .fork,
            worktree: run.isolation == .worktree || run.worktreePath != nil,
            linesAdded: run.changedLinesAdded ?? 0,
            linesRemoved: run.changedLinesRemoved ?? 0,
            changedFiles: run.changedFiles,
            // Its own turn ended while sub-threads it delegated still work: busy through them.
            subThreadsWorking: run.status == .completed && attention == .working ? app.workspace.workingSubThreads(of: run.id) : 0,
            otherProjects: projectNames(run.otherProjects ?? [], own: run.projectPath)
        )
    }

    private func item(_ session: AgentSession, transcript: PastSession?) -> AgentListItem {
        let status: AgentListItem.Status
        if session.approvalID != nil || session.status == .waiting {
            status = .waiting
        } else {
            switch session.status {
            case .running: status = .working
            case .failed: status = .failed
            // Compacting between turns (your /compact): it works, though no turn runs.
            default: status = session.compactingSince != nil ? .working : .idle
            }
        }
        let conversation = app.conversationID(for: session)
        let known = transcript ?? conversation.flatMap { id in app.history.sessions.first { $0.isConversation(id) } }
        let named = AgentFormat.sessionTitle(session, known: known)
        let title = named.isEmpty ? session.project : named
        let branch = known.flatMap { $0.branch.isEmpty ? nil : $0.branch } ?? GitHead.branch(for: session.cwd)
        return AgentListItem(
            id: session.id,
            folder: session.project,
            title: title,
            branch: branch,
            agent: session.name,
            account: account(app.profile(for: session)),
            status: status,
            // Busy: how long this turn runs, not how long ago the session started.
            started: status == .idle ? (session.updated ?? session.started ?? known?.started)
                : (session.turnStarted ?? session.compactingSince ?? session.started ?? known?.started),
            path: session.cwd,
            finishKey: FinishedSessions.key(session: session),
            unseen: session.status == .done && unseen(session.id, session.updated),
            machine: MachineName.local,
            model: known?.model ?? "",
            accountName: accountName(app.profile(for: session)),
            firstPrompt: known?.firstPrompt ?? "",
            spawnedTasks: known?.spawnedTasks ?? [],
            worktree: GitHead.isWorktree(session.cwd),
            linesAdded: session.linesAdded,
            linesRemoved: session.linesRemoved,
            otherProjects: projectNames(session.otherProjects, own: session.cwd)
        )
    }

    /// The names you gave the other projects a session works in (else their folders'), for "Nook + monorepo".
    private func projectNames(_ projects: [String], own: String) -> [String] {
        guard !projects.isEmpty else { return [] }
        let settings = app.workspace.settings
        return SessionProjects.names(projects, own: settings.projectDisplayName(own), name: settings.projectDisplayName)
    }

    private func item(_ session: PastSession) -> AgentListItem {
        AgentListItem(
            id: "past:" + session.id,
            folder: session.project,
            title: AgentFormat.title(session.title),
            branch: session.branch.isEmpty ? nil : session.branch,
            agent: session.agent.name,
            account: account(app.profile(for: session)),
            status: .finished,
            started: session.ended,
            path: session.cwd,
            finishKey: FinishedSessions.key(agent: session.agent.name, conversation: session.sessionID, fallback: "past:" + session.id),
            machine: MachineName.local,
            model: session.model,
            accountName: accountName(app.profile(for: session)),
            firstPrompt: session.firstPrompt,
            spawnedTasks: session.spawnedTasks,
            // No file is read for the history's many rows: the worktrees agents make sit in a "worktrees" folder.
            worktree: session.cwd.contains("/worktrees/")
        )
    }

    /// Finished after you last looked, and not the session you are looking at now.
    private func unseen(_ id: String, _ finished: Date?) -> Bool {
        guard !app.demoMode, let finished, id != selected else { return false }
        return SessionVisits.shared.isUnseen(id, finished: finished)
    }
}

extension InboxRow {
    /// A row of the list as the inbox decisions (`InboxLayout`, `AutoSettlePolicy`) see it.
    @MainActor
    init(_ item: AgentListItem, store: InboxStore, finished: FinishedSessions, workspace: WorkspaceManager) {
        let isPast = item.id.hasPrefix("past:")
        // A busy session settles only when you settled it during this busy spell (a turn that hangs).
        let settledBusy = item.isBusy && finished.isMarkedWhileBusy(item.finishKey)
        // Only you settle a chat (or the auto-settle rules you switched on): one that went quiet stays until you handled it,
        // across a restart of Nook too.
        let settled = isPast || settledBusy || (!item.isBusy && finished.contains(item.finishKey))
        let run = item.id.hasPrefix("run:") ? UUID(uuidString: String(item.id.dropFirst(4))) : nil
        self.init(
            id: item.id, title: item.title, project: InboxProject.key(folder: item.folder, path: item.path),
            attention: Self.attention(item),
            pinned: store.state.pinned.contains(item.id), settled: settled,
            snoozedUntil: item.snoozedUntil, snoozedAt: item.snoozedAt, limitedAt: item.limitedAt,
            lastActivity: item.started ?? .distantPast,
            hasOpenRequest: item.status == .waiting || item.status == .input,
            // Messages waiting for the next turn keep it out of the settled shelf.
            hasQueued: run.map { !(workspace.queued[$0]?.isEmpty ?? true) } ?? false,
            isActive: item.isBusy || item.status == .working,
            unread: item.unseen,
            parentID: item.parentID,
            unsettledAt: finished.kept[item.finishKey],
            machine: item.machineID
        )
    }

    private static func attention(_ item: AgentListItem) -> AgentAttention {
        switch item.status {
        case .waiting: return .approval
        case .input: return .input
        case .failed: return .failed
        case .limited: return .limited
        case .working: return .working
        case .idle: return item.unseen ? .ready : .idle
        case .finished: return .finished
        }
    }
}
