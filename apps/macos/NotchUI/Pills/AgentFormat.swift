import Foundation

/// Text formatting shared by the agent views: durations, reset times, session titles and model names.
enum AgentFormat {
    private static let tagStripperRegex = try? NSRegularExpression(pattern: "<[^>]*>?")
    private static let titleTrimSet = CharacterSet(charactersIn: "#*-:· ")

    private static func formatTime(_ date: Date) -> String {
        NookDates.clock(date)
    }

    private static func formatDay(_ date: Date) -> String {
        NookDates.formatter("EEE d MMM", locale: NookDates.appLocale).string(from: date)
    }

    /// "< 1 min", "12 min", "1 h 20 m", "3 d".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return tr("agents.duration.lessThanMinute") }
        if minutes < 60 { return tr("agents.duration.minutes", minutes) }
        let hours = minutes / 60
        if hours < 48 {
            return minutes % 60 == 0
                ? tr("agents.duration.hours", hours)
                : tr("agents.duration.hoursMinutes", hours, minutes % 60)
        }
        return tr("agents.duration.days", hours / 24)
    }

    /// Short, for lists: "now", "12 min", "3 h", "2 d".
    static func short(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return tr("agents.time.now") }
        if minutes < 60 { return tr("agents.time.minutes", minutes) }
        let hours = minutes / 60
        if hours < 24 { return tr("agents.time.hours", hours) }
        return tr("agents.time.days", hours / 24)
    }

    /// "resets at 15:40" or "resets Thu Oct 16".
    static func reset(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        if date.timeIntervalSinceNow < 20 * 3600 { return tr("agents.resetAt", formatTime(date)) }
        return tr("agents.resetOn", formatDay(date))
    }

    /// When a limit resets, as a clock time: "17:30" today, "Tue 4 Nov 17:30" later.
    static func upcoming(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? formatTime(date) : "\(formatDay(date)) \(formatTime(date))"
    }

    /// How long until a limit resets, compact: "2d 3h", "2h 14m", "14m".
    static func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        let (days, hours) = (minutes / 1440, minutes % 1440 / 60)
        if days > 0 { return tr("limits.duration.days", days, hours) }
        if hours > 0 { return tr("limits.duration.hours", hours, minutes % 60) }
        return tr("limits.duration.minutes", minutes)
    }

    /// "resets in 2h 14m", "resets now", or nil without a reset time.
    static func resetsIn(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if date <= now { return tr("limits.resetsNow") }
        return tr("limits.resetsIn", compactDuration(date.timeIntervalSince(now)))
    }

    static func weekdayLetter(_ date: Date) -> String {
        NookDates.formatter("EEEEEE", locale: NookDates.appLocale).string(from: date)
    }

    /// A live session's title: what it was first asked (its transcript's title, else the first prompt Nook heard), so a
    /// new prompt never renames it. The latest prompt and then the agent's last answer only stand in while nothing else
    /// is known.
    static func sessionTitle(_ session: AgentSession, known: PastSession?) -> String {
        if let known, !known.title.isEmpty { return title(known.title) }
        if !session.firstPrompt.isEmpty { return title(session.firstPrompt) }
        if !session.lastPrompt.isEmpty { return title(session.lastPrompt) }
        if !session.summary.isEmpty { return title(session.summary) }
        return ""
    }

    static func title(_ raw: String) -> String {
        var text = InjectedPrompt.title(raw)
        if text.contains("<"), let regex = tagStripperRegex {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: titleTrimSet)
        if text.isEmpty { return raw.contains("pasted") ? tr("agents.pastedText") : tr("agents.untitledSession") }
        return text
    }

    /// A model id as a name: "claude-sonnet-5-5" and "claude-3-5-sonnet-20241022" read "Claude Sonnet 5.5" and
    /// "Claude Sonnet 3.5"; other agents' models stay as they are.
    static func model(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespaces)
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        guard id.lowercased().hasPrefix("claude-") else { return id }
        var parts = id.split(separator: "-").map(String.init)
        // A release date at the end ("20241022").
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.filter { Int($0) == nil }.map(\.capitalized)
        let numbers = parts.filter { Int($0) != nil }
        return (words + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")])).joined(separator: " ")
    }
}

/// A single subscription limit: percentage consumed and reset time.
struct UsageLimit: Identifiable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var id: String { label }
}
