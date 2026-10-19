import Foundation

// Structured (not localised) labels for the timeline: a work group's summary, a folded turn's label and the "Go to
// failure" target. The view turns them into words, so this stays testable and the strings live in the i18n files.

enum WorkAction: Sendable {
    case command, edit, read, search, web, mcp, thought, other, agent
}

struct WorkGroupItem: Equatable, Sendable {
    var action: WorkAction
    var failed = false
}

struct WorkGroupSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case empty
        /// Every item was a thought: "Thought (×3)".
        case thoughtOnly(count: Int)
        case work
    }

    struct Part: Equatable, Sendable {
        var category: WorkAction
        var count: Int
    }

    var kind: Kind
    /// At most two, in the order they first appeared.
    var parts: [Part]
    /// Actions in the groups that did not make the cut.
    var otherCount: Int
    var hasFailure: Bool

    /// Summarizes a tool group into one group per action: the two highest by
    /// priority (ties: first seen) are shown in their original order, and the rest is counted.
    /// Thoughts mixed with tools are ignored and never counted as "other", and reads rank below
    /// search/web/mcp.
    static func make(_ items: [WorkGroupItem]) -> WorkGroupSummary {
        guard !items.isEmpty else { return WorkGroupSummary(kind: .empty, parts: [], otherCount: 0, hasFailure: false) }
        let tools = items.filter { $0.action != .thought }
        guard !tools.isEmpty else {
            return WorkGroupSummary(kind: .thoughtOnly(count: items.count), parts: [], otherCount: 0, hasFailure: false)
        }
        var order: [WorkAction] = []
        var counts: [WorkAction: Int] = [:]
        for item in tools {
            if counts[item.action] == nil { order.append(item.action) }
            counts[item.action, default: 0] += 1
        }
        let chosen = order.enumerated()
            .sorted { (priority($0.element), $0.offset) < (priority($1.element), $1.offset) }
            .prefix(2)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        let parts = chosen.map { Part(category: $0, count: counts[$0] ?? 0) }
        let shown = parts.reduce(0) { $0 + $1.count }
        return WorkGroupSummary(kind: .work, parts: parts, otherCount: tools.count - shown,
                                hasFailure: tools.contains { $0.failed })
    }

    private static func priority(_ action: WorkAction) -> Int {
        switch action {
        case .command, .edit, .agent: 0
        case .search, .web, .mcp: 1
        case .read, .other, .thought: 2
        }
    }
}

/// The label on a folded finished turn.
struct FoldLabel: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// "Worked for 42s"; nil when the duration is unknown.
        case worked(seconds: Double?)
        case stoppedAfter(seconds: Double)
        case stopped
        /// An earlier attempt cut off by a steer: its time would mislead.
        case superseded
    }

    var kind: Kind
    /// A failed turn still says "worked", and the row carries this flag for the red accent.
    var failed = false

    /// nil while the turn is still going: there is nothing to fold yet.
    static func make(status: RunStatus, durationSeconds: Double?, superseded: Bool) -> FoldLabel? {
        if superseded { return FoldLabel(kind: .superseded) }
        switch status {
        case .preparing, .running, .waitingApproval:
            return nil
        case .stopped:
            if let durationSeconds { return FoldLabel(kind: .stoppedAfter(seconds: max(0, durationSeconds))) }
            return FoldLabel(kind: .stopped)
        case .completed:
            return FoldLabel(kind: .worked(seconds: durationSeconds.map { max(0, $0) }))
        case .failed:
            return FoldLabel(kind: .worked(seconds: durationSeconds.map { max(0, $0) }), failed: true)
        }
    }
}

enum FailureJump {
    private static func isFailure(_ event: RunEvent) -> Bool {
        event.kind == .error || (event.kind == .tool && event.state == .failed)
    }

    /// The target of "Go to failure": the first failed tool call or error in the group.
    static func firstFailure(in events: [RunEvent]) -> UUID? { events.first(where: isFailure)?.id }

    static func failureCount(in events: [RunEvent]) -> Int { events.filter(isFailure).count }
}
