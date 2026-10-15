import Foundation

enum NookDates {
    /// Parses ISO 8601 with or without timezone. Without timezone, the Mac's current timezone is used.
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

    /// "Fri 16 Oct 14:00"
    static func short(_ date: Date) -> String {
        formatter("EEE d MMM HH:mm").string(from: date)
    }

    static func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    /// "FRI"
    static func weekdayCaps(_ date: Date) -> String {
        formatter("EEE").string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }

    /// "Wednesday"
    static func weekday(_ date: Date) -> String {
        formatter("EEEE").string(from: date)
    }

    /// "12 Oct"
    static func dayMonth(_ date: Date) -> String {
        formatter("d MMM").string(from: date)
    }

    static func dayNumber(_ date: Date) -> String {
        formatter("d").string(from: date)
    }

    /// "Wednesday 14 October 2026"
    static func day(_ date: Date) -> String {
        formatter("EEEE d MMMM yyyy").string(from: date)
    }

    /// "Wednesday 14 October 2026 08:31"
    static func long(_ date: Date) -> String {
        formatter("EEEE d MMMM yyyy HH:mm").string(from: date)
    }
}
