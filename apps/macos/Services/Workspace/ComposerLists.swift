import Foundation

/// Markdown lists keep going while you write a prompt: a new line after `- item` starts with
/// `- `, after `- [x] done` with `- [ ] `, after `7. step` with `8. ` (zero padding kept: `07.` → `08.`), and a new
/// line after an item you left empty ends the list by removing its marker. Only a line break typed at the end of the
/// text is continued, since the field cannot say where the caret is.
enum ComposerLists {
    private enum Marker {
        case bullet(indent: String, bullet: Character)
        case task(indent: String)
        case ordered(indent: String, number: String, delimiter: Character)
    }

    private static let ordered = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,9})([.)])[ \t]+"#)
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)-[ \t]\[[ xX]\][ \t]+"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+"#)

    /// The text after a line break was typed at the end of `old`, or nil to leave `new` as it is.
    static func continued(old: String, new: String) -> String? {
        guard new == old + "\n" else { return nil }
        let line = old.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? old
        guard let (marker, end) = parse(line) else { return nil }
        let content = line.utf16.count > end ? String(line.utf16.dropFirst(end)) ?? "" : ""
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: the list ends, and the line is left empty.
            return String(old.dropLast(line.count))
        }
        return new + next(marker)
    }

    private static func parse(_ line: String) -> (Marker, Int)? {
        let range = NSRange(line.startIndex..., in: line)
        func text(_ match: NSTextCheckingResult, _ group: Int) -> String {
            Range(match.range(at: group), in: line).map { String(line[$0]) } ?? ""
        }
        if let match = task.firstMatch(in: line, range: range) {
            return (.task(indent: text(match, 1)), match.range.length)
        }
        if let match = ordered.firstMatch(in: line, range: range) {
            return (.ordered(indent: text(match, 1), number: text(match, 2), delimiter: text(match, 3).first ?? "."), match.range.length)
        }
        if let match = bullet.firstMatch(in: line, range: range) {
            return (.bullet(indent: text(match, 1), bullet: text(match, 2).first ?? "-"), match.range.length)
        }
        return nil
    }

    private static func next(_ marker: Marker) -> String {
        switch marker {
        case .bullet(let indent, let bullet):
            return "\(indent)\(bullet) "
        case .task(let indent):
            return "\(indent)- [ ] "
        case .ordered(let indent, let number, let delimiter):
            guard let value = Int(number) else { return "\(indent)\(number)\(delimiter) " }
            var following = String(value + 1)
            if number.hasPrefix("0"), following.count < number.count {
                following = String(repeating: "0", count: number.count - following.count) + following
            }
            return "\(indent)\(following)\(delimiter) "
        }
    }
}
