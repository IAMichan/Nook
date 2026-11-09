import Foundation

/// One list of agent conversations: hook sessions, running processes, transcripts and the sessions Nook runs itself,
/// folded together by `AgentSessionRegistry`.
extension AppModel {
    /// The directory of the account a profile stands for; empty for the default account (as the hooks report it).
    private func accountHome(profileID: String) -> String {
        profiles.profile(id: profileID)?.home ?? ""
    }

    /// The current session id of the Nook session that continues an earlier id of the same conversation, by
    /// "<agent>|<earlier id>". A chat resumed in Nook gets a new id; the transcript under the old one is still that chat.
    private var continuedSessionIDs: [String: String] {
        var map: [String: String] = [:]
        for run in workspace.runs {
            guard let current = run.providerSessionID, !current.isEmpty else { continue }
            for earlier in run.earlierConversations {
                map["\(run.provider.displayName)|\(earlier)"] = current
            }
        }
        return map
    }

    /// Every known conversation as a record, one per source row (not yet merged).
    func sessionRecords() -> [AgentSessionRecord] {
        var records: [AgentSessionRecord] = []
        let continued = continuedSessionIDs
        let sessions = hub.sessions + hub.detected
        for session in sessions {
            let phase: AgentSessionRecord.Phase
            switch session.status {
            case .waiting: phase = .needsYou
            case .running: phase = .working
            case .failed: phase = .failed
            case .done, .detected: phase = .idle
            }
            records.append(AgentSessionRecord(
                id: "live:" + session.id,
                sources: [session.isDetected ? .process : .hook],
                agent: session.name,
                accountHome: session.home,
                conversationID: session.isDetected ? "" : (conversationID(for: session).map { continued["\(session.name)|\($0)"] ?? $0 } ?? ""),
                pid: session.isDetected ? Int32(session.id.dropFirst(5)) : nil,
                cwd: session.cwd,
                title: session.project,
                phase: session.approvalID != nil ? .needsYou : phase,
                updated: Date()
            ))
        }
        for run in workspace.runs where !run.archived {
            let phase: AgentSessionRecord.Phase
            switch run.status {
            case .waitingApproval: phase = .needsYou
            case .preparing, .running: phase = .working
            case .completed: phase = .idle
            case .failed: phase = .failed
            case .stopped: phase = .finished
            }
            records.append(AgentSessionRecord(
                id: "run:" + run.id.uuidString,
                sources: [.nook],
                agent: run.provider.displayName,
                accountHome: accountHome(profileID: run.profileID),
                conversationID: run.providerSessionID ?? "",
                pid: nil,
                cwd: run.workingDirectory,
                title: run.title,
                phase: phase,
                updated: run.updatedAt
            ))
        }
        for past in history.sessions {
            records.append(AgentSessionRecord(
                id: "past:" + past.id,
                sources: [.transcript],
                agent: past.agent.name,
                accountHome: accountHome(profileID: past.profileID),
                conversationID: continued["\(past.agent.name)|\(past.sessionID)"] ?? past.sessionID,
                pid: nil,
                cwd: past.cwd,
                title: past.title,
                phase: .finished,
                updated: past.ended
            ))
        }
        return records
    }

    /// The merged list: every conversation once, grouped by what needs the user first.
    var mergedSessions: [AgentSessionRecord] {
        sessionLists().merged
    }

    /// The merged list and what follows from it, worked out again only when a list it comes from changes. The Agents
    /// tab asks on every redraw, and merging every session list costs more than the rest of the tab.
    private func sessionLists() -> SessionListsCache {
        let key = SessionListsCache.Key(sessions: (hub.sessions + hub.detected).map(SessionListsCache.Key.live),
                                        runs: workspace.runs.map(SessionListsCache.Key.run),
                                        past: history.sessions, profiles: profiles.all)
        if let cache = sessionListsCache, cache.key == key { return cache }
        let merged = AgentSessionRegistry.merge(sessionRecords())
        let free = pastNotCovered(merged: merged)
        let transcripts = detectedTranscripts(free: free)
        let linked = Set(transcripts.values.map(\.id))
        let cache = SessionListsCache(key: key, merged: merged, transcripts: transcripts,
                                      past: free.filter { !linked.contains($0.id) })
        sessionListsCache = cache
        return cache
    }

