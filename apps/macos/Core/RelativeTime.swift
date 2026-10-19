import Foundation

extension NookDates {
    /// How long ago, in the app's language: "just now", "12 min ago", "today 14:20", "yesterday 09:12", "Tue Oct 14".
    /// The one relative-time text for the whole app (lists, sessions, source status, context lines).
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return tr("agents.justNow") }
        if seconds < 3600 { return tr("agents.minAgo", Int(seconds / 60)) }
        let calendar = Calendar.current
        let language = I18n.shared.language.rawValue
        let time = formatter("HH:mm", locale: language)
        if calendar.isDateInToday(date) { return tr("agents.todayAt", time.string(from: date)) }
        if calendar.isDateInYesterday(date) { return tr("agents.yesterdayAt", time.string(from: date)) }
        return formatter("EEE d MMM", locale: language).string(from: date)
    }
}
