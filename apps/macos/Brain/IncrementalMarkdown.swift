import Foundation

/// Where a growing Markdown text (a streaming answer) can be cut so the blocks before the cut never change again.
///
/// A cut sits at the start of a finished line that follows a blank line, outside a code fence, and that does not start a
/// list item (a blank line between items keeps a list going, so a list marker could still join the list above). Every
/// block `MarkdownBlock.parse` makes ends at such a line, so parsing the text before the cut and the text after it gives
/// the same blocks as parsing it whole.
enum MarkdownBoundary {
    /// The UTF-8 offset, counted from the start of `text`, of the last cut in it; nil when there is none past the start.
    /// `text` must itself start at a cut (or at the start of the answer): outside a fence, at the start of a line.
    static func lastStable(in text: Substring) -> Int? {
        var found: Int?
        var inFence = false
        var previousBlank = true
        var offset = 0
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        while let newline = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let length = utf8.distance(from: lineStart, to: newline)
            let line = String(text[lineStart..<newline])
            let trimmed = (line.hasSuffix("\r") ? String(line.dropLast()) : line).trimmingCharacters(in: .whitespaces)
            if inFence {
                if trimmed.hasPrefix("```") { inFence = false }
                previousBlank = false
            } else if trimmed.isEmpty {
                previousBlank = true
            } else {
                if previousBlank, offset > 0, !mayStartListItem(trimmed) { found = offset }
                if trimmed.hasPrefix("```") { inFence = true }
                previousBlank = false
            }
            offset += length + 1
            lineStart = utf8.index(after: newline)
        }
        return found
    }

    /// Whether a trimmed line could be a list item: a bullet, or a digit that may begin "1." or "2)". Erring on the
    /// side of yes only gives fewer cuts.
    private static func mayStartListItem(_ trimmed: String) -> Bool {
        guard let first = trimmed.unicodeScalars.first else { return false }
        return "-*•◦▪+".unicodeScalars.contains(first) || ("0"..."9").contains(Character(first))
    }
}

/// The blocks of a streaming answer, parsed one stretch at a time: blocks before the last cut (`MarkdownBoundary`) are
/// kept, and each new token parses only the text after it. A text that does not continue the one before is parsed
/// whole. `Block` is `MarkdownBlock` in the app; tests use their own.
struct IncrementalMarkdown<Block> {
    /// The text the blocks are of.
    private(set) var source = ""
    /// UTF-8 offset in `source` of the last cut: `stable` are the blocks before it, `tail` those after.
    private(set) var boundary = 0
    private(set) var stable: [Block] = []
    private(set) var tail: [Block] = []

    init() {}

    var blocks: [Block] { stable + tail }

    /// Whether `text` is `source` one or more tokens further.
    func continues(_ text: String) -> Bool {
        text.utf8.count > source.utf8.count && text.utf8.starts(with: source.utf8)
    }

    /// The blocks of `text`, reusing what is kept when `text` continues `source`.
    mutating func update(_ text: String, parse: (String) -> [Block]) -> [Block] {
        if text == source, !source.isEmpty { return blocks }
        if !continues(text) {
            boundary = 0
            stable = []
        }
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: boundary)
        if let cut = MarkdownBoundary.lastStable(in: text[start...]) {
            let split = utf8.index(start, offsetBy: cut)
            stable += parse(String(text[start..<split]))
            boundary += cut
            tail = parse(String(text[split...]))
        } else {
            tail = parse(String(text[start...]))
        }
        source = text
        return blocks
    }
}