    /// Earlier sessions from transcripts, without the ones that are also a running session or a session Nook runs
    /// (those are listed there, in more detail).
    var pastSessionsOutsideWorkspace: [PastSession] {
        detectedTranscriptsAndPast().past
    }

    /// `detectedTranscripts()` and `pastSessionsOutsideWorkspace` together. Merging every session list is the costly
    /// part of both: this does it once, for a view that needs the two.
    func detectedTranscriptsAndPast() -> (transcripts: [String: PastSession], past: [PastSession]) {
        let lists = sessionLists()
        return (lists.transcripts, lists.past)
    }

    /// The transcript behind each process Nook only sees (started before Nook opened, or without hooks), by session id: the
    /// latest earlier session of the same agent, folder and account. Several processes in one folder take the sessions in
    /// turn, newest process first. With it such a session shows its conversation straight away.
    func detectedTranscripts() -> [String: PastSession] {
        guard !hub.detected.isEmpty else { return [:] }
        return sessionLists().transcripts
    }

    /// `detectedTranscripts()` with the earlier sessions not covered elsewhere (`pastNotCovered(merged:)`) already worked out.
    private func detectedTranscripts(free: [PastSession]) -> [String: PastSession] {
        guard !hub.detected.isEmpty else { return [:] }
        var result: [String: PastSession] = [:]
        let groups = Dictionary(grouping: hub.detected) { "\($0.name)|\($0.cwd)|\($0.home)" }
        for group in groups.values {
            guard let first = group.first, let kind = AgentKind(agentName: first.name), !first.cwd.isEmpty else { continue }
            let account = profile(for: first)?.id
            let candidates = free
                .filter { $0.agent == kind && $0.cwd == first.cwd && (account == nil || $0.profileID == account) }
                .sorted { $0.started > $1.started }
            let processes = group.sorted { (Int($0.id.dropFirst(5)) ?? 0) > (Int($1.id.dropFirst(5)) ?? 0) }
            for (index, process) in processes.enumerated() where index < candidates.count {
                result[process.id] = candidates[index]
            }
        }
        return result
    }

    private func pastNotCovered(merged: [AgentSessionRecord]) -> [PastSession] {
        let shown = Set(merged.filter { $0.leading != .transcript }.compactMap(\.conversationKey))
        let continued = continuedSessionIDs
        return history.sessions.filter { past in
            // A resumed chat is covered when a running session continues any of its transcripts.
            ([past.sessionID] + past.earlierIDs).allSatisfy { id in
                let key = AgentSessionRecord(id: "", sources: [.transcript], agent: past.agent.name,
                                             accountHome: accountHome(profileID: past.profileID),
                                             conversationID: continued["\(past.agent.name)|\(id)"] ?? id,
                                             pid: nil, cwd: "", title: "", phase: .finished, updated: past.ended).conversationKey
                return key.map { !shown.contains($0) } ?? true
            }
        }
    }

