import Foundation

// Quiet suggestions, as data only: the lead phrases them.

struct LimitState: Equatable, Sendable {
    var provider: RunProvider
    var profileID: String
    /// 0...1, nil when unknown.
    var usedFraction: Double?
    var resetAt: Date?
}

struct LimitSuggestion: Equatable, Sendable {
    var provider: RunProvider
    var profileID: String
    var sameAgent: Bool
    /// Seconds until the current instance resets, for "or wait N".
    var resumeIn: TimeInterval?
}

enum LimitAdvisor {
    static let limitedAt = 0.9
    static let freeBelow = 0.7

    static func suggest(states: [LimitState], current: (provider: RunProvider, profileID: String), now: Date) -> LimitSuggestion? {
        guard let me = states.first(where: { $0.provider == current.provider && $0.profileID == current.profileID }),
              let used = me.usedFraction, used >= limitedAt else { return nil }
        let others = states.filter { !($0.provider == current.provider && $0.profileID == current.profileID) }
        let known = others.filter { ($0.usedFraction ?? 1) < freeBelow }.sorted { ($0.usedFraction ?? 1) < ($1.usedFraction ?? 1) }
        let unknown = others.filter { $0.usedFraction == nil }
        // Same agent first (its context and skills carry over), then the least used of the rest. Unknown only as a last resort.
        let pick = known.first { $0.provider == current.provider } ?? known.first ?? unknown.first { $0.provider == current.provider } ?? unknown.first
        guard let pick else { return nil }
        return LimitSuggestion(provider: pick.provider, profileID: pick.profileID, sameAgent: pick.provider == current.provider,
                               resumeIn: me.resetAt.map { max(0, $0.timeIntervalSince(now)) })
    }
}

struct StuckInput: Sendable {
    var status: RunStatus
    var lastActivity: Date?
    var pendingRequestSince: Date?
    var userIdleSeconds: TimeInterval
    var limitedSince: Date? = nil
    var now: Date
}

enum StuckSuggestion: Equatable, Sendable {
    case waitingOnYou(minutes: Int)
    case noProgress(minutes: Int)
    case limitedForLong(minutes: Int)
}

enum StuckDetector {
    static let requestMinutes = 5.0
    static let noProgressMinutes = 10.0
    static let limitedMinutes = 30.0

    static func detect(_ input: StuckInput) -> StuckSuggestion? {
        func minutes(since date: Date) -> Double { input.now.timeIntervalSince(date) / 60 }
        if let since = input.pendingRequestSince, minutes(since: since) > requestMinutes,
           input.userIdleSeconds > requestMinutes * 60 {
            return .waitingOnYou(minutes: Int(minutes(since: since)))
        }
        if let since = input.limitedSince, minutes(since: since) > limitedMinutes {
            return .limitedForLong(minutes: Int(minutes(since: since)))
        }
        if input.status == .running, input.pendingRequestSince == nil, let last = input.lastActivity,
           minutes(since: last) > noProgressMinutes {
            return .noProgress(minutes: Int(minutes(since: last)))
        }
        return nil
    }
}
