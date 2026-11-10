import Foundation

// A compaction of the conversation while it runs, the same for every coding agent that says when it starts: one
// `.system` row (tool "compaction") that is live while the agent summarizes ("Compacting the conversation…" in the live
// line under the timeline) and becomes the compacted notice when it is done, or an error when it failed. Agents that only
// report the result get the done row straight away, as before.
//
// What each agent reports (see the coding agent matrix in docs/INTEGRATIONS.md):
// - Claude Code: `system/status` with `status: "compacting"`, then `system/status` with `compact_result` and the
//   `compact_boundary` message.
// - Codex (app-server): `item/started` and `item/completed` of a `contextCompaction` item (`thread/compacted` on older ones).
// - Pi: `compaction_start` and `compaction_end`.
//
// Foundation only, so the tests drive it without an agent.

/// How a compaction goes, as an agent's parser reports it (the result itself stays the `compact` notice).
enum CompactionPhase: Equatable, Sendable {
    /// The agent started summarizing the conversation.
    case started
    /// It stopped without a summary: the agent's message, or nil when it gave none (an interrupt).
    case failed(String?)
}

/// What the session's events need for a compaction: a row to add, a row to change, or nothing.
enum CompactionChange: Equatable, Sendable {
    case append(RunEvent)
    case update(id: UUID, kind: RunEvent.Kind, text: String, state: RunEvent.State)
    case none
}

enum CompactionProgress {
    /// The `tool` of a compaction's row.
    static let tool = "compaction"

    static func isCompaction(_ event: RunEvent) -> Bool { event.kind == .system && event.tool == tool }

    static func isRunning(_ event: RunEvent) -> Bool { isCompaction(event) && event.state == .running }

    /// The compaction of the last turn that still runs, found from the end (a turn starts at a message of yours).
    static func running(in events: [RunEvent]) -> UUID? {
        for event in events.reversed() {
            if isRunning(event) { return event.id }
            if event.kind == .user { return nil }
        }
        return nil
    }

    /// The agent started compacting: a live row, unless one already runs (an agent that reports the start twice).
    /// `done` is what the row says once the conversation is compacted (by hand, by Nook while idle, or for its size).
    static func start(_ events: [RunEvent], done: String, at date: Date = Date()) -> CompactionChange {
        guard running(in: events) == nil else { return .none }
        return .append(RunEvent(kind: .system, text: done, tool: tool, state: .running, date: date))
    }

    /// The conversation is compacted: the live row is done (with `text`, in case the reason became known since), or a
    /// done row of its own for an agent that reports only the result.
    static func finish(_ events: [RunEvent], text: String, at date: Date = Date()) -> CompactionChange {
        if let id = running(in: events) { return .update(id: id, kind: .system, text: text, state: .done) }
        // One compaction reported twice (Codex's item and its `thread/compacted`) is one row.
        if let last = events.last, isCompaction(last), last.state == .done { return .none }
        return .append(RunEvent(kind: .system, text: text, tool: tool, state: .done, date: date))
    }

    /// The compaction stopped without a summary: the live row turns into the error (`stopped` when the agent gave no
    /// reason). Nothing changes when no compaction runs.
    static func fail(_ events: [RunEvent], message: String?, stopped: String) -> CompactionChange {
        guard let id = running(in: events) else { return .none }
        let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .update(id: id, kind: .error, text: reason.isEmpty ? stopped : reason, state: .failed)
    }
}