    /// What an id from the session list points at ("live:<session id>", "past:<past session id>"), if it still exists.
    func sessionSelection(_ id: String) -> AgentSessionSelection? {
        if id.hasPrefix("live:") {
            let key = String(id.dropFirst(5))
            return agentSessions.first { $0.id == key }.map { .live($0) }
        }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            return history.sessions.first { $0.id == key }.map { .past($0) }
        }
        return nil
    }

    /// The sessions the main window lists besides the ones Nook runs: waiting for you, active, and earlier.
    func externalSessionRecords(limitEarlier: Int = 25) -> [AgentSessionRecord] {
        let external = mergedSessions.filter { $0.leading != .nook }
        let current = external.filter { $0.section != .earlier }
        let earlier = external.filter { $0.section == .earlier }.prefix(limitEarlier)
        return current + earlier
    }

    /// A conversation Nook runs that went on outside Nook: in the agent's own app (the Claude desktop app), its terminal,
    /// or resumed there (`claude --resume` writes a new transcript under a new session id, and the Nook session moves on
    /// to that id). The Nook session shows what was said and done there, as the agent's own app does, also while the
    /// agent still works on it. Without it the Nook session stopped at your message, or the continuation appeared as a
    /// second chat and Nook's next turn resumed the older conversation.
    func followTerminalContinuations() {
        let candidates = workspace.runs.filter { !$0.archived && !$0.status.isActive && !$0.isRemote }
        guard !candidates.isEmpty else { return }
        // Each transcript by "family|session id", and by "family|earlier id" for one that resumed another, the first in
        // history's order as before: this runs every two seconds while an agent works, and looking each session up in
        // the whole history went through every earlier session for every session Nook runs.
        var ownTranscripts: [String: PastSession] = [:]
        var resumedTranscripts: [String: PastSession] = [:]
        for past in history.sessions where !past.path.isEmpty {
            let family = AgentSessionRecord.family(past.agent.name)
            if ownTranscripts["\(family)|\(past.sessionID)"] == nil { ownTranscripts["\(family)|\(past.sessionID)"] = past }
            for earlier in past.earlierIDs where earlier != past.sessionID && resumedTranscripts["\(family)|\(earlier)"] == nil {
                resumedTranscripts["\(family)|\(earlier)"] = past
            }
        }
        for run in candidates {
            guard let current = run.providerSessionID, !current.isEmpty else { continue }
            let agent = run.provider.displayName
            let family = AgentSessionRecord.family(agent)
            // The agent's app or terminal working on this conversation right now, with the transcript it writes.
            let live = hub.sessions.first {
                AgentSessionRecord.family($0.name) == family && $0.ownConversationID == current && !$0.transcriptPath.isEmpty
            }
            // A transcript that resumed this one under a new id, else this conversation's own.
            let resumed = resumedTranscripts["\(family)|\(current)"]
            let own = ownTranscripts["\(family)|\(current)"]
            let newSession = resumed?.sessionID ?? current
            guard let path = resumed?.path ?? live?.transcriptPath ?? own?.path else { continue }
            // Only when something was written there after Nook last ran it, and once for each change.
            let written = [live?.updated, resumed?.ended, own?.ended].compactMap { $0 }.max() ?? .distantPast
            guard written > run.updatedAt, followedTranscripts[run.id] != written else { continue }
            followedTranscripts[run.id] = written
            let busy = live.map { $0.status == .running || $0.status == .waiting || $0.approvalID != nil } ?? false
            let id = run.id
            Task { [weak self] in
                let messages = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
                self?.workspace.followContinuation(id, from: current, to: newSession, messages: messages, finished: !busy)
            }
        }
    }

    /// Sessions Nook took over before it knew their title were named after their folder ("macos"): they take the title
    /// the agent gave the conversation (the Claude app names every session) or its first question, once history has it.
    func nameSessionsAfterAgents() {
        for run in workspace.runs where !run.archived && !run.isRemote {
            guard let current = run.providerSessionID, !current.isEmpty,
                  run.title == URL(fileURLWithPath: run.projectPath).lastPathComponent else { continue }
            let agent = run.provider.displayName
            guard let past = history.sessions.first(where: { $0.agent.name == agent && $0.isConversation(current) }),
                  !past.title.isEmpty else { continue }
            workspace.rename(run.id, to: past.title)
        }
    }
}

/// Where a chat of the usage breakdown lives in the Agents list: the id to select, and the name the list shows it by.
struct UsageChatTarget: Equatable {
    let selection: String
    let title: String
}

