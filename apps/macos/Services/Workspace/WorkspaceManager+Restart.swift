import Foundation

// What waits on you survives a restart of Nook (`RestartRequests`): questions come back answerable as a message,
// approvals say they expired, and queued messages stay queued. The same for every agent: it is built on the shared
// `questions`, `approvals` and `queued`, which every agent's handler fills.
extension WorkspaceManager {
    /// The most of an approval's summary kept for the note after a restart.
    private static let savedApprovalLength = 200

    /// The session list as it is written: with what waits on each session now.
    func durableRuns(_ snapshot: [WorkspaceRun]) -> [WorkspaceRun] {
        var asked: [UUID: [SavedQuestion]] = [:]
        for (id, list) in questions {
            let saved = list.compactMap(\.saved)
            if !saved.isEmpty { asked[id] = saved }
        }
        var waiting: [UUID: [String]] = [:]
        for (id, list) in approvals where !list.isEmpty {
            waiting[id] = list.map { pending in
                ToolSummary.oneLine([pending.tool, pending.summary].filter { !$0.isEmpty }.joined(separator: ": "),
                                    Self.savedApprovalLength)
            }
        }
        return RestartRequests.merged(snapshot, questions: asked, approvals: waiting, queues: queued)
    }

    /// A question or approval came or went: the list is saved with it, and a kept agent's output is not marked read past
    /// the request until it is answered (`KeptRuns.durableOffset`).
    func waitingChanged<Value>(_ now: Dictionary<UUID, Value>.Keys, _ before: Dictionary<UUID, Value>.Keys) {
        guard runsLoaded else { return }
        scheduleSave()
        for id in Set(now).union(before) { syncKeptHold(id) }
    }

    /// Puts back what waited on each session when Nook stopped. A kept agent that is still running asks again by itself
    /// (its output is read again from before the request), so only its queue comes back.
    func restoreWaiting(_ saved: [UUID: RestartRequests.Saved]) {
        for (id, entry) in saved {
            guard let run = run(id) else { continue }
            if var queue = entry.queue, queued[id] == nil {
                // A session still at work (a kept agent) sends it when its turn ends, as before the restart.
                if run.status.isActive { queue.resume() }
                setQueue(id, queue)
            }
            guard run.kept == nil else { continue }
            restoreRequests(id, questions: entry.questions, approvals: entry.approvals)
        }
    }

    /// The questions come back to be answered as a message; each approval leaves a note that it expired.
    func restoreRequests(_ id: UUID, questions saved: [SavedQuestion], approvals summaries: [String]) {
        let known = Set((questions[id] ?? []).map(\.id))
        let restored = saved.filter { !known.contains($0.id) }.map { PendingQuestion(restoring: $0, runID: id) }
        if !restored.isEmpty { questions[id, default: []].append(contentsOf: restored) }
        for summary in summaries {
            append(id, RunEvent(kind: .system, text: tr("ws.event.approvalExpiredRestart", summary), tool: "restart"))
        }
    }

    /// Leaves a question that nothing waits for (asked before a restart, or while the agent went on) unanswered.
    func dismissQuestion(_ runID: UUID, questionID: String) {
        guard let question = questions[runID]?.first(where: { $0.id == questionID }), question.answersAsMessage else { return }
        questions[runID]?.removeAll { $0.id == questionID }
        if questions[runID]?.isEmpty == true { questions[runID] = nil }
    }
}
