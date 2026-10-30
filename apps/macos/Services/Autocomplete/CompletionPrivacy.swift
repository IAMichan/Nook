import Foundation

/// Takes out what looks like a secret before text is kept as a writing sample or given to the model as context: card
/// numbers, IBANs, Dutch citizen service numbers (BSN), API keys and tokens, private keys, passwords after "password:" (in the
/// five languages Nook speaks) or in a setting named after one, bearer tokens, logins and signatures in links.
enum CompletionPrivacy {
    static let placeholder = "[redacted]"

    private enum Check { case none, luhn, elevenTest }

    // The literal is typed on its own: in one expression with the .map the compiler cannot infer .none/.luhn.
    private static let sources: [(String, Check)] = [
        (#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#, Check.none),
        (#"\b\d(?:[ -]?\d){12,18}\b"#, Check.luhn),
        (#"\b\d{9}\b|\b\d{4}\.\d{2}\.\d{3}\b"#, Check.elevenTest),
        (#"\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_\-]{16,}\b"#, Check.none),
        (#"\b(?:ghp|gho|ghu|ghs|github_pat|glpat|xox[abprs]|AKIA|AIza|re_|whsec_)[A-Za-z0-9_\-]{12,}\b"#, Check.none),
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, Check.none),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, Check.none),
        (#"(?i)\b(?:password|passwd|pwd|passphrase|wachtwoord|passwort|kennwort|mot de passe|mdp|contraseña|clave|secret|geheim|api[_-]?key|token|pincode|pin)\b\s*[:=]\s*\S+"#, Check.none),
        // A setting or environment variable named after a secret (DATABASE_PASSWORD=…, export GITHUB_TOKEN=…, "clientSecret": …):
        // the word sits inside a longer name, where `\b` does not see it.
        (#"(?i)\b[A-Za-z0-9_]*(?:password|passwd|secret|token|api_?key|access_?key|private_?key|credential)[A-Za-z0-9_]*"?\s*[:=]\s*"?[^\s",;]{4,}"#, Check.none),
        (#"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/\-]{16,}=*"#, Check.none),
        // A login in a link (https://user:password@host) and a signed link's signature (?sig=…, X-Amz-Signature=…).
        (#"\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s/:@]+:[^\s/@]+@"#, Check.none),
        (#"(?i)[?&][A-Za-z0-9_.\-]*sig(?:nature)?=[^&\s"'<>()\[\]]{8,}"#, Check.none),
    ]

    /// Any long run of letters and digits: catches keys without a known prefix, but also the identifiers tools hand back
    /// (event ids, commit hashes), so only the writing samples use it (see `sanitize(_:generic:)`).
    private static let genericSource = #"\b(?=[A-Za-z0-9+/_\-]*\d)(?=[A-Za-z0-9+/_\-]*[A-Za-z])[A-Za-z0-9+/_\-]{32,}={0,2}"#

    private static let patterns: [(NSRegularExpression, Check)] = sources.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    private static let genericPattern = try! NSRegularExpression(pattern: genericSource)

    /// `generic: false` keeps long identifiers and hashes, for text a model still has to act on.
    static func sanitize(_ text: String, generic: Bool = true) -> String {
        var result = text
        for (pattern, check) in patterns + (generic ? [(genericPattern, Check.none)] : []) {
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
