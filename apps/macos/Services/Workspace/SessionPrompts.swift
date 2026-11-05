import Foundation

// What the side panel hands to a session's agent: the text that lands in its composer, for you to read and send.
// Foundation only, so tests can use it independently. It only builds text, so every coding agent gets the same words.
// Whatever comes from outside (a comment, a check's name, a page) is marked as data for the agent, not as an order.

/// The pull request a prompt is about.
struct SessionPullRequestRef: Equatable, Sendable {
    var number: Int
    var title: String
    var url: String
    var headBranch: String
    var baseBranch: String
}

enum SessionPrompts {
    /// A block above what you already wrote, the way terminal output and quotes land in the composer.
    static func merging(_ block: String, into draft: String) -> String {
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text + "\n\n" + rest
    }

    /// Text from outside inside a tag, with anything that would close the tag taken out.
    static func untrusted(_ tag: String, _ text: String) -> String {
        let clean = text.replacingOccurrences(of: "</\(tag)", with: "<\\/\(tag)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "<\(tag)>\n\(clean)\n</\(tag)>"
    }

    private static func describe(_ pull: SessionPullRequestRef) -> String {
        "pull request #\(pull.number) (\(pull.url)), branch \(pull.headBranch) into \(pull.baseBranch)"
    }

    private static func title(_ pull: SessionPullRequestRef) -> String {
        untrusted("pull_request_title", pull.title)
    }

    static func explain(_ pull: SessionPullRequestRef) -> String {
        "Explain \(describe(pull)): what it changes, why, and what a reviewer should look at first.\n\n" + title(pull)
    }

    /// Only points at the pull request: the question is yours to write.
    static func ask(_ pull: SessionPullRequestRef) -> String {
        "About \(describe(pull)):\n\n" + title(pull)
    }

    static func resolveConflicts(_ pull: SessionPullRequestRef) -> String {
        "Check out \(pull.headBranch), bring in \(pull.baseBranch), resolve the merge conflicts of \(describe(pull)) "
            + "and show me the result before you push."
    }

    /// Everything that fails, so one message covers them.
    static func fixChecks(_ pull: SessionPullRequestRef, failing: [String]) -> String {
        let names = failing.map { "- " + $0 }.joined(separator: "\n")
        return "These checks fail on \(describe(pull)). Find out why and fix them:\n\n"
            + untrusted("failing_checks", names)
    }

    static func fixComment(_ pull: SessionPullRequestRef, author: String, path: String?, line: Int?, text: String) -> String {
        let place = path.map { path in " on \(path)" + (line.map { ":\($0)" } ?? "") } ?? ""
        return "@\(author) commented\(place) on \(describe(pull)). Decide whether it is right and, if so, fix it:\n\n"
            + untrusted("review_comment", text)
    }

    /// A remark on one line of a file you read in the side panel.
    static func fileLine(path: String, line: Int, code: String, note: String) -> String {
        "About \(path):\(line): \(note.trimmingCharacters(in: .whitespacesAndNewlines))\n\n> \(code)"
    }

    /// An element you pointed at in Nook's browser, with what you said about it.
    static func pageElement(url: String, selector: String, text: String, note: String) -> String {
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return "About this element on \(url) (\(selector))" + (said.isEmpty ? ":" : ": \(said)") + "\n\n"
            + untrusted("page_element", text)
    }
}

/// The task boxes of a markdown text ("- [ ] step"), outside code fences.
enum MarkdownTasks {
    /// The line of each box, in order.
    static func lines(in text: String) -> [Int] {
        var fence = false
        var found: [Int] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence.toggle()
                continue
            }
            if !fence, boxRange(in: line) != nil { found.append(index) }
        }
        return found
    }

    /// `text` with the box on `line` ticked or cleared; nil when that line has no box any more.
    static func setting(_ checked: Bool, line: Int, in text: String) -> String? {
        guard lines(in: text).contains(line) else { return nil }
        var rows = text.components(separatedBy: "\n")
        guard let box = boxRange(in: rows[line]) else { return nil }
        rows[line].replaceSubrange(box, with: checked ? "[x]" : "[ ]")
        return rows.joined(separator: "\n")
    }

    enum Segment: Equatable {
        case text(String)
        /// One box: its line in the text, whether it is ticked, and its words.
        case task(line: Int, checked: Bool, text: String)
    }

    /// The text cut at its boxes, so each can be drawn as a control and the rest stays ordinary markdown.
    static func segments(_ text: String) -> [Segment] {
        let boxes = Set(lines(in: text))
        guard !boxes.isEmpty else { return [.text(text)] }
        var result: [Segment] = []
        var prose: [String] = []
        func flush() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(.text(joined)) }
            prose = []
        }
        for (index, row) in text.components(separatedBy: "\n").enumerated() {
            guard boxes.contains(index), let box = boxRange(in: row) else {
                prose.append(row)
                continue
            }
            flush()
            result.append(.task(line: index, checked: row[box].lowercased() == "[x]",
                                text: String(row[box.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        flush()
        return result
    }

    /// Whether a list line starts with a box, and which one.
    static func checked(_ line: String) -> Bool? {
        boxRange(in: line).map { line[$0].lowercased() == "[x]" }
    }

    private static func boxRange(in line: String) -> Range<String.Index>? {
        line.range(of: #"^\s*(?:[-*+]|\d+[.)])\s+\[[ xX]\]"#, options: .regularExpression).map {
            line.index($0.upperBound, offsetBy: -3)..<$0.upperBound
        }
    }
}
