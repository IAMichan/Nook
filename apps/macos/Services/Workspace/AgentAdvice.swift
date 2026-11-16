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
    /// How much of the suggested account's limit is used, 0...1; nil when unknown.
    var usedFraction: Double? = nil
    /// Seconds until the current instance resets, for "or wait N".
    var resumeIn: TimeInterval?
}

enum LimitAdvisor {
    static let limitedAt = 0.9
    static let freeBelow = 0.7

    static func suggest(states: [LimitState], current: (provider: RunProvider, profileID: String), now: Date) -> LimitSuggestion? {
        options(states: states, current: current, now: now).first
    }

    /// Every account to go on with, best first: same agent first (its context and skills carry over), then the least
    /// used of the rest; accounts whose use is unknown only after those, same agent first again. Accounts that are
    /// nearly full themselves are left out. Empty while the current account still has room.
    static func options(states: [LimitState], current: (provider: RunProvider, profileID: String), now: Date) -> [LimitSuggestion] {
        guard let me = states.first(where: { $0.provider == current.provider && $0.profileID == current.profileID }),
              let used = me.usedFraction, used >= limitedAt else { return [] }
        let others = states.filter { !($0.provider == current.provider && $0.profileID == current.profileID) }
        let known = others.filter { ($0.usedFraction ?? 1) < freeBelow }.sorted { ($0.usedFraction ?? 1) < ($1.usedFraction ?? 1) }
        let unknown = others.filter { $0.usedFraction == nil }
        func sameFirst(_ list: [LimitState]) -> [LimitState] {
            list.filter { $0.provider == current.provider } + list.filter { $0.provider != current.provider }
        }
        let resumeIn = me.resetAt.map { max(0, $0.timeIntervalSince(now)) }
        return (sameFirst(known) + sameFirst(unknown)).map {
            LimitSuggestion(provider: $0.provider, profileID: $0.profileID, sameAgent: $0.provider == current.provider,
                            usedFraction: $0.usedFraction, resumeIn: resumeIn)
        }
    }

    /// The accounts to offer when `options` has none: the others that are filling up but not full yet, least used first
    /// (same agent first when equally used), so the usage limit card can still propose one to go on with.
    static func fallbacks(states: [LimitState], current: (provider: RunProvider, profileID: String), now: Date) -> [LimitSuggestion] {
        guard let me = states.first(where: { $0.provider == current.provider && $0.profileID == current.profileID }),
              let used = me.usedFraction, used >= limitedAt else { return [] }
        let resumeIn = me.resetAt.map { max(0, $0.timeIntervalSince(now)) }
        let others = states.filter { !($0.provider == current.provider && $0.profileID == current.profileID) }
        let roomy = others.compactMap { state -> (LimitState, Double)? in
            guard let fraction = state.usedFraction, fraction < 1 else { return nil }
            return (state, fraction)
        }
        return roomy
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : (lhs.0.provider == current.provider && rhs.0.provider != current.provider)
            }
            .map { state, fraction in
                LimitSuggestion(provider: state.provider, profileID: state.profileID,
                                sameAgent: state.provider == current.provider, usedFraction: fraction, resumeIn: resumeIn)
            }
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
