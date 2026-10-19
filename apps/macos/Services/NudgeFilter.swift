import Foundation

/// Pure checks that keep think-along offers useful: a clean teaser line, no offers about things far away,
/// and no repeats of a suggestion that was only reworded.
enum NudgeFilter {
    /// Dates further away than this are never a reason to interrupt the user.
    static let horizon: TimeInterval = 14 * 24 * 3600

    /// Concise teaser beside the notch: the first sentence of the offer, max ~64 characters.
    /// A period inside a word ("IMDigital.info", "v1.2") does not end the sentence.
    static func line(body: String, fallback: String?) -> String {
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var line = first
        var index = first.startIndex
        while index < first.endIndex {
            let next = first.index(after: index)
            if "?.!".contains(first[index]), next == first.endIndex || first[next].isWhitespace {
                line = String(first[...index])
                break
            }
            index = next
        }
        line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if line.isEmpty { line = fallback ?? "" }
        return line.count > 64 ? String(line.prefix(62)) + "…" : line
    }

    /// True when the offer is about dates that are all well in the future: a renewal next year is no reason to speak up now.
    static func isFarOff(_ dates: [Date], now: Date = Date()) -> Bool {
        guard !dates.isEmpty else { return false }
        return dates.allSatisfy { $0.timeIntervalSince(now) > horizon }
    }

    /// Lowercased letters, digits and single spaces.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Two offers say the same thing when most of their meaningful words overlap, even if the brain rephrased them.
    static func similar(_ a: String, _ b: String) -> Bool {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return normalize(a) == normalize(b) }
        let overlap = Double(left.intersection(right).count) / Double(left.union(right).count)
        return overlap >= 0.6
    }

    private static func words(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 3 })
    }
}
