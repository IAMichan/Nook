import Foundation

/// What every chat bridge's data needs from a JSON answer, in one place: the object of an answer, an ISO 8601 date (with
/// or without a fraction, as Beeper, Nook's helper and Microsoft Graph write them) and an id as one segment of a path.
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

    /// An id as one segment of a URL path: "/", "?" and "#" in it are escaped, so it cannot leave its segment.
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
    }
}
