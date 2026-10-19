import Foundation

enum NookDates {
    /// Parses ISO 8601 with or without timezone. Without timezone, the Mac's current timezone is used.
    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = isoPlain.date(from: trimmed) { return date }
        if let date = isoFractional.date(from: trimmed) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            if let date = formatter(format, locale: "en_US_POSIX").date(from: trimmed) { return date }
        }
        return nil
    }

    static func iso(_ date: Date) -> String {
        let zone = TimeZone.current
        let formatter = cached("iso|\(zone.identifier)") { () -> ISO8601DateFormatter in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = zone
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }
        return formatter.string(from: date)
    }

    /// Parsing only: the input names its own time zone, so these never change.
    static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: Formatter cache

    /// Building a formatter loads locale data and costs far more than using one, and these run for every row of every
    /// list on each redraw. Formatters are kept per format, locale and time zone (so a changed zone still gets a fresh one)
    /// and never changed after creation, which makes sharing them across threads safe.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var formatters: [String: AnyObject] = [:]

    static func cached<F: AnyObject>(_ key: String, make: () -> F) -> F {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = formatters[key] as? F { return hit }
        let made = make()
        formatters[key] = made
        return made
    }

    /// A date formatter for `format` in `locale`, in the Mac's current time zone.
    static func formatter(_ format: String, locale: String = "nl_NL") -> DateFormatter {
        let zone = TimeZone.current
        return cached("date|\(format)|\(locale)|\(zone.identifier)") { () -> DateFormatter in
            let f = DateFormatter()
            f.locale = Locale(identifier: locale)
            f.timeZone = zone
            f.dateFormat = format
            return f
        }
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
