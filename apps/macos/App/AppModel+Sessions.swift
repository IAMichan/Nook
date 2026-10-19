import Foundation

/// One list of agent conversations: hook sessions, running processes, transcripts and the sessions Nook runs itself,
/// folded together by `AgentSessionRegistry`.
extension AppModel {
    /// The directory of the account a profile stands for; empty for the default account (as the hooks report it).
    private func accountHome(profileID: String) -> String {
        profiles.profile(id: profileID)?.home ?? ""
    }

    /// Every known conversation as a record, one per source row (not yet merged).
    func sessionRecords() -> [AgentSessionRecord] {
        var records: [AgentSessionRecord] = []
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
                conversationID: session.isDetected ? "" : (conversationID(for: session) ?? ""),
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
                sources: [past.cloud == nil ? AgentSessionRecord.Source.transcript : .cloud],
                agent: past.cloud == nil ? past.agent.name : AppModel.cloudAgentName,
                accountHome: accountHome(profileID: past.profileID),
                conversationID: past.sessionID,
                pid: nil,
                cwd: past.cwd,
                title: past.title,
                phase: past.cloud.map(AppModel.phase) ?? .finished,
                updated: past.ended
            ))
        }
        return records
    }

    /// How cloud sessions are named in the list, next to "Claude Code" and "Claude (app)".
    static let cloudAgentName = "Claude (cloud)"

    private static func phase(_ cloud: CloudSession) -> AgentSessionRecord.Phase {
        switch cloud.status {
        case .running: return .working
        case .needsYou: return .needsYou
        case .failed: return .failed
        case .idle, .archived: return .finished
        }
    }

    /// The merged list: every conversation once, grouped by what needs the user first.
    var mergedSessions: [AgentSessionRecord] {
        AgentSessionRegistry.merge(sessionRecords())
    }

    /// Earlier sessions from transcripts, without the ones that are also a running session or a session Nook runs
    /// (those are listed there, in more detail).
    var pastSessionsOutsideWorkspace: [PastSession] {
        detectedTranscriptsAndPast().past
    }

    /// `detectedTranscripts()` and `pastSessionsOutsideWorkspace` together. Merging every session list is the costly
    /// part of both: this does it once, for a view that needs the two.
    func detectedTranscriptsAndPast() -> (transcripts: [String: PastSession], past: [PastSession]) {
        let free = pastNotCovered
        let transcripts = detectedTranscripts(free: free)
        let linked = Set(transcripts.values.map(\.id))
        return (transcripts, free.filter { !linked.contains($0.id) })
    }

    /// The transcript behind each process Nook only sees (started before Nook opened, or without hooks), by session id: the
    /// latest earlier session of the same agent, folder and account. Several processes in one folder take the sessions in
    /// turn, newest process first. With it such a session shows its conversation straight away.
    func detectedTranscripts() -> [String: PastSession] {
        guard !hub.detected.isEmpty else { return [:] }
        return detectedTranscripts(free: pastNotCovered)
    }

    /// `detectedTranscripts()` with the earlier sessions not covered elsewhere (`pastNotCovered`) already worked out.
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

    private var pastNotCovered: [PastSession] {
        let shown = Set(mergedSessions.filter { $0.leading != .transcript }.compactMap(\.conversationKey))
        return history.sessions.filter { past in
            // A resumed chat is covered when a running session continues any of its transcripts.
            ([past.sessionID] + past.earlierIDs).allSatisfy { id in
                let key = AgentSessionRecord(id: "", sources: [.transcript], agent: past.agent.name,
                                             accountHome: accountHome(profileID: past.profileID), conversationID: id,
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
}
