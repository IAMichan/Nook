import Foundation

// A compaction while it runs and when it ends, for every agent that reports it (see CompactionProgress): each provider's
// handler only translates its own events into these calls.
extension WorkspaceManager {
    /// What the row says once the conversation is compacted: by Nook for its size, by Nook while idle, or by the agent.
    func compactedText(_ id: UUID) -> String {
        tr(sizeCompacting.contains(id) ? "ws.event.sizeCompaction" : idleCompacting.contains(id) ? "ws.event.idleCompaction" : "ws.event.compacted")
    }

    /// The agent started compacting: a live row, which the live line under the timeline names while it runs.
    func compactionStarted(_ id: UUID) {
        apply(CompactionProgress.start(timeline(id), done: compactedText(id)), to: id)
    }

    /// The conversation is compacted (`.notice("compact")` of every agent).
    func compactionFinished(_ id: UUID) {
        turns[id]?.compacted = true
        apply(CompactionProgress.finish(timeline(id), text: compactedText(id)), to: id)
    }

    /// The compaction stopped without a summary; `message` is nil when the agent gave no reason (or you stopped it).
    func compactionFailed(_ id: UUID, message: String?) {
        apply(CompactionProgress.fail(timeline(id), message: message, stopped: tr("ws.event.compactionStopped")), to: id)
    }

    func noteCompaction(_ id: UUID, _ phase: CompactionPhase) {
        switch phase {
        case .started: compactionStarted(id)
        case .failed(let message): compactionFailed(id, message: message)
        }
    }

    private func apply(_ change: CompactionChange, to id: UUID) {
        switch change {
        case .append(let event):
            append(id, event)
        case .update(let eventID, let kind, let text, let state):
            mutateEvent(id, eventID) { event in
                event.kind = kind
                event.text = text
                event.state = state
            }
        case .none:
            break
        }
    }
}
