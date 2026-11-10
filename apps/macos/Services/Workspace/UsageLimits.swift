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

    /// One line of the composer's limit chip: a window's short name and how much of it is used.
    struct ChipLine: Equatable {
        var short: String
        var used: Int
    }

    /// The composer chip's lines: the shortest and the longest window, each the fullest of the windows that last that long
    /// (an agent with a quota per model has several), in that order; one line when every window lasts as long.
    static func chipLines(_ windows: [(duration: TimeInterval?, percent: Double, window: String)]) -> [ChipLine] {
        var spans: [(duration: TimeInterval?, windows: [(duration: TimeInterval?, percent: Double, window: String)])] = []
        for window in windows {
            let key = window.duration.map { ($0 / 60).rounded() * 60 }
            if let index = spans.firstIndex(where: { $0.duration == key }) {
                spans[index].windows.append(window)
            } else {
                spans.append((key, [window]))
            }
        }
        spans.sort { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        let picked = spans.count > 1 ? [spans[0], spans[spans.count - 1]] : spans
        return picked.map { span in
            let percent = span.windows.map(\.percent).max() ?? 0
            return ChipLine(short: shortWindow(span.duration, fallback: span.windows[0].window),
                            used: Int(min(100, max(0, percent)).rounded()))
        }
    }

    /// "5h", "W", "3d": a window's length in a letter or two, to fit beside the chip's ring.
    static func shortWindow(_ duration: TimeInterval?, fallback: String) -> String {
        guard let duration, duration > 0 else { return String(fallback.prefix(2)) }
        let day: TimeInterval = 24 * 3600
        if duration < day { return tr("compose.limits.shortHours", max(1, Int((duration / 3600).rounded()))) }
        if duration >= 6 * day { return tr("compose.limits.shortWeek") }
        return tr("compose.limits.shortDays", Int((duration / day).rounded()))
    }

    /// The latest reset of the blocked windows; nil when one of them did not say when.
    /// An account's limit windows (percent used, reset): when every full one has reset. Nil when none is full or a
    /// full one has no reset time.
    static func fullWindowsReset(_ windows: [(percent: Double, resetsAt: Date?)], now: Date = Date()) -> Date? {
        let full = windows.filter { $0.percent >= 100 }
        guard !full.isEmpty, !full.contains(where: { $0.resetsAt == nil }) else { return nil }
        return full.compactMap(\.resetsAt).max().flatMap { $0 > now ? $0 : nil }
    }

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

    /// The percentage to indicate across a list of window percentages: only indicates 100% when all windows are full;
    /// otherwise shows the highest non-full window (capped at 99%).
    static func effectiveHighestPercent(_ percents: [Double]) -> Double {
        guard !percents.isEmpty else { return 0 }
        if percents.allSatisfy({ $0 >= 99.5 }) { return 100 }
        let nonFull = percents.filter { $0 < 99.5 }
        if let max = nonFull.max() { return min(99, max) }
        return 0
    }
}

/// When a limit resets, read from what the agent wrote, for the turns that carry no reset time of their own (no
/// `rate_limit_event`, no snapshot): Claude Code's "Claude AI usage limit reached|1736010000" and "You've hit your limit ·
/// resets 3pm (Europe/Amsterdam)", Codex's "try again at Nov 12th, 2026 3:04 PM", Gemini's "Please retry in 41.3s".
extension UsageLimits {
    /// When a waiting session goes on: a little after the reset, so the limit is really free again; without a reset
    /// time (or with one that turned out too early) a try after a pause that grows with each try.
    static func resumeDue(limitedAt: Date, reset: Date?, retries: Int) -> Date {
        if let reset, reset > limitedAt { return reset.addingTimeInterval(20) }
        return limitedAt.addingTimeInterval(retryDelay(retries))
    }

    /// 10, 20, 40 minutes, then every hour.
    static func retryDelay(_ retries: Int) -> TimeInterval {
        min(600 * pow(2, Double(min(max(retries, 0), 3))), 3_600)
    }

    static func textReset(_ text: String, now: Date = Date(), calendar base: Calendar = .current) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
        // Seconds since 1970 after a bar.
        if let match = epochPattern?.firstMatch(in: text, range: range), let seconds = group(match, 1).flatMap(Double.init) {
            let date = Date(timeIntervalSince1970: seconds)
            if date > now.addingTimeInterval(-86_400) { return date }
        }
        // "in 2 hours 5 minutes", "in 41.3s".
        if let match = relativePattern?.firstMatch(in: text, range: range), let span = group(match, 1) {
            var seconds = 0.0
            let parts = span as NSString
            for part in unitPattern?.matches(in: span, range: NSRange(location: 0, length: parts.length)) ?? [] {
                let value = Double(parts.substring(with: part.range(at: 1))) ?? 0
                let unit = parts.substring(with: part.range(at: 2)).lowercased()
                switch unit.first {
                case "d": seconds += value * 86_400
                case "h": seconds += value * 3_600
                case "m": seconds += value * 60
                default: seconds += value
                }
            }
            if seconds > 0 { return now.addingTimeInterval(seconds) }
        }
        // "resets 3pm", "resets at 15:30 (Europe/Amsterdam)", "try again at Nov 12th, 2026 3:04 PM".
        guard let match = clockPattern?.firstMatch(in: text, range: range),
              var hour = group(match, 4).flatMap(Int.init) else { return nil }
        let minute = group(match, 5).flatMap(Int.init) ?? 0
        let meridiem = group(match, 6)?.lowercased()
        guard meridiem != nil || group(match, 5) != nil, minute < 60 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard hour < 24 else { return nil }
        var calendar = base
        if let zone = group(match, 7).flatMap({ TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) }) {
            calendar.timeZone = zone
        }
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        let month = group(match, 1).flatMap { name in
            months.firstIndex { name.lowercased().hasPrefix($0) }.map { $0 + 1 }
        }
        if let month, let day = group(match, 2).flatMap(Int.init) {
            parts.month = month
            parts.day = day
            if let year = group(match, 3).flatMap(Int.init) { parts.year = year }
            guard var date = calendar.date(from: parts) else { return nil }
            // A date without a year that already passed this year is next year's.
            if group(match, 3) == nil, date < now.addingTimeInterval(-86_400),
               let next = calendar.date(byAdding: .year, value: 1, to: date) { date = next }
            return date
        }
        // A time of day alone is the next time the clock says so.
        guard let today = calendar.date(from: parts) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let epochPattern = try? NSRegularExpression(pattern: #"\|\s*(\d{10})(?!\d)"#)
    private static let unitPattern = try? NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#, options: .caseInsensitive)
    private static let relativePattern = try? NSRegularExpression(
        pattern: #"(?:try again|retry|resets?|available again)\s+in\s+((?:\d+(?:\.\d+)?\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b[\s,]*(?:and\s+)?)+)"#,
        options: .caseInsensitive)
    private static let clockPattern = try? NSRegularExpression(
        pattern: #"(?:resets?|try again|available again)(?:\s+at)?(?:\s+on)?\s+(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(?:(\d{4}),?\s*)?(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b(?:\s*\(([^)]+)\))?"#,
        options: .caseInsensitive)
}
