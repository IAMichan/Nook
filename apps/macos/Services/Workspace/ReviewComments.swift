import Foundation

// Comments on a session's diff, sent to the agent as one message, and quoting the agent's
// own words back into the composer. Foundation only, so tests can use it independently.

/// A remark on one line of a changed file.
struct ReviewComment: Identifiable, Equatable, Sendable {
    var id = UUID()
    var path: String
    /// Line number in the new version of the file; nil for a removed line.
    var line: Int?
    /// The diff line it is about, with its +, - or space.
    var code: String
    var text: String
}

enum ReviewComments {
    /// The line number in the new file for each line of a unified diff (nil for removed lines and headers).
    static func newLineNumbers(_ lines: [String]) -> [Int?] {
        var result: [Int?] = []
        // Inside a hunk: the number the next new-side line gets. Outside (file headers): nil.
        var next: Int?
        for line in lines {
            if line.hasPrefix("@@") {
                next = hunkStart(line)
                result.append(nil)
            } else if line.hasPrefix("diff ") {
                next = nil
                result.append(nil)
            } else if let current = next, !line.hasPrefix("-"), !line.hasPrefix("\\") {
                result.append(current)
                next = current + 1
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// "@@ -10,4 +12,6 @@" → 12.
    static func hunkStart(_ header: String) -> Int? {
        guard let plus = header.range(of: " +") else { return nil }
        let digits = header[plus.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// One message for the agent with every comment, grouped by file in the order they were made.
    static func message(_ comments: [ReviewComment]) -> String {
        let blocks = comments.map { comment -> String in
            let line = comment.line.map { " line=\"\($0)\"" } ?? ""
            return "<review_comment file=\"\(comment.path)\"\(line)>\n> \(comment.code)\n\(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n</review_comment>"
        }
        return "Review comments on your changes. Address each one:\n\n" + blocks.joined(separator: "\n\n")
    }

    /// The agent's words as a quote above what you write next.
    static func quote(_ text: String, into draft: String) -> String {
        let quoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return quoted + "\n\n" + (rest.isEmpty ? "" : rest)
    }
}
