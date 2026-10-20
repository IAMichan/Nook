import Foundation

/// A usage limit that stopped a turn, so the session can go on by itself once the
/// limit resets. Claude Code says so in `rate_limit_event` (status "rejected", `resetsAt`); Codex with the error code
/// `usageLimitExceeded` and its rate limit snapshot (`account/rateLimits/updated`).
enum UsageLimits {
    /// What a session sends when it goes on after the reset.
    static let resumeMessage = "Continue where you left off."

    struct ClaudeEvent: Equatable, Sendable {
        /// "five_hour", "seven_day", "seven_day_opus", …
        var window: String
        /// Rejected and no extra usage to fall back on: the turn waits.
        var blocked: Bool
        var resetsAt: Date?
    }

    /// `rate_limit_event.rate_limit_info`.
    static func claudeEvent(_ info: [String: Any]) -> ClaudeEvent? {
        guard let status = info["status"] as? String else { return nil }
        let overage = (info["overageStatus"] as? String).map { $0 == "allowed" || $0 == "allowed_warning" } ?? false
        let usingOverage = (info["isUsingOverage"] as? Bool) == true || (info["overageInUse"] as? Bool) == true
        let reset = ClaudeStreamParser.number(info["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        return ClaudeEvent(window: (info["rateLimitType"] as? String) ?? "five_hour",
                           blocked: status == "rejected" && !overage && !usingOverage, resetsAt: reset)
    }

    /// How full one subscription window is: the same numbers the status line shows, read from Claude Code's own output.
    struct PlanReading: Equatable, Sendable {
        /// "five_hour" or "seven_day".
        var window: String
        var usedPercent: Double
        var resetsAt: Date
    }

    /// `rate_limit_event.rate_limit_info` with its `utilization` (a fraction) and `resetsAt`; nil for another window or
    /// without those numbers.
    static func planReading(_ info: [String: Any]) -> PlanReading? {
        let window = (info["rateLimitType"] as? String) ?? "five_hour"
        guard window == "five_hour" || window == "seven_day",
              let utilization = ClaudeStreamParser.number(info["utilization"]),
              let reset = ClaudeStreamParser.number(info["resetsAt"]) else { return nil }
        let percent = utilization <= 1 ? utilization * 100 : utilization
        return PlanReading(window: window, usedPercent: min(100, max(0, percent)), resetsAt: Date(timeIntervalSince1970: reset))
    }

    /// The `get_usage` control reply of Claude Code: both windows as claude.ai reports them (`utilization` 0–100,
    /// `resets_at` ISO 8601). A window that is missing has not started. Nil when the account has no plan limits (API key,
    /// or Claude Code could not read them).
    static func claudeUsageReply(_ response: [String: Any]) -> [PlanReading]? {
        guard let limits = response["rate_limits"] as? [String: Any] else { return nil }
        return ["five_hour", "seven_day"].compactMap { key in
            guard let raw = limits[key] as? [String: Any],
                  let percent = ClaudeStreamParser.number(raw["utilization"]),
                  let text = raw["resets_at"] as? String,
                  let reset = NookDates.isoFractional.date(from: text) ?? NookDates.isoPlain.date(from: text) else { return nil }
            return PlanReading(window: key, usedPercent: min(100, max(0, percent)), resetsAt: reset)
        }
    }

    /// The latest reset of the blocked windows; nil when one of them did not say when.
    static func latestReset(_ windows: [String: Date?]) -> Date? {
        guard !windows.isEmpty, !windows.values.contains(where: { $0 == nil }) else { return nil }
        return windows.values.compactMap { $0 }.max()
    }

    /// Codex's `codexErrorInfo`: a plain code ("usageLimitExceeded") or an object keyed by the code.
    static func codexErrorCode(_ info: Any?) -> String? {
        if let code = info as? String { return code }
        return (info as? [String: Any])?.keys.sorted().first
    }

    static func isCodexUsageLimit(_ info: Any?) -> Bool {
        let code = codexErrorCode(info)
        return code == "usageLimitExceeded" || code == "rateLimitExceeded"
    }

    /// When Codex may go on: the latest reset among the windows at 100 %; nil when one of those has no reset time.
    static func codexReset(_ params: [String: Any]) -> Date? {
        let snapshot = (params["rateLimits"] as? [String: Any]) ?? params
        if let limit = snapshot["limitId"] as? String, limit != "codex" { return nil }
        let full = ["primary", "secondary"].compactMap { snapshot[$0] as? [String: Any] }
            .filter { (ClaudeStreamParser.number($0["usedPercent"]) ?? 0) >= 100 }
        guard !full.isEmpty else { return nil }
        let resets = full.map { ClaudeStreamParser.number($0["resetsAt"]).map { Date(timeIntervalSince1970: $0) } }
        guard !resets.contains(where: { $0 == nil }) else { return nil }
        return resets.compactMap { $0 }.max()
    }
}
