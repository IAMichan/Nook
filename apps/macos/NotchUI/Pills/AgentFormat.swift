import Foundation

/// Text formatting shared by the agent views: durations, reset times, session titles and model names.
enum AgentFormat {
    private static let formatterLock = NSLock()
    private static var cachedLanguage: String = ""
    private static var cachedTimeFormatter = DateFormatter()
    private static var cachedDayFormatter = DateFormatter()
    private static var cachedWeekdayFormatter = DateFormatter()
    private static let tagStripperRegex = try? NSRegularExpression(pattern: "<[^>]*>?")
    private static let titleTrimSet = CharacterSet(charactersIn: "#*-:· ")

    private static func updateFormattersIfNeeded() {
        let lang = I18n.shared.language.rawValue
        guard cachedLanguage != lang else { return }
        cachedLanguage = lang
        let locale = Locale(identifier: lang)
        cachedTimeFormatter.locale = locale
        cachedTimeFormatter.dateFormat = "HH:mm"
        cachedDayFormatter.locale = locale
        cachedDayFormatter.dateFormat = "EEE d MMM"
        cachedWeekdayFormatter.locale = locale
        cachedWeekdayFormatter.dateFormat = "EEEEEE"
    }

    private static func formatTime(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        updateFormattersIfNeeded()
        return cachedTimeFormatter.string(from: date)
    }

    private static func formatDay(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        updateFormattersIfNeeded()
        return cachedDayFormatter.string(from: date)
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

    static func weekdayLetter(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        updateFormattersIfNeeded()
        return cachedWeekdayFormatter.string(from: date)
    }

    /// A session title stripped of tags Claude Code sometimes prefixes ("<pasted_content …>").
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
