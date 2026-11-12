import Foundation

// When a session settles by itself. The blockers are the
// point: nothing that still runs, waits for you, or that you pinned or snoozed disappears behind your back.

enum AutoSettlePolicy {
    struct Settings: Codable, Equatable, Sendable {
        var enabled = false
        /// Quiet for longer than this many days settles; 0 or less switches the inactivity rule off.
        var inactivityDays = 3
        var settleOnMergedPullRequest = false
        /// A pull request closed without merging settles its idle session too.
        var settleOnClosedPullRequest = false
        /// A session whose pull request is still open never settles for inactivity ("Keep sessions with an open PR").
        var keepWithOpenPullRequest = false
        var perThreadOptOut: Set<String> = []

        init(enabled: Bool = false, inactivityDays: Int = 3, settleOnMergedPullRequest: Bool = false,
             settleOnClosedPullRequest: Bool = false, keepWithOpenPullRequest: Bool = false,
             perThreadOptOut: Set<String> = []) {
            self.enabled = enabled
            self.inactivityDays = inactivityDays
            self.settleOnMergedPullRequest = settleOnMergedPullRequest
            self.settleOnClosedPullRequest = settleOnClosedPullRequest
            self.keepWithOpenPullRequest = keepWithOpenPullRequest
            self.perThreadOptOut = perThreadOptOut
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            inactivityDays = (try? c.decode(Int.self, forKey: .inactivityDays)) ?? 3
            settleOnMergedPullRequest = (try? c.decode(Bool.self, forKey: .settleOnMergedPullRequest)) ?? false
            // Before this was a rule of its own, a closed pull request settled like a merged one: settings saved then
            // keep doing that.
            settleOnClosedPullRequest = (try? c.decode(Bool.self, forKey: .settleOnClosedPullRequest)) ?? settleOnMergedPullRequest
            keepWithOpenPullRequest = (try? c.decode(Bool.self, forKey: .keepWithOpenPullRequest)) ?? false
            perThreadOptOut = (try? c.decode(Set<String>.self, forKey: .perThreadOptOut)) ?? []
        }
    }

    /// What a new install starts with: quiet sessions settle after a week, and so do sessions whose pull request merged or
    /// closed. Existing installs keep what they had (`initial`).
    static let newInstallDefaults = Settings(enabled: true, inactivityDays: 7, settleOnMergedPullRequest: true,
                                             settleOnClosedPullRequest: true)

    /// Once, for an install that still has the old default (off, never changed): t3code's rules, as a new install gets
    /// them. Settings you changed stay as they are; the sessions you kept out of it stay out.
    static func upgradingOldDefault(_ settings: Settings) -> Settings {
        var untouched = settings
        untouched.perThreadOptOut = []
        guard untouched == Settings() else { return settings }
        var upgraded = newInstallDefaults
        upgraded.perThreadOptOut = settings.perThreadOptOut
        return upgraded
    }

    /// The key of this Mac among the machines with rules of their own; an SSH machine goes by its `RemoteMachine.id`.
    static let thisMac = "local"

    /// The rules for sessions on `machine` (nil: this Mac): its own when it has them, else the ones for all machines, as
    /// t3code's rules per environment. The sessions you kept out of it stay out on every machine.
    static func settings(for machine: String?, all: Settings, perMachine: [String: Settings]) -> Settings {
        guard var own = perMachine[machine ?? thisMac] else { return all }
        own.perThreadOptOut = all.perThreadOptOut
        return own
    }

    /// One rule changed for all machines: the machines with their own rules take it too, as t3code's "All environments".
    static func settingAll<Value>(_ field: WritableKeyPath<Settings, Value>, to value: Value, all: inout Settings,
                                  perMachine: inout [String: Settings]) {
        all[keyPath: field] = value
        for key in perMachine.keys { perMachine[key]?[keyPath: field] = value }
    }

    /// How long after Nook first remembered anything a launch still counts as the first one.
    static let firstLaunchWindow: TimeInterval = 10 * 60

    /// The settings at launch: what is stored wins. Without any, a Mac that used Nook before (`usedSince`, the first trace
    /// Nook left, older than `firstLaunchWindow`) keeps the old default (off), and a new install gets `newInstallDefaults`.
    static func initial(stored: Settings?, usedSince: Date?, now: Date = Date()) -> Settings {
        if let stored { return stored }
        if let usedSince, now.timeIntervalSince(usedSince) > firstLaunchWindow { return Settings() }
        return newInstallDefaults
    }

    /// What the session's pull request says, for the rules: nothing (none, or one that landed before you wrote again),
    /// still open, merged, or closed without merging.
    enum PullRequestState: Equatable, Sendable { case none, open, merged, closed }

    enum SettleReason: String, Equatable, Sendable { case mergedPullRequest, closedPullRequest, inactivity }

    enum KeepReason: String, Equatable, Sendable {
        case disabled, alreadySettled, optedOut, unsettledByYou, pinned, openRequest, turnRunning, backgroundWork
        case queuedMessages, snoozed, openPullRequest, recentActivity
    }

    enum Decision: Equatable, Sendable {
        case settle(SettleReason)
        case keep(KeepReason)
    }

    static func decide(row: InboxRow, prMerged: Bool, settings: Settings, now: Date) -> Decision {
        decide(row: row, pullRequest: prMerged ? .merged : .none, settings: settings, now: now)
    }

    static func decide(row: InboxRow, pullRequest: PullRequestState, settings: Settings, now: Date) -> Decision {
        if row.settled { return .keep(.alreadySettled) }
        guard settings.enabled else { return .keep(.disabled) }
        if settings.perThreadOptOut.contains(row.id) { return .keep(.optedOut) }
        // You brought it back from Settled: it stays until something new happens in it, then the rules apply again.
        if let unsettled = row.unsettledAt, row.lastActivity <= unsettled { return .keep(.unsettledByYou) }
        if row.pinned { return .keep(.pinned) }
        if row.needsYou { return .keep(.openRequest) }
        if row.isActive { return .keep(.turnRunning) }
        if row.hasBackgroundWork { return .keep(.backgroundWork) }
        if row.hasQueued { return .keep(.queuedMessages) }
        // A snooze that already woke does not block.
        if SnoozePolicy.isSnoozed(until: row.snoozedUntil, since: row.snoozedAt, attention: row.attention,
                                  finishedAt: row.lastActivity, limitedAt: row.limitedAt, now: now) {
            return .keep(.snoozed)
        }
        switch pullRequest {
        case .merged where settings.settleOnMergedPullRequest: return .settle(.mergedPullRequest)
        case .closed where settings.settleOnClosedPullRequest: return .settle(.closedPullRequest)
        case .open where settings.keepWithOpenPullRequest: return .keep(.openPullRequest)
        default: break
        }
        // A snooze that ran out brought the session back to you: its quiet time counts from then.
        let woke = row.snoozedUntil.flatMap { $0 <= now ? $0 : nil }
        let quietSince = max(row.lastActivity, woke ?? .distantPast)
        if settings.inactivityDays > 0,
           quietSince < now.addingTimeInterval(-Double(settings.inactivityDays) * 86_400) {
            return .settle(.inactivity)
        }
        return .keep(.recentActivity)
    }
}

typealias AutoSettleDecision = AutoSettlePolicy.Decision
