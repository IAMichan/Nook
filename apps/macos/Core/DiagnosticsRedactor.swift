import Foundation

/// Takes private data out of text before it leaves the Mac in a diagnostics export or a problem report: secrets and
/// tokens, mail addresses, phone numbers, IBANs, query strings of links and the user's name in file paths. Foundation
/// only, so it runs in the core tests. What it cannot recognise it leaves alone; the export says so and shows a preview
/// before anything is shared.
enum DiagnosticsRedactor {
    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        // Order matters: secrets first, then links, then personal details.
        let patterns: [(String, String)] = [
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer [secret]"),
            (#"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})"#, "[secret]"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|token|secret|password|passwd|authorization)\b(\s*[:=]\s*)("?)[^\s",;]+"#, "$1$2$3[secret]"),
            (#"(https?://[^\s?#"]+)\?[^\s"]*"#, "$1?[query]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
            (#"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#, "[iban]"),
            (#"\+\d[\d\s().-]{7,}\d"#, "[phone]"),
            (#"(?:/Users/|/home/)[^/\s]+"#, "~"),
            (#"[A-Za-z]:\\Users\\[^\\\s]+"#, "~"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(regex: $0, template: template) }
        }
    }()

    /// `text` with everything private replaced by a short marker such as `[email]`.
    static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    /// One export: a header of facts about this Nook (versions, what is set up) and the log lines, all redacted.
    static func report(header: [(String, String)], log: [String], now: Date = Date()) -> String {
        var lines = ["Nook diagnostics", "Created: \(ISO8601DateFormatter().string(from: now))"]
        lines += header.map { "\($0.0): \($0.1)" }
        lines += ["", "Log"]
        lines += log
        return redact(lines.joined(separator: "\n"))
    }
}

/// The log lines a diagnostics export carries: Nook's own (`Log`, read by `Log.recentEntries`), from the last minutes,
/// newest kept when there are too many, each cut to a sane length. Foundation only, so the selection is tested on its own.
enum DiagnosticsLog {
    struct Entry: Equatable, Sendable {
        var date: Date
        var category: String
        var level: String
        var message: String
    }

    /// How far back an export reads, and the most lines and characters per line it keeps.
    static let window: TimeInterval = 30 * 60
    static let lineLimit = 400
    static let messageLimit = 500

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// One piece of a logged message: the fixed text before an argument, the argument's placeholder as the format had it
    /// (`%{public}s`, `%s`, `%ld`), whether it is a number, and its value.
    struct Piece: Equatable, Sendable {
        var text: String
        var placeholder: String
        var isNumber: Bool
        var value: String?
    }

    /// A message as the export may show it. Within its own process macOS hands back every value, also those logged as
    /// private, so the privacy of each is applied here as Console.app would: a value marked public shows, a number
    /// without a mark shows (the system's default for numbers), and everything else (strings and objects without a mark,
    /// which are private by default, and anything marked private) is `<private>`.
    static func message(_ pieces: [Piece]) -> String {
        pieces.map { piece in
            guard !piece.placeholder.isEmpty else { return piece.text }
            let shown = piece.placeholder.contains("{public}") || (piece.isNumber && !piece.placeholder.contains("{private}"))
            return piece.text + (shown ? (piece.value ?? "") : "<private>")
        }.joined()
    }

    /// One line per entry, oldest first: "12:00:01.250 error storage: …". Entries older than `window` before `now` are
    /// left out, and of the rest only the newest `limit`.
    static func lines(_ entries: [Entry], now: Date = Date(), limit: Int = lineLimit) -> [String] {
        let recent = entries.filter { now.timeIntervalSince($0.date) <= window }.sorted { $0.date < $1.date }.suffix(limit)
        return recent.map { entry in
            let message = entry.message.replacingOccurrences(of: "\n", with: " ")
            let clipped = message.count > messageLimit ? String(message.prefix(messageLimit)) + "…" : message
            return "\(time.string(from: entry.date)) \(entry.level) \(entry.category): \(clipped)"
        }
    }
}
