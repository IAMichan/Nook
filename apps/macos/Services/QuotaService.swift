import Foundation

/// One subscription window: "5 hours" at 34%, resetting at some time.
struct QuotaLimit: Identifiable, Equatable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    /// Shown instead of a reset time, e.g. when the window has not started yet.
    var note: String? = nil
    /// How long the window lasts (5 hours, a week), when known. With `resetsAt` it places the window's start.
    var duration: TimeInterval? = nil
    var id: String { label }

    /// How far `now` is into the window, 0...1: where usage would sit if it were spread evenly over the window.
    /// Nil when the window's start is unknown or it has already reset.
    func elapsed(at now: Date = Date()) -> Double? {
        guard let duration, duration > 0, let resetsAt, resetsAt > now else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / duration))
    }

    /// The model group of a label like "Gemini 4 Pro · Week" ("Gemini 4 Pro"), or nil for a plain window ("5 hours").
    var group: String? {
        guard let range = label.range(of: " · ", options: .backwards) else { return nil }
        return String(label[..<range.lowerBound])
    }

    /// The window part of the label: "Week" for "Gemini 4 Pro · Week".
    var window: String {
        guard let range = label.range(of: " · ", options: .backwards) else { return label }
        return String(label[range.upperBound...])
    }
}

/// The subscription limits of every agent account, from one place. The Agents list, the account details, Settings › Usage
/// and Nook's own context all read them here, so they can no longer disagree.
///
/// Claude Code reports its limits through its status line and sessions in Nook, and `ClaudeUsage` asks the `claude` CLI
/// for them every few minutes; Codex reports them itself, per account directory.
@MainActor
struct QuotaService {
    let hub: AgentHub
    let codex: CodexUsage
    let antigravity: AntigravityUsage

    /// The 5-hour and weekly windows of an account, as far as the agent has reported them.
    func limits(for profile: AgentProfile) -> [QuotaLimit] {
        switch profile.kind {
        case .claude:
            guard let usage = hub.subscriptionUsage(for: profile) else { return [] }
            return [
                window(usage.fiveHour.map { ($0.effectivePercent, $0.resetsAt) }, label: tr("agents.fiveHour"), duration: Self.fiveHours),
                window(usage.sevenDay.map { ($0.effectivePercent, $0.resetsAt) }, label: tr("agents.week"), duration: Self.week)
            ]
        case .gemini, .opencode, .cursor, .grok, .acp:
            // No limits reported; ACP agents report context and cost per session instead.
            return []
        case .antigravity:
            return antigravity.limits
        case .codex:
            guard let snapshot = codex.snapshot(home: profile.home.map { _ in profile.homeURL }) else { return [] }
            return [
                window(snapshot.fiveHour.map { (Double($0.percent()), $0.resetsAt) }, label: tr("agents.fiveHour"),
                       duration: snapshot.fiveHour?.windowMinutes.map { TimeInterval($0 * 60) } ?? Self.fiveHours),
                window(snapshot.weekly.map { (Double($0.percent()), $0.resetsAt) }, label: tr("agents.week"),
                       duration: snapshot.weekly?.windowMinutes.map { TimeInterval($0 * 60) } ?? Self.week)
            ]
        }
    }

    private static let fiveHours: TimeInterval = 5 * 3600
    private static let week: TimeInterval = 7 * 24 * 3600

    /// A window as reported, or, when the agent reports none (or it has run out), an idle one: 0% that starts with the next message.
    private func window(_ reported: (percent: Double, resetsAt: Date?)?, label: String, duration: TimeInterval) -> QuotaLimit {
        if let reported, reported.resetsAt.map({ $0 > Date() }) ?? true {
            return QuotaLimit(label: label, percent: reported.percent, resetsAt: reported.resetsAt, duration: duration)
        }
        return QuotaLimit(label: label, percent: 0, resetsAt: nil, note: tr("agents.usage.startsOnMessage"))
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
