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

    /// Numeric dates written in the text: "2027-09-20", "20-09-2027" or "20/9/2027". A portable backstop for the system's date detector.
    static func numericDates(in text: String) -> [Date] {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b|\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})\b"#) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Date? in
            let number = { (group: Int) -> Int? in
                Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
            }
            let isoOrder = number(1) != nil
            guard let year = number(isoOrder ? 1 : 6), let month = number(isoOrder ? 2 : 5), let day = number(isoOrder ? 3 : 4),
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
    }

    /// An offer without an action must not ask anything: accepting a question ("Shall I…?") would then do nothing,
    /// wherever in the text the question sits.
    static func asksWithoutAction(_ body: String, hasActions: Bool) -> Bool {
        !hasActions && body.contains("?")
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
