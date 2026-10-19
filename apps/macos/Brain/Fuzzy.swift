import Foundation

/// Names as people say or type them: "spotfy" is Spotify, "lsia" is Lisa, "rekenmachine" is the Calculator's Dutch name.
/// After open-source code (aliases, exact, words, then Levenshtein ≤ 2; MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
/// Tested in FuzzyTests.
enum Fuzzy {
    /// Lowercase, without accents, separators or a trailing ".app".
    static func fold(_ text: String) -> String {
        var out = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if out.hasSuffix(".app") { out = String(out.dropLast(4)) }
        return out.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// The candidate meant, or nil when nothing is close enough or two are equally close.
    static func best(_ query: String, in candidates: [String]) -> String? {
        let wanted = fold(query)
        guard !wanted.isEmpty else { return nil }
        let folded = candidates.map { ($0, fold($0)) }
        func unique(_ found: [(String, String)]) -> String? {
            let names = Set(found.map(\.0))
            return names.count == 1 ? names.first : nil
        }
        let exact = folded.filter { $0.1 == wanted }
        if !exact.isEmpty { return unique(exact) }
        let joined = folded.filter { $0.1.replacingOccurrences(of: " ", with: "") == wanted.replacingOccurrences(of: " ", with: "") }
        if !joined.isEmpty { return unique(joined) }
        let prefix = folded.filter { $0.1.hasPrefix(wanted + " ") || $0.1.split(separator: " ").contains { $0 == Substring(wanted) } }
        if !prefix.isEmpty { return unique(prefix) }
        // Typos: one mistake in a short name, two in a longer one.
        guard wanted.count >= 4 else { return nil }
        let allowed = wanted.count >= 7 ? 2 : 1
        let scored = folded.map { ($0, distance(wanted, $0.1)) }.filter { $0.1 <= allowed }
        guard let least = scored.map(\.1).min() else { return nil }
        return unique(scored.filter { $0.1 == least }.map(\.0))
    }

    /// Levenshtein distance (Wagner–Fischer), on characters.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
