import Foundation

// When a session settles by itself. The blockers are the
// point: nothing that still runs, waits for you, or that you pinned or snoozed disappears behind your back.

enum AutoSettlePolicy {
    struct Settings: Codable, Equatable, Sendable {
        var enabled = false
        /// Quiet for longer than this many days settles; 0 or less switches the inactivity rule off.
        var inactivityDays = 3
        var settleOnMergedPullRequest = false
        var perThreadOptOut: Set<String> = []

        init(enabled: Bool = false, inactivityDays: Int = 3, settleOnMergedPullRequest: Bool = false,
             perThreadOptOut: Set<String> = []) {
            self.enabled = enabled
            self.inactivityDays = inactivityDays
            self.settleOnMergedPullRequest = settleOnMergedPullRequest
            self.perThreadOptOut = perThreadOptOut
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            inactivityDays = (try? c.decode(Int.self, forKey: .inactivityDays)) ?? 3
            settleOnMergedPullRequest = (try? c.decode(Bool.self, forKey: .settleOnMergedPullRequest)) ?? false
            perThreadOptOut = (try? c.decode(Set<String>.self, forKey: .perThreadOptOut)) ?? []
        }
    }

    enum SettleReason: String, Equatable, Sendable { case mergedPullRequest, inactivity }

    enum KeepReason: String, Equatable, Sendable {
        case disabled, alreadySettled, optedOut, pinned, openRequest, turnRunning, backgroundWork, queuedMessages
        case snoozed, recentActivity
    }

    enum Decision: Equatable, Sendable {
        case settle(SettleReason)
        case keep(KeepReason)
    }

    static func decide(row: InboxRow, prMerged: Bool, settings: Settings, now: Date) -> Decision {
        if row.settled { return .keep(.alreadySettled) }
        guard settings.enabled else { return .keep(.disabled) }
        if settings.perThreadOptOut.contains(row.id) { return .keep(.optedOut) }
        if row.pinned { return .keep(.pinned) }
        if row.needsYou { return .keep(.openRequest) }
        if row.isActive { return .keep(.turnRunning) }
        if row.hasBackgroundWork { return .keep(.backgroundWork) }
        if row.hasQueued { return .keep(.queuedMessages) }
        // A snooze that already woke does not block.
        if SnoozePolicy.isSnoozed(until: row.snoozedUntil, since: row.snoozedAt, attention: row.attention,
                                  finishedAt: row.lastActivity, now: now) {
            return .keep(.snoozed)
        }
        if prMerged && settings.settleOnMergedPullRequest { return .settle(.mergedPullRequest) }
        if settings.inactivityDays > 0,
           row.lastActivity < now.addingTimeInterval(-Double(settings.inactivityDays) * 86_400) {
            return .settle(.inactivity)
        }
        return .keep(.recentActivity)
    }
}

typealias AutoSettleDecision = AutoSettlePolicy.Decision
