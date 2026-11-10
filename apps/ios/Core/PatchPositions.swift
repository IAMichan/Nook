import Foundation

// Where a comment on a line of a pull request's patch lands (docs/COMPANION.md, "Pull requests"): GitHub's line number and
// side for each line of a unified diff, and the comment for a picked range. Foundation only, tested on the Mac.

enum PatchPositions {
    struct Position: Equatable, Sendable {
        var line: Int
        /// RIGHT for an added or unchanged line (its number in the new file), LEFT for a removed line (in the old one).
        var side: String
    }

    /// Each line's position; nil for a hunk header and for "\ No newline at end of file".
    static func positions(_ lines: [String]) -> [Position?] {
        var old = 0, new = 0
        var inHunk = false
        return lines.map { line in
            if line.hasPrefix("@@") {
                old = number(after: " -", in: line) ?? 0
                new = number(after: " +", in: line) ?? 0
                inHunk = true
                return nil
            }
            guard inHunk, !line.hasPrefix("\\") else { return nil }
            if line.hasPrefix("-") {
                defer { old += 1 }
                return Position(line: old, side: "LEFT")
            }
            if line.hasPrefix("+") {
                defer { new += 1 }
                return Position(line: new, side: "RIGHT")
            }
            defer { old += 1; new += 1 }
            return Position(line: new, side: "RIGHT")
        }
    }

    private static func number(after marker: String, in line: String) -> Int? {
        line.range(of: marker).flatMap { Int(line[$0.upperBound...].prefix { $0.isNumber }) }
    }

    /// The comment for the picked lines (indexes into `positions`): on the last picked line, starting at the first one on
    /// the same side when the range covers more than one. Nil when nothing picked can carry a comment.
    static func comment(path: String, picked: ClosedRange<Int>, positions: [Position?], body: String) -> CompanionPullAction.LineComment? {
        let inRange = picked.compactMap { $0 < positions.count ? positions[$0] : nil }
        guard let end = inRange.last else { return nil }
        let start = inRange.first { $0.side == end.side }
        let startLine = start.flatMap { $0.line < end.line ? $0.line : nil }
        return CompanionPullAction.LineComment(path: path, line: end.line, side: end.side, body: body, startLine: startLine)
    }
}
