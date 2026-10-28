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
            for earlier in run.conversation?.earlierSessions ?? [] {
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
        let key = SessionListsCache.Key(sessions: hub.sessions, detected: hub.detected, runs: workspace.runs,
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

    /// A conversation Nook runs that was continued in the terminal (`claude --resume` writes a new transcript under a new
    /// session id): the Nook session moves on to that id and shows what was said there. Without it the continuation
    /// appeared as a second chat and Nook's next turn resumed the older conversation, losing the terminal's messages.
    func followTerminalContinuations() {
        for run in workspace.runs where !run.archived && !run.status.isActive {
            guard let current = run.providerSessionID, !current.isEmpty else { continue }
            let agent = run.provider.displayName
            guard let past = history.sessions.first(where: {
                $0.agent.name == agent && $0.sessionID != current && !$0.path.isEmpty && $0.earlierIDs.contains(current)
            }) else { continue }
            let id = run.id
            let path = past.path
            let newSession = past.sessionID
            Task { [weak self] in
                let messages = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
                self?.workspace.followContinuation(id, from: current, to: newSession, messages: messages)
            }
        }
    }
}

/// The merged session lists and the inputs they were worked out from (see `AppModel.sessionLists()`).
struct SessionListsCache {
    struct Key: Equatable {
        let sessions: [AgentSession]
        let detected: [AgentSession]
        let runs: [WorkspaceRun]
        let past: [PastSession]
        let profiles: [AgentProfile]
    }

    let key: Key
    let merged: [AgentSessionRecord]
    /// The transcript behind each process Nook only sees, by session id.
    let transcripts: [String: PastSession]
    /// Earlier sessions no running session, Nook session or process covers.
    let past: [PastSession]
}
