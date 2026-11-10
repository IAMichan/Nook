import Foundation

/// Finds what looks like a secret in text you paste into a session's composer: API keys and tokens with a known shape,
/// private keys, and a lone long random token. The composer then keeps each one out of the message: the value goes to a
/// private file (`SecretFiles`) and the message carries only a reference to it (see `ContextRef.Kind.secret`).
///
/// It errs on the side of quiet: a commit hash, a UUID, a path, an address or ordinary words never count, because a
/// message you meant to send must not change under your hands.
enum SecretPasteDetector {
    struct Match: Equatable {
        /// What it is, as a name for the secret (`OPENAI_API_KEY`): the variable an agent would put it in.
        var name: String
        var range: Range<String.Index>
    }

    /// Pastes longer than this are code or logs, not a key; only a private key block is looked for in them.
    static let scanLimit = 20_000
    /// A lone token shorter than this is never taken for a secret on its randomness alone.
    static let minimumGenericLength = 32
    /// Bits per character a lone token needs to count as random.
    static let minimumEntropy = 3.5

    private struct Rule {
        let name: String
        let regex: NSRegularExpression
    }

    private static let rules: [Rule] = {
        let table: [(String, String)] = [
            ("PRIVATE_KEY", #"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----[\s\S]+?-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----"#),
            ("ANTHROPIC_API_KEY", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
            ("OPENAI_API_KEY", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#),
            ("STRIPE_SECRET_KEY", #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
            ("GITHUB_TOKEN", #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})"#),
            ("GITLAB_TOKEN", #"\bglpat-[A-Za-z0-9_\-]{20,}"#),
            ("SLACK_TOKEN", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
            ("AWS_ACCESS_KEY_ID", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
            ("GOOGLE_API_KEY", #"\bAIza[0-9A-Za-z_\-]{35}"#),
            ("HUGGINGFACE_TOKEN", #"\bhf_[A-Za-z0-9]{30,}"#),
            ("NPM_TOKEN", #"\bnpm_[A-Za-z0-9]{36,}"#),
            ("JWT", #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
            // An assignment of a long value to a name that says it is secret: `API_KEY=…`, `"token": "…"`.
            ("SECRET", #"(?i)\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY)[A-Z0-9_]*["']?\s*[:=]\s*["']?([^\s"'`]{16,})"#)
        ]
        return table.compactMap { name, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(name: name, regex: $0) }
        }
    }()

    /// The secrets in `text`, in order and never overlapping; empty when there are none.
    static func matches(in text: String) -> [Match] {
        guard !text.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Match] = []
        let rules = text.utf16.count > scanLimit ? Self.rules.filter { $0.name == "PRIVATE_KEY" } : Self.rules
        for rule in rules {
            for result in rule.regex.matches(in: text, range: whole) {
                // An assignment keeps its name in the message; only the value goes.
                let nsRange = rule.name == "SECRET" && result.numberOfRanges > 1 ? result.range(at: 1) : result.range
                guard let range = Range(nsRange, in: text) else { continue }
                if rule.name == "SECRET", !isRandom(String(text[range]), minimumLength: 16) { continue }
                guard !found.contains(where: { $0.range.overlaps(range) }) else { continue }
                found.append(Match(name: rule.name == "SECRET" ? assignedName(text, before: range) : rule.name, range: range))
            }
        }
        if found.isEmpty, let lone = loneToken(in: text) { found.append(lone) }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// A paste that is one random-looking token and nothing else.
    private static func loneToken(in text: String) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumGenericLength, trimmed.count <= 512,
              !trimmed.contains(where: { $0.isWhitespace }), isRandom(trimmed, minimumLength: minimumGenericLength),
              let range = text.range(of: trimmed) else { return nil }
        return Match(name: "PASTED_SECRET", range: range)
    }

    /// Looks like a generated key: letters and digits mixed, no shape of a hash, an id, a path or an address, and random
    /// enough per character.
    static func isRandom(_ token: String, minimumLength: Int) -> Bool {
        guard token.count >= minimumLength else { return false }
        // Paths, addresses, domains and file names.
        if token.contains("/") || token.contains("\\") || token.contains("://") || token.contains("@") { return false }
        // A dot only in the three-part shape of a signed token (`SG.abc.def`), never a domain or a file name.
        if token.contains("."), token.range(of: #"^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}$"#, options: .regularExpression) == nil {
            return false
        }
        // A hex string is a commit, a checksum or a color, far more often than a key.
        if token.allSatisfy({ $0.isHexDigit }) { return false }
        // A UUID.
        if UUID(uuidString: token) != nil { return false }
        guard token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_+=.~".contains($0)) }) else { return false }
        let letters = token.filter(\.isLetter).count
        let digits = token.filter(\.isNumber).count
        guard letters > 0, digits > 0 else { return false }
        // Words in snake or camel case (`handle_secret_paste_for_composer`) have few digits and low entropy.
        let hasUpper = token.contains(where: \.isUppercase), hasLower = token.contains(where: \.isLowercase)
        guard hasUpper && hasLower || digits * 4 >= token.count else { return false }
        return entropy(token) >= minimumEntropy
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    /// The name in front of an assignment (`STRIPE_KEY=…` → STRIPE_KEY), or SECRET.
    private static func assignedName(_ text: String, before range: Range<String.Index>) -> String {
        let head = text[..<range.lowerBound]
        guard let name = head.range(of: #"([A-Za-z0-9_]+)["']?\s*[:=]\s*["']?$"#, options: .regularExpression) else { return "SECRET" }
        let word = head[name].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return word.isEmpty ? "SECRET" : word.uppercased()
    }

    /// `name`, or `name_2`, `name_3`… when `taken` holds it already.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var index = 2
        while taken.contains("\(name)_\(index)") { index += 1 }
        return "\(name)_\(index)"
    }
}
