import Foundation

/// One subscription window: "5 hours" at 34%, resetting at some time.
struct QuotaLimit: Identifiable, Equatable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var id: String { label }
}

/// The subscription limits of every agent account, from one place. The Agents list, the account details, Settings › Usage
/// and Nook's own context all read them here, so they can no longer disagree.
///
/// Claude reports its limits through its status line (only while a session runs); Codex reports them itself, per
/// account directory.
@MainActor
struct QuotaService {
    let hub: AgentHub
    let codex: CodexUsage

    /// The 5-hour and weekly windows of an account, as far as the agent has reported them.
    func limits(for profile: AgentProfile) -> [QuotaLimit] {
        switch profile.kind {
        case .claude:
            guard let usage = hub.subscriptionUsage(for: profile) else { return [] }
            return [
                usage.fiveHour.map { QuotaLimit(label: tr("agents.fiveHour"), percent: $0.effectivePercent, resetsAt: $0.resetsAt) },
                usage.sevenDay.map { QuotaLimit(label: tr("agents.week"), percent: $0.effectivePercent, resetsAt: $0.resetsAt) }
            ].compactMap { $0 }
        case .gemini, .antigravity:
            return []
        case .codex:
            guard let snapshot = codex.snapshot(home: profile.home.map { _ in profile.homeURL }) else { return [] }
            return [
                snapshot.fiveHour.map { QuotaLimit(label: tr("agents.fiveHour"), percent: Double($0.percent()), resetsAt: $0.resetsAt) },
                snapshot.weekly.map { QuotaLimit(label: tr("agents.week"), percent: Double($0.percent()), resetsAt: $0.resetsAt) }
            ].compactMap { $0 }
        }
    }

    /// "5 hours 34% · week 12%", or nil when nothing is known.
    func summary(for profile: AgentProfile) -> String? {
        let windows = limits(for: profile)
        guard !windows.isEmpty else { return nil }
        return windows.map { "\($0.label.lowercased()) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
    }

    /// The highest percentage of the windows: the one reached first.
    func highest(for profile: AgentProfile) -> Double? {
        limits(for: profile).map(\.percent).max()
    }

    /// The plan Codex reports for this account ("Plus", "Pro"), capitalised.
    func codexPlan(for profile: AgentProfile) -> String {
        guard profile.kind == .codex,
              let raw = codex.snapshot(home: profile.home.map { _ in profile.homeURL })?.planType, !raw.isEmpty else { return "" }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