/// The chats of the usage breakdown (Cost, Tokens and the limit windows), as the Agents list knows them.
extension AppModel {
    /// The session behind a usage chat (`agent:session id` of its latest transcript), in the order the Agents list prefers
    /// them: a session Nook runs (under the name Nook gave it), a session running in its own app, then the transcript.
    /// Nil for a chat the list does not show (Nook's own runs, or older than the history).
    func usageChatTarget(_ chat: UsageLedger.Chat) -> UsageChatTarget? {
        guard !demoMode, let kind = AgentKind(rawValue: chat.agent), let colon = chat.id.firstIndex(of: ":") else { return nil }
        let sessionID = String(chat.id[chat.id.index(after: colon)...])
        guard !sessionID.isEmpty else { return nil }
        let past = history.sessions.first { $0.agent == kind && $0.isConversation(sessionID) }
        let ids = Set([sessionID] + (past.map { [$0.sessionID] + $0.earlierIDs } ?? []))
        let runs = workspace.runs.filter { AgentKind(agentName: $0.provider.displayName) == kind && ids.contains(where: $0.isConversation) }
        if let run = runs.first(where: { !$0.archived }) ?? runs.first, !run.title.isEmpty {
            return UsageChatTarget(selection: "run:" + run.id.uuidString, title: run.title)
        }
        let live = hub.sessions.first { session in
            AgentKind(agentName: session.name) == kind && conversationID(for: session).map(ids.contains) == true
        }
        if let live {
            let named = AgentFormat.sessionTitle(live, known: past)
            return UsageChatTarget(selection: live.id, title: named.isEmpty ? live.project : named)
        }
        if let past { return UsageChatTarget(selection: "past:" + past.id, title: AgentFormat.title(past.title)) }
        return nil
    }

    /// Opens a usage chat's session in the Agents tab, in the notch or the main window, and closes the usage modal.
    func openUsageChat(_ target: UsageChatTarget) {
        if target.selection.hasPrefix("run:"), let uuid = UUID(uuidString: String(target.selection.dropFirst(4))) {
            workspace.selectedRunID = uuid
        }
        viewModel.selectedAgentID = target.selection
        viewModel.sheet = nil
        viewModel.windowSheet = nil
        usageModalOpen = false
        viewModel.show(.panel(.agents))
    }
}

/// The merged session lists and the inputs they were worked out from (see `AppModel.sessionLists()`).
struct SessionListsCache {
    /// Only what `sessionRecords()` reads of a running session or a session Nook runs: their steps, replies and streamed
    /// text change many times a second while agents work, and none of it changes the lists.
    struct Key: Equatable {
        let sessions: [String]
        let runs: [String]
        let past: [PastSession]
        let profiles: [AgentProfile]

        static func live(_ s: AgentSession) -> String {
            "\(s.id)|\(s.status)|\(s.approvalID != nil)|\(s.name)|\(s.home)|\(s.cwd)|\(s.project)|\(s.sessionID)"
        }

        static func run(_ r: WorkspaceRun) -> String {
            // The time to the minute: a streaming run moves it on every 2 s, and each change merged every list again
            // while rendering. Its status (a turn starting or ending) is part of the key on its own.
            "\(r.id)|\(r.archived)|\(r.status)|\(r.provider.displayName)|\(r.profileID)|\(r.providerSessionID ?? "")|"
                + "\(r.workingDirectory)|\(r.title)|\(Int(r.updatedAt.timeIntervalSinceReferenceDate / 60))|"
                + r.earlierConversations.joined(separator: ",")
        }
    }

    let key: Key
    let merged: [AgentSessionRecord]
    /// The transcript behind each process Nook only sees, by session id.
    let transcripts: [String: PastSession]
    /// Earlier sessions no running session, Nook session or process covers.
    let past: [PastSession]
}
