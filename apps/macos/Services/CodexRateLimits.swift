import Foundation

/// Codex subscription plan usage: 5-hour window and weekly limits.
struct CodexUsageSnapshot: Equatable {
    struct Window: Equatable {
        /// Percentage used, 0–100, as reported by Codex.
        var usedPercent: Double
        /// Timestamp when this window resets. `nil` if not reported by Codex.
        var resetsAt: Date?
        /// Window duration in minutes (300 for 5 hours, 10080 for one week).
        var windowMinutes: Int?

        /// Current percentage: 0 if window has already reset.
        func percent(at date: Date = Date()) -> Int {
            if let resetsAt, resetsAt <= date { return 0 }
            return Int(min(100, max(0, usedPercent)).rounded())
        }
    }

    enum Source: Equatable {
        /// `codex app-server`, same source as `/status` in Codex.
        case appServer
        /// The last rate limit entry in a session log under ~/.codex/sessions.
        case sessionLog
    }

    /// Reset credits the account has banked: each one empties the 5-hour and weekly windows at once, when used.
    struct ResetCredits: Equatable {
        var available: Int
        /// When the first of the available credits expires, when Codex says.
        var nextExpiresAt: Date?
    }

    var fiveHour: Window?
    var weekly: Window?
    var planType: String?
    var updatedAt: Date
    var source: Source
    /// Only `codex app-server` reports these; nil when it did not (a session log, an older Codex).
    var resetCredits: ResetCredits? = nil

    /// E.g. "5 hours: 42% used · resets at 14:30".
    var fiveHourLabel: String? {
        guard let fiveHour else { return nil }
        var text = "5 hours: \(fiveHour.percent())% used"
        if let reset = fiveHour.resetsAt, reset > Date() {
            text += " · resets at \(Self.timeFormatter.string(from: reset))"
        }
        return text
    }

    /// E.g. "Weekly: 18% used · resets Thu Oct 16".
    var weeklyLabel: String? {
        guard let weekly else { return nil }
        var text = "Weekly: \(weekly.percent())% used"
        if let reset = weekly.resetsAt, reset > Date() {
            text += " · resets \(Self.dayFormatter.string(from: reset))"
        }
        return text
    }

