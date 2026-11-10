import Foundation

/// Markdown in the session composer, styled as you type: where the bold, italic, code, headings, list markers, task boxes,
/// quotes and code blocks are in the draft, as UTF-16 ranges for the text view. Only how it looks: the text itself,
/// markers and all, is what goes to the agent. The markers stay visible (dimmed), so they edit like any other text.
enum ComposerMarkdownStyle {
    enum Kind: Equatable, Sendable {
        case bold, italic, strike, code
        /// A whole line inside a ``` block, fences included.
        case codeBlock
        case heading(Int)
        /// `- `, `* `, `1. `: the marker of a list item.
        case listMarker
        /// `[ ]` or `[x]` after a list marker.
        case task(done: Bool)
        /// `> ` at the start of a line, and the rest of that line.
        case quote
        /// Markdown syntax that shows dimmed: `**`, `*`, `` ` ``, `#`, `~~`.
        case syntax
    }

    struct Span: Equatable, Sendable {
        var kind: Kind
        var range: NSRange
    }

    /// Past this many UTF-16 units the draft is left plain: a huge paste is kept as a file anyway (`keepPaste`), and
    /// styling it on every key would cost more than it shows.
    static let limit = 20_000

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+\S.*$"#, options: [.anchorsMatchLines])
    private static let listItem = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+"#, options: [.anchorsMatchLines])
    private static let task = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+(\[[ xX]\])(?=[ \t])"#, options: [.anchorsMatchLines])
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?.*$"#, options: [.anchorsMatchLines])
    private static let code = try! NSRegularExpression(pattern: #"(`+)([^`\n]+?)\1(?!`)"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)([^\n]+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*\w])(\*|_)(?=[^\s*_])([^\n*_]+?)(?<=\S)\1(?![*\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"(~~)(?=\S)([^\n]+?)(?<=\S)~~"#)

    static func spans(_ text: String) -> [Span] {
        let ns = text as NSString
        guard ns.length > 0, ns.length <= limit else { return [] }
        var spans: [Span] = []
        let whole = NSRange(location: 0, length: ns.length)

        // Code blocks first: nothing inside them is Markdown.
        var blocked: [NSRange] = []
        var lineStart = 0
        var open: Int?
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("```") {
                if let start = open {
                    blocked.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    open = nil
                } else {
                    open = line.location
                }
            }
            lineStart = NSMaxRange(line)
        }
        // An open fence styles to the end while you are still writing the block.
        if let start = open { blocked.append(NSRange(location: start, length: ns.length - start)) }
        for range in blocked { spans.append(Span(kind: .codeBlock, range: range)) }
        func free(_ range: NSRange) -> Bool { !blocked.contains { NSIntersectionRange($0, range).length > 0 } }

        for match in heading.matches(in: text, range: whole) where free(match.range) {
            let hashes = match.range(at: 1)
            spans.append(Span(kind: .heading(hashes.length), range: match.range))
            spans.append(Span(kind: .syntax, range: hashes))
        }
        for match in quote.matches(in: text, range: whole) where free(match.range) {
            spans.append(Span(kind: .quote, range: match.range))
        }
        for match in listItem.matches(in: text, range: whole) where free(match.range) {
            spans.append(Span(kind: .listMarker, range: match.range))
        }
        for match in task.matches(in: text, range: whole) where free(match.range) {
            let box = match.range(at: 1)
            let done = ns.substring(with: box).lowercased() == "[x]"
            spans.append(Span(kind: .task(done: done), range: box))
        }
        // Inline: code spans first, so a `*` inside one is not emphasis.
        var codeRanges: [NSRange] = []
        for match in code.matches(in: text, range: whole) where free(match.range) {
            codeRanges.append(match.range)
            spans.append(Span(kind: .code, range: match.range))
            let ticks = match.range(at: 1).length
            spans.append(Span(kind: .syntax, range: NSRange(location: match.range.location, length: ticks)))
            spans.append(Span(kind: .syntax, range: NSRange(location: NSMaxRange(match.range) - ticks, length: ticks)))
        }
        func inline(_ range: NSRange) -> Bool {
            free(range) && !codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var boldRanges: [NSRange] = []
        for (regex, kind) in [(bold, Kind.bold), (strike, Kind.strike)] {
            for match in regex.matches(in: text, range: whole) where inline(match.range) {
                if kind == .bold { boldRanges.append(match.range) }
                spans.append(Span(kind: kind, range: match.range))
                spans.append(Span(kind: .syntax, range: NSRange(location: match.range.location, length: 2)))
                spans.append(Span(kind: .syntax, range: NSRange(location: NSMaxRange(match.range) - 2, length: 2)))
            }
        }
        for match in italic.matches(in: text, range: whole) where inline(match.range) {
            // A bold's own markers are not italic.
            guard !boldRanges.contains(where: { NSLocationInRange(match.range.location, $0) && (match.range.location == $0.location || NSMaxRange(match.range) == NSMaxRange($0)) }) else { continue }
            // A `*` that starts a list item is its marker, not emphasis.
            guard !spans.contains(where: { $0.kind == .listMarker && NSLocationInRange(match.range.location, $0.range) }) else { continue }
            spans.append(Span(kind: .italic, range: match.range))
            spans.append(Span(kind: .syntax, range: NSRange(location: match.range.location, length: 1)))
            spans.append(Span(kind: .syntax, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1)))
        }
        return spans
    }
}

extension ComposerLists {
    /// Tab and Shift+Tab on a list item: the lines the selection touches move in (two spaces) or out, when every one of
    /// them is a list item. Returns the new text and the selection moved along, or nil to leave Tab to the field.
    static func nest(_ text: String, selection: NSRange, outdent: Bool) -> (text: String, selection: NSRange)? {
        let ns = text as NSString
        guard NSMaxRange(selection) <= ns.length else { return nil }
        let lines = ns.lineRange(for: selection)
        var starts: [Int] = []
        var location = lines.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            starts.append(line.location)
            location = NSMaxRange(line)
        } while location < NSMaxRange(lines)
        let item = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]"#)
        var edits: [(at: Int, remove: Int, insert: String)] = []
        for start in starts {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            guard let match = item.firstMatch(in: text, range: line), match.range.location == start else { return nil }
            let indent = match.range(at: 1)
            if outdent {
                let leading = ns.substring(with: indent)
                guard !leading.isEmpty else { continue }
                let remove = leading.hasPrefix("\t") ? 1 : min(2, leading.prefix { $0 == " " }.count)
                edits.append((start, remove, ""))
            } else {
                edits.append((start, 0, "  "))
            }
        }
        guard !edits.isEmpty else { return outdent ? (text, selection) : nil }
        let result = NSMutableString(string: text)
        var head = selection.location, tail = NSMaxRange(selection)
        for edit in edits.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.at, length: edit.remove), with: edit.insert)
            let delta = edit.insert.utf16.count - edit.remove
            if edit.at < head || (edit.at == head && delta > 0) { head = max(edit.at, head + delta) }
            if edit.at < tail || (edit.at == tail && delta > 0) { tail = max(edit.at, tail + delta) }
        }
        return (result as String, NSRange(location: head, length: max(0, tail - head)))
    }
}
