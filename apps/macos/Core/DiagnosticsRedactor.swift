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
