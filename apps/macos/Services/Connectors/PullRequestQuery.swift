import Foundation

/// The pull request search split into its words and the qualifiers typed in it:
/// `label:bug` (also `label:bug,ui` for either, `-label:wip` to leave one out, and a scoped label such as `area:ui`
/// written bare), `author:ada`, `draft:true` or `draft:false`, `review:approved` / `changes-requested` / `required` /
/// `none`, `checks:passing` / `failing` / `pending` (or `status:`), and Nook's own `repo:owner/name`. A qualifier
/// typed here wins over the same choice in the Filters dropdown. Foundation only, so tests can use it.
struct PullRequestQuery: Equatable, Sendable {
    /// The words left over, lowercased; every one must appear in the row.
    var words: [String] = []
    /// Each group needs one of its labels; all groups must hold.
    var labels: [[String]] = []
    var excludedLabels: [String] = []
    var author: String?
    var draft: PullRequestFilter.Draft?
    var review: PullRequestFilter.Review?
    var checks: PullRequestFilter.Status?
    var repo: String?

    private static let maxValues = 10
    private static let maxLength = 200

    static func parse(_ raw: String) -> PullRequestQuery {
        var query = PullRequestQuery()
        for token in tokens(raw) {
            guard let (negated, key, rawValue) = qualifier(token) else {
                query.words.append(token.lowercased())
                continue
            }
            let value = clean(rawValue)
            guard !value.isEmpty else { query.words.append(token.lowercased()); continue }
            switch key.lowercased() {
            case "label":
                let names = list(rawValue)
                if names.isEmpty { query.words.append(token.lowercased()) }
                else if negated { query.excludedLabels += names } else { query.labels.append(names) }
            case "author" where !negated:
                query.author = String((value.hasPrefix("@") ? String(value.dropFirst()) : value).prefix(maxLength))
            case "draft" where !negated && ["true", "false"].contains(value.lowercased()):
                query.draft = value.lowercased() == "true" ? .drafts : .ready
            case "review" where !negated && review(value) != nil:
                query.review = review(value)
            case "checks" where !negated && checks(value) != nil, "status" where !negated && checks(value) != nil:
                query.checks = checks(value)
            case "repo" where !negated:
                query.repo = String(value.prefix(maxLength))
            case "author", "draft", "review", "checks", "status", "repo":
                query.words.append(token.lowercased())
            default:
                // Anything else with a colon is a scoped label ("area:ui"), unless it reads as a path or an address.
                guard !value.hasPrefix("/") else { query.words.append(token.lowercased()); continue }
                let names = list(rawValue).map { $0.contains(":") ? $0 : key + ":" + $0 }
                if negated { query.excludedLabels += names } else { query.labels.append(names) }
            }
        }
        query.labels = Array(query.labels.prefix(maxValues))
        query.excludedLabels = Array(query.excludedLabels.prefix(maxValues))
        return query
    }

    /// The query without the qualifiers named in `keys` ("draft", "review" …), for when the same choice changes in the
    /// Filters dropdown: left in, the typed one would keep winning over what was just picked.
    static func removing(_ keys: Set<String>, from raw: String) -> String {
        tokens(raw).filter { token in
            guard let (_, key, _) = qualifier(token) else { return true }
            return !keys.contains(key.lowercased())
        }.joined(separator: " ")
    }

    /// Words, where a quoted part keeps its spaces: `label:"good first issue"` is one token.
    static func tokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in raw {
            if character == "\"" { quoted.toggle() }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// `-key:value` as (negated, key, value); nil for a plain word. A key starts with a letter, so "12:30" stays a word.
    private static func qualifier(_ token: String) -> (Bool, String, String)? {
        let negated = token.hasPrefix("-")
        let body = negated ? String(token.dropFirst()) : token
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = String(body[..<colon])
        guard let first = key.first, first.isASCII, first.isLetter,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return (negated, key, String(body[body.index(after: colon)...]))
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// "bug,ui" or `"good first issue",docs` as names, at most ten, each at most 200 characters.
    private static func list(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in raw {
            if character == "\"" { quoted.toggle(); continue }
            if character == "," && !quoted { parts.append(current); current = "" } else { current.append(character) }
        }
        parts.append(current)
        return parts.map { String($0.trimmingCharacters(in: .whitespaces).prefix(maxLength)) }
            .filter { !$0.isEmpty }
            .prefix(maxValues)
            .map { $0 }
    }

    private static func review(_ value: String) -> PullRequestFilter.Review? {
        switch value.lowercased() {
        case "approved": return .approved
        case "changes_requested", "changes-requested", "changes": return .changesRequested
        case "required", "review-required", "review_required": return .required
        case "none": return .noReviews
        default: return nil
        }
    }

    private static func checks(_ value: String) -> PullRequestFilter.Status? {
        switch value.lowercased() {
        case "success", "passing": return .passing
        case "failure", "failing": return .failing
        case "pending", "running": return .pending
        default: return nil
        }
    }
}
