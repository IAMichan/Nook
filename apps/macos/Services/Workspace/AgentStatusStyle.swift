import Foundation

// One source for the word, symbol and colour role of every Agents status (docs/AGENTS-PLAN.md §4.2). Colour is never the
// only difference: every state has its own symbol and word. Foundation only; the views map `StatusTone` to real colours.

/// What the list, the notch ring and the project row show: the attention states plus the two that come from snoozing.
enum AgentDisplayState: Hashable, CaseIterable, Sendable {
    case approval, input, failed, limited, working, ready, idle, finished
    /// Snoozed until a time; the row shows the time itself.
    case snoozed
    /// A snooze that ran out (or was cut short by a request) and now asks to be looked at.
    case woke

    init(_ attention: AgentAttention) {
        switch attention {
        case .approval: self = .approval
        case .input: self = .input
        case .failed: self = .failed
        case .limited: self = .limited
        case .working: self = .working
        case .ready: self = .ready
        case .idle: self = .idle
        case .finished: self = .finished
        }
    }

    fileprivate var id: String {
        switch self {
        case .approval: "approval"
        case .input: "input"
        case .failed: "failed"
        case .limited: "limited"
        case .working: "working"
        case .ready: "ready"
        case .idle: "idle"
        case .finished: "finished"
        case .snoozed: "snoozed"
        case .woke: "woke"
        }
    }
}

/// Colour role, resolved to a real colour by the view layer (light and dark differ there).
enum StatusTone: String, CaseIterable, Sendable {
    case amber, coral, mint, iris, white, muted, slate
}

enum AgentStatusStyle {
    static func longKey(_ state: AgentDisplayState) -> String { "agents.status.\(state.id).long" }
    static func shortKey(_ state: AgentDisplayState) -> String { "agents.status.\(state.id).short" }

    /// Distinct per state; the test guards it.
    static func symbol(_ state: AgentDisplayState) -> String {
        switch state {
        case .approval: "shield.lefthalf.filled"
        case .input: "questionmark.bubble"
        case .failed: "exclamationmark.circle"
        case .limited: "clock"
        case .working: "circle.dotted"
        case .ready: "checkmark.circle"
        case .idle: "moon.zzz"
        case .finished: "archivebox"
        case .snoozed: "bell.slash"
        case .woke: "alarm"
        }
    }

    static func tone(_ state: AgentDisplayState) -> StatusTone {
        switch state {
        case .approval, .input, .limited, .woke: .amber
        case .failed: .coral
        case .working: .iris
        case .ready: .mint
        case .idle, .finished: .muted
        case .snoozed: .slate
        }
    }

    /// Only a running agent moves; everything else is still so a long list stays calm.
    static func pulses(_ state: AgentDisplayState) -> Bool { state == .working }

    /// Higher = more urgent. Distinct per state so a roll-up never depends on input order.
    static func priority(_ state: AgentDisplayState) -> Int {
        switch state {
        case .approval: 100
        case .input: 90
        case .failed: 80
        case .woke: 70
        case .limited: 60
        case .working: 50
        case .ready: 40
        case .idle: 20
        case .snoozed: 10
        case .finished: 0
        }
    }

    /// Every i18n key the style uses, for the coverage test and for the lead to add.
    static var keys: [String] {
        AgentDisplayState.allCases.flatMap { [longKey($0), shortKey($0)] }
    }
}

enum ProjectRollup {
    /// The state a collapsed project row or the notch ring shows: the most urgent one, so a project that needs approval
    /// outranks one that is working. The first of equals wins.
    static func highest(_ states: [AgentDisplayState]) -> AgentDisplayState? {
        var best: AgentDisplayState?
        for state in states where best == nil || AgentStatusStyle.priority(state) > AgentStatusStyle.priority(best!) {
            best = state
        }
        return best
    }
}

enum StallSeverity: Int, Comparable, Sendable {
    case quiet, long
    static func < (lhs: StallSeverity, rhs: StallSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct StallHint: Equatable, Sendable {
    var seconds: TimeInterval
    var severity: StallSeverity
}

enum StallDetector {
    /// A running agent that has said nothing for `thresholdSeconds` gets a quiet hint, at 5x a stronger one. Any new
    /// activity moves `lastActivity` and so clears it. A clock that went backwards gives no hint.
    static func hint(lastActivity: Date?, now: Date, thresholdSeconds: TimeInterval = 60) -> StallHint? {
        guard let lastActivity, thresholdSeconds > 0 else { return nil }
        let seconds = now.timeIntervalSince(lastActivity)
        guard seconds >= thresholdSeconds else { return nil }
        return StallHint(seconds: seconds, severity: seconds >= thresholdSeconds * 5 ? .long : .quiet)
    }
}

enum DurationText {
    /// "42s", "1m 12s", "2h 5m". Whole seconds, rounded down, so a counter never runs ahead of the clock.
    static func short(_ seconds: Double) -> String {
        let total = whole(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    /// One unit, for "last activity 1m ago": "12s", "3m", "2h", "1d".
    static func ago(_ seconds: Double) -> String {
        let total = whole(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3600)h" }
        return "\(total / 86_400)d"
    }

    private static func whole(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1e9).rounded(.down))
    }
}
