import Foundation

enum NookDates {
    /// Leest ISO 8601 met of zonder tijdzone. Zonder tijdzone geldt de tijdzone van je Mac.
    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) { return date }
        }
        return nil
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = format
        return f
    }

    /// "vr 16 okt 14:00"
    static func short(_ date: Date) -> String {
        formatter("EEE d MMM HH:mm").string(from: date)
    }

    static func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    /// "VR"
    static func weekdayCaps(_ date: Date) -> String {
        formatter("EEE").string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }

    /// "woensdag"
    static func weekday(_ date: Date) -> String {
        formatter("EEEE").string(from: date)
    }

    /// "12 okt"
    static func dayMonth(_ date: Date) -> String {
        formatter("d MMM").string(from: date)
    }

    static func dayNumber(_ date: Date) -> String {
        formatter("d").string(from: date)
    }

    /// "net", "14:20", "gisteren", "ma" of "12 okt": hoe lang geleden, zo kort mogelijk.
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if Date().timeIntervalSince(date) < 90 { return "net" }
        if calendar.isDateInToday(date) { return time(date) }
        if calendar.isDateInYesterday(date) { return "gisteren" }
        if Date().timeIntervalSince(date) < 6 * 86_400 { return weekday(date) }
        return dayMonth(date)
    }

    /// "woensdag 14 oktober 2026 08:31"
    static func long(_ date: Date) -> String {
        formatter("EEEE d MMMM yyyy HH:mm").string(from: date)
    }
}
