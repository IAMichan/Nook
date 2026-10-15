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
                sources: [.transcript],
                agent: past.agent.name,
                accountHome: accountHome(profileID: past.profileID),
                conversationID: past.sessionID,
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
        AgentSessionRegistry.merge(sessionRecords())
    }

    /// Earlier sessions from transcripts, without the ones that are also a running session or a session Nook runs
    /// (those are listed there, in more detail).
    var pastSessionsOutsideWorkspace: [PastSession] {
        let shown = Set(mergedSessions.filter { $0.leading != .transcript }.compactMap(\.conversationKey))
        return history.sessions.filter { past in
            let key = AgentSessionRecord(id: "", sources: [.transcript], agent: past.agent.name,
                                         accountHome: accountHome(profileID: past.profileID), conversationID: past.sessionID,
                                         pid: nil, cwd: "", title: "", phase: .finished, updated: past.ended).conversationKey
            return key.map { !shown.contains($0) } ?? true
        }
    }
}