    /// Highest of the two windows: the one you will reach first.
    var dominantPercent: Int? {
        [fiveHour?.percent(), weekly?.percent()].compactMap { $0 }.max()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// What Codex's app-server says about an account's limits, read without Codex running: the answer of
/// `account/rateLimits/read`, the `account/rateLimits/updated` a session sends while it works, and the outcome of using
/// a reset credit. Foundation only, so it is tested on its own (`CodexUsage` runs the app-server).
enum CodexRateLimits {
    /// What using a reset credit did, as `account/rateLimitResetCredit/consume` answers it.
    enum ResetOutcome: Equatable {
        /// The windows were emptied.
        case reset
        /// Nothing was used, so there was nothing to reset; the credit is kept.
        case nothingToReset
        /// No credit left (used elsewhere in the meantime).
        case noCredit
        /// This request was already redeemed (a retry of the same request).
        case alreadyRedeemed
        /// Codex is missing, did not answer, or answered something else.
        case failed
    }

    /// Reads an `account/rateLimits/read` response. primary and secondary are not fixed: duration determines which window it is.
    static func snapshot(read result: [String: Any], at date: Date = Date()) -> CodexUsageSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var snapshot = windows(limits, at: date)
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { return nil }
        snapshot.resetCredits = resetCredits(result["rateLimitResetCredits"])
        return snapshot
    }

    /// The params of an `account/rateLimits/updated` laid over what was shown. The update can name only one window; the
    /// other keeps what it showed, as do the plan and the reset credits. Nil when the update changes nothing to show: a
    /// model's own allowance (`limitId` other than "codex") must not overwrite the account's main one.
    static func merge(pushed params: [String: Any], into previous: CodexUsageSnapshot?, at date: Date = Date()) -> CodexUsageSnapshot? {
        guard let limits = params["rateLimits"] as? [String: Any] else { return nil }
        if let id = limits["limitId"] as? String, id != "codex" { return nil }
        let fresh = windows(limits, at: date)
        guard fresh.fiveHour != nil || fresh.weekly != nil else { return nil }
        var snapshot = previous ?? CodexUsageSnapshot(fiveHour: nil, weekly: nil, planType: nil, updatedAt: date, source: .appServer)
        if let window = fresh.fiveHour { snapshot.fiveHour = window }
        if let window = fresh.weekly { snapshot.weekly = window }
        if let plan = fresh.planType { snapshot.planType = plan }
        snapshot.updatedAt = date
        snapshot.source = .appServer
        return snapshot
    }

    /// The windows of a rate limit snapshot, wherever Codex wrote it: `rateLimits` of an app-server read or update
    /// (camelCase), or `rate_limits` of a `token_count` line in its session log (snake_case). `date`: when it was
    /// written, for a reset given in seconds from then.
    static func windows(_ limits: [String: Any], at date: Date, source: CodexUsageSnapshot.Source = .appServer) -> CodexUsageSnapshot {
        var snapshot = CodexUsageSnapshot(fiveHour: nil, weekly: nil,
                                          planType: (limits["planType"] as? String) ?? (limits["plan_type"] as? String),
                                          updatedAt: date, source: source)
        for (index, key) in ["primary", "secondary"].enumerated() {
            guard let window = window(limits[key], at: date) else { continue }
            assign(window, minutes: window.windowMinutes, isPrimary: index == 0, to: &snapshot)
        }
        return snapshot
    }

    /// One window (`primary`, `secondary`), in either spelling: its use, its length and when it resets (an absolute
    /// time, or seconds from `date`). Nil without a use.
    static func window(_ value: Any?, at date: Date) -> CodexUsageSnapshot.Window? {
        guard let raw = value as? [String: Any],
              let percent = number(raw["usedPercent"]) ?? number(raw["used_percent"]) else { return nil }
        let minutes = (number(raw["windowDurationMins"]) ?? number(raw["window_minutes"])).map { Int($0) }
        let reset = (number(raw["resetsAt"]) ?? number(raw["resets_at"])).map { Date(timeIntervalSince1970: $0) }
            ?? (number(raw["resetsInSeconds"]) ?? number(raw["resets_in_seconds"])).map { date.addingTimeInterval($0) }
        return CodexUsageSnapshot.Window(usedPercent: percent, resetsAt: reset, windowMinutes: minutes)
    }

    /// `rateLimitResetCredits`: `{availableCount, credits: [{status, expiresAt}]}`. Nil when Codex does not report them.
    static func resetCredits(_ value: Any?) -> CodexUsageSnapshot.ResetCredits? {
        guard let summary = value as? [String: Any], let count = number(summary["availableCount"]) else { return nil }
        let expiries = ((summary["credits"] as? [[String: Any]]) ?? [])
            .filter { ($0["status"] as? String) == "available" }
            .compactMap { number($0["expiresAt"]) }
        return CodexUsageSnapshot.ResetCredits(available: max(0, Int(count)),
                                               nextExpiresAt: expiries.min().map { Date(timeIntervalSince1970: $0) })
    }

    /// The `outcome` of an `account/rateLimitResetCredit/consume` answer.
    static func resetOutcome(_ result: [String: Any]) -> ResetOutcome {
        switch result["outcome"] as? String {
        case "reset": return .reset
        case "nothingToReset": return .nothingToReset
        case "noCredit": return .noCredit
        case "alreadyRedeemed": return .alreadyRedeemed
        default: return .failed
        }
    }

    /// A window by its length: a day or shorter is the 5-hour one, longer the weekly one; without a length, primary is
    /// the short one.
    static func assign(_ window: CodexUsageSnapshot.Window, minutes: Int?, isPrimary: Bool, to snapshot: inout CodexUsageSnapshot) {
        let isShort = minutes.map { $0 <= 24 * 60 } ?? isPrimary
        if isShort { snapshot.fiveHour = window } else { snapshot.weekly = window }
    }

    static func number(_ value: Any?) -> Double? { JSONNumber.double(value) }
}
