import Foundation

/// The list of agent sessions the hooks told Nook about: pruned when they end or go quiet, and published at most once
/// a second while they work.
extension AgentHub {
    // MARK: Session List

    func prune() {
        let now = Date()
        // A compaction no event ended (an agent that only says when it starts) stops showing after `HookCompaction.timeout`.
        for (key, record) in records where record.compactingSince != nil && !HookCompaction.isLive(since: record.compactingSince, now: now) {
            records[key]?.compactingSince = nil
            if let last = records[key]?.steps.last, last.mark == .running, last.text == tr("ws.activity.compacting") {
                records[key]?.steps.removeLast()
            }
            rebuild()
        }
        let kept = records.filter { key, record in
            if pendingApprovals.values.contains(where: { $0.request.sessionKey == key }) { return true }
            let settled = Self.isSettled(key: key, agent: record.agent, sessionID: record.sessionID, cwd: record.cwd,
                                         lastActive: record.updated)
            return !SessionLiveness.isExpired(done: record.status == .done || record.status == .failed, settled: settled, age: now.timeIntervalSince(record.updated))
        }
        // Only when something expired: every assignment runs `records`' didSet, which saves agent-sessions.json.
        guard kept.count != records.count else { return }
        records = kept
        rebuild()
    }

    /// Whether you settled this session in the Agents list (`FinishedSessions.key(session:)` for a hooked session).
    static func isSettled(key: String, agent: String, sessionID: String, cwd: String, lastActive: Date) -> Bool {
        let conversation = FinishedSessions.ownConversation(id: key, sessionID: sessionID, cwd: cwd, detected: false)
        return FinishedSessions.shared.isSettled(FinishedSessions.key(agent: agent, conversation: conversation, fallback: key),
                                                 lastActive: lastActive)
    }

    /// How often a session's progress alone is published at most. Each tool call of each agent is a hook event, and each
    /// publish redraws every view of the app: with several agents at work that was several full redraws a second.
    private static let progressInterval: TimeInterval = 1

    /// Publishes the sessions as the records now have them. What asks something of you or changes the list (a session
    /// that starts, waits, finishes or ends, an approval, a new prompt) is published at once; progress alone (a step, a
    /// reply, the time of the last event, the order that follows from it) at most once every `progressInterval`.
    func rebuild() {
        // A hook event being handled rebuilds once, at its end (`handle`).
        if deferringRebuild {
            rebuildRequested = true
            return
        }
        let newSessions = makeSessions()
        guard sessions != newSessions else { return }
        let wait = lastPublished.timeIntervalSinceNow + Self.progressInterval
        if wait <= 0 || Self.shape(newSessions) != Self.shape(sessions) {
            sessions = newSessions
            lastPublished = Date()
        } else if !publishPending {
            publishPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.publishPending = false
                    self?.rebuild()
                }
            }
        }
    }

    /// What of the sessions must show at once, in no particular order.
    private static func shape(_ sessions: [AgentSession]) -> [String] {
        sessions.map {
            "\($0.id)|\($0.status)|\($0.approvalID ?? "")|\($0.turnStarted == nil)|\($0.compactingSince == nil)|\($0.lastPrompt)"
        }.sorted()
    }

    private func makeSessions() -> [AgentSession] {
        let order: [AgentStatus: Int] = [.waiting: 0, .failed: 1, .running: 2, .done: 3]
        // The context lines of a finished session are made anew on each rebuild, each with a new id: the ones published
        // already are kept while their text is the same, so an unchanged session stays equal and its rows keep their identity.
        let published = Dictionary(sessions.map { ($0.id, $0.diff) }, uniquingKeysWith: { first, _ in first })
        // The oldest approval of each session, as `approvals.first { $0.sessionKey == key }` finds it.
        let approvalIDs = Dictionary(approvals.map { ($0.sessionKey, $0.id) }, uniquingKeysWith: { first, _ in first })
        return records
            .sorted { lhs, rhs in
                let l = order[lhs.value.status] ?? 9
                let r = order[rhs.value.status] ?? 9
                return l != r ? l < r : lhs.value.updated > rhs.value.updated
            }
            .map { key, record in
                var diff: [DiffLine] = []
                if record.status == .done || record.status == .failed || record.diff.isEmpty {
                    if !record.cwd.isEmpty { diff.append(DiffLine(kind: .context, text: record.cwd)) }
                    for line in record.lastMessage.split(separator: "\n").prefix(8) {
                        diff.append(DiffLine(kind: .context, text: String(line.prefix(110))))
                    }
                } else {
                    diff = record.diff
                }
                if let old = published[key], old.elementsEqual(diff, by: { $0.kind == $1.kind && $0.text == $1.text }) {
                    diff = old
                }
                var file = record.file
                if record.linesAdded + record.linesRemoved > 0 {
                    file += "  +\(record.linesAdded) −\(record.linesRemoved)"
                }
                return AgentSession(
                    id: key,
                    name: record.agent,
                    project: record.project,
                    status: record.status,
                    file: file,
                    placeholder: "Type in the terminal of \(record.agent) to continue",
                    steps: record.steps,
                    diff: diff,
                    cwd: record.cwd,
                    hostBundleID: record.hostBundleID,
                    home: record.home,
                    approvalID: approvalIDs[key],
                    linesAdded: record.linesAdded,
                    linesRemoved: record.linesRemoved,
                    summary: Self.oneLine(record.lastMessage),
                    sessionID: record.sessionID,
                    transcriptPath: record.transcriptPath,
                    lastPrompt: record.lastPrompt,
                    firstPrompt: record.firstPrompt,
                    lastReply: record.lastMessage,
                    started: record.started,
                    turnStarted: record.turnStarted,
                    compactingSince: HookCompaction.isLive(since: record.compactingSince) ? record.compactingSince : nil,
                    updated: record.updated,
                    otherProjects: record.otherProjects
                )
            }
    }
}
