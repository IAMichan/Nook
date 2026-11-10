import Foundation

// What needs you in the Agents list, derived in one place: the list, the notch
// and the notifications read the same answer. Foundation only, so tests can use it independently.

/// How urgently a session asks for you. Lower raw value = more urgent; the list sorts on it.
enum AgentAttention: Int, Comparable, Sendable {
    /// A tool or command waits for your approval.
    case approval
    /// The agent asked a question and waits for your answer.
    case input
    case failed
    /// Stopped by a usage limit; it goes on at the reset, or when you do.
    case limited
    case working
    /// Done since you last looked.
    case ready
    case idle
    /// Marked finished, snoozed or stopped: out of the way.
    case finished

    static func < (lhs: AgentAttention, rhs: AgentAttention) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Something only you can unblock.
    var needsYou: Bool { self == .approval || self == .input }

    struct Input: Equatable, Sendable {
        var status: RunStatus
        var pendingApprovals = 0
        var pendingQuestions = 0
        var limitedAt: Date?
        /// Finished after you last opened it.
        var unseen = false
        /// Marked finished by you, or snoozed.
        var settled = false
        /// The turn ended, but subagents it started still work in the background.
        var subagentsWorking = false
    }

    /// Approval beats question beats everything else. A pending request wins over `settled`: what waits for you is never
    /// hidden, and a snoozed session wakes when something needs you.
    static func resolve(_ input: Input) -> AgentAttention {
        if input.pendingApprovals > 0 || input.status == .waitingApproval { return .approval }
        if input.pendingQuestions > 0 && input.status.isActive { return .input }
        if input.settled && !input.status.isActive { return .finished }
        switch input.status {
        case .preparing, .running: return .working
        case .waitingApproval: return .approval
        case .failed: return input.limitedAt != nil ? .limited : .failed
        case .completed: return input.subagentsWorking ? .working : (input.unseen ? .ready : .idle)
        case .stopped: return .finished
        }
    }
}

/// Fires a notification once per session and state, not once per event. A state that is
/// left and entered again fires again.
struct AttentionLedger: Sendable {
    private var last: [String: String] = [:]

    /// True the first time `state` is seen for `id` since it last changed.
    mutating func shouldNotify(id: String, state: AgentAttention, turn: Int = 0) -> Bool {
        guard state.needsYou || state == .ready || state == .failed || state == .limited else {
            last[id] = nil
            return false
        }
        let key = "\(turn):\(state.rawValue)"
        if last[id] == key { return false }
        last[id] = key
        return true
    }

    mutating func forget(_ id: String) { last[id] = nil }
}

/// Snooze: a session out of the way until a time, back earlier when something needs you.
enum SnoozePolicy {
    /// Still hidden at `now`? A snooze ends at its time, or earlier when the session needs you, failed, or finished
    /// something after the snooze began. A usage limit wakes it too, unless the limit was there already when you snoozed
    /// (`limitedAt` before `since`): that is what "until the limit resets" is for.
    static func isSnoozed(until: Date?, since: Date?, attention: AgentAttention, finishedAt: Date?, limitedAt: Date? = nil,
                          now: Date = Date()) -> Bool {
        guard let until, until > now else { return false }
        if attention == .limited {
            guard let limitedAt, let since, limitedAt <= since else { return false }
        }
        if attention.needsYou || attention == .failed { return false }
        if let since, let finishedAt, finishedAt > since, attention == .ready { return false }
        return true
    }

    /// The end of "until the usage limit resets": the session's reset time, while a limit stopped it and that time is
    /// still ahead. Nil when no limit holds it or Nook does not know when it resets.
    static func limitResetEnd(limitedAt: Date?, resetAt: Date?, now: Date = Date()) -> Date? {
        guard limitedAt != nil, let resetAt, resetAt > now else { return nil }
        return resetAt
    }

    /// The longest custom snooze: a month. Anything longer is settling, not snoozing.
    static let maxCustom: TimeInterval = 31 * 24 * 3600

    /// A custom end, from a moment you picked: nil when it is not ahead of `now`, pulled in to `maxCustom`.
    static func customEnd(_ date: Date, now: Date = Date()) -> Date? {
        guard date > now.addingTimeInterval(30) else { return nil }
        return min(date, now.addingTimeInterval(maxCustom))
    }

    /// A custom end, from a duration (`amount` of `unit`).
    static func customEnd(amount: Int, unit: DurationUnit, now: Date = Date()) -> Date? {
        guard amount > 0 else { return nil }
        return customEnd(now.addingTimeInterval(TimeInterval(amount) * unit.seconds), now: now)
    }

    enum DurationUnit: String, CaseIterable, Sendable {
        case minutes, hours, days
        var seconds: TimeInterval {
            switch self {
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86_400
            }
        }
    }

    /// The snooze choices of the menu: an hour, this evening (18:00, or tomorrow when it is later), tomorrow morning (09:00).
    enum Choice: String, CaseIterable, Sendable {
        case hour, evening, tomorrow

        func end(from now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .hour:
                return now.addingTimeInterval(3600)
            case .evening:
                let today = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3600)
                return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
            case .tomorrow:
                let start = calendar.startOfDay(for: now)
                let day = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            }
        }
    }
}

/// Goes on with a session that a restart cut off: one "Continue where you left off.",
/// chained at most `limit` times within `loopWindow` so a session that keeps crashing Nook does not loop.
enum RestartContinuation {
    static let limit = 3
    static let message = "Continue where you left off."

    /// Should this run get the continue message after Nook started?
    /// Only a session cut off just now: one that sat interrupted for a day is yours to pick up.
    static let maxAge: TimeInterval = 30 * 60
    /// Continuations count towards the cap only while they follow each other this closely.
    static let loopWindow: TimeInterval = 5 * 60

    /// Never a session you archived, settled or snoozed, one that waits on you (a question, an approval that the restart
    /// cut off), or one stopped by a usage limit, which has its own resume.
    static func shouldContinue(_ run: WorkspaceRun, enabled: Bool, hasPendingQuestion: Bool = false, settled: Bool = false,
                               now: Date = Date()) -> Bool {
        guard enabled, !run.archived, !settled, !hasPendingQuestion else { return false }
        if run.interruptedWhileWaiting == true, !run.provider.capabilities.pendingRequestsSurviveRestart { return false }
        if let until = run.snoozedUntil, until > now { return false }
        guard now.timeIntervalSince(run.updatedAt) <= maxAge else { return false }
        guard run.status == .stopped, run.statusDetail == "interrupted" else { return false }
        guard run.limitedAt == nil else { return false }
        return chainLength(run, now: now) < limit
    }

    /// Continuations in a row that still count: none once the last one is older than `loopWindow`.
    static func chainLength(_ run: WorkspaceRun, now: Date = Date()) -> Int {
        let count = run.continuations ?? 0
        guard count > 0, let last = run.lastContinuedAt else { return count }
        return now.timeIntervalSince(last) <= loopWindow ? count : 0
    }
}
