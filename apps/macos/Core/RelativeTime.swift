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

    /// "14:05" in the app's language: the time of a message, a wake-up or a reset. One cached formatter for the whole
    /// app; never a `DateFormatter` with `dateFormat = "HH:mm"` of a view's own.
    static func clock(_ date: Date) -> String {
        formatter("HH:mm", locale: appLocale).string(from: date)
    }

    /// A list's time: "14:05" today, else the day ("Yesterday", "Monday", "12 Oct"), as a chat list shows it.
    static func clockOrDay(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return clock(date) }
        return ChatTimeline.dayLabel(date, now: now, locale: Locale(identifier: appLocale))
    }

    /// A message's time with its day: "14:05" today, else "Yesterday 14:05", "Monday 14:05", "12 Oct 14:05".
    static func dayAndClock(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return clock(date) }
        return ChatTimeline.dayLabel(date, now: now, locale: Locale(identifier: appLocale)) + " " + clock(date)
    }
}
