import Foundation

/// What every chat bridge's data needs from a JSON answer, in one place: the object of an answer, an ISO 8601 date (with
/// or without a fraction, as Nook's chat helper, Microsoft Graph and the WhatsApp gateways write them), a number however
/// it is written, a date in seconds or milliseconds since 1970, and an id as one segment of a path.
/// Foundation only, so it can be tested anywhere.
enum ChatJSON {
    /// The JSON object of an answer; nil when it is none.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // Made once: a formatter is costly to make and a read parses a date per message. Parsing with one is thread-safe.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let withoutFraction = ISO8601DateFormatter()

    /// "2026-10-22T09:14:56.123Z" or "2026-10-22T09:14:56Z"; nil for anything else.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }

    /// A date as ISO 8601 without a fraction, in UTC ("2026-10-22T09:14:56Z"), as the gateways take one.
    static func iso(_ date: Date) -> String { withoutFraction.string(from: date) }

    /// A number however an answer writes it: a whole or a fractional number, or a numeral in a string. Nil for anything
    /// else.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A whole number however an answer writes it (TDLib's ids come as numbers or as strings). A fractional number is
    /// cut to its whole part; nil for anything else, or a number too large for 64 bits.
    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let text = value as? String, let number = Int64(text.trimmingCharacters(in: .whitespaces)) { return number }
        guard let number = number(value), number.isFinite, abs(number) < 9.2e18 else { return nil }
        return Int64(number)
    }

    /// Seconds since 1970, as a number or a numeral; nil when missing or not after 1970, so a missing date never
    /// becomes 1 January 1970.
    static func epoch(seconds value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Milliseconds since 1970, as a number or a numeral; nil when missing or not after 1970.
    static func epoch(millis value: Any?) -> Date? {
        guard let millis = number(value), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// An id as one segment of a URL path: "/", "?" and "#" in it are escaped, so it cannot leave its segment.
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
    }
}
