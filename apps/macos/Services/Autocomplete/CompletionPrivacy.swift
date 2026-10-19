import Foundation

/// Takes out what looks like a secret before text is kept as a writing sample or given to the model as context: card
/// numbers, IBANs, Dutch citizen service numbers (BSN), API keys and tokens, private keys, passwords after "password:".
/// After Typist's sanitizer (MIT, © 2026 Brody Salvucci), with the BSN check added.
enum CompletionPrivacy {
    static let placeholder = "[redacted]"

    private enum Check { case none, luhn, elevenTest }

    private static let patterns: [(NSRegularExpression, Check)] = [
        (#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#, .none),
        (#"\b\d(?:[ -]?\d){12,18}\b"#, .luhn),
        (#"\b\d{9}\b|\b\d{4}\.\d{2}\.\d{3}\b"#, .elevenTest),
        (#"\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_\-]{16,}\b"#, .none),
        (#"\b(?:ghp|gho|ghu|ghs|github_pat|glpat|xox[abprs]|AKIA|AIza|re_|whsec_)[A-Za-z0-9_\-]{12,}\b"#, .none),
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, .none),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, .none),
        (#"\b(?=[A-Za-z0-9+/_\-]*\d)(?=[A-Za-z0-9+/_\-]*[A-Za-z])[A-Za-z0-9+/_\-]{32,}={0,2}"#, .none),
        (#"(?i)\b(?:password|passwd|pwd|wachtwoord|secret|geheim|api[_-]?key|token|pincode|pin)\b\s*[:=]\s*\S+"#, .none),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func sanitize(_ text: String) -> String {
        var result = text
        for (pattern, check) in patterns {
            let source = result as NSString
            var output = ""
            var cursor = 0
            for match in pattern.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                let candidate = source.substring(with: match.range)
                switch check {
                case .luhn where !passesLuhn(candidate): continue
                case .elevenTest where !passesElevenTest(candidate): continue
                default: break
                }
                output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + placeholder
                cursor = match.range.location + match.range.length
            }
            result = output + source.substring(from: cursor)
        }
        return result
    }

    static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            let doubled = offset % 2 == 1 ? digit * 2 : digit
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum % 10 == 0
    }

    /// The BSN "elfproef": 9×d1 + 8×d2 + … + 2×d8 − 1×d9 is a multiple of 11 (and not zero).
    static func passesElevenTest(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == 9, digits.contains(where: { $0 != 0 }) else { return false }
        let sum = (0..<8).reduce(0) { $0 + (9 - $1) * digits[$1] } - digits[8]
        return sum % 11 == 0
    }
}
