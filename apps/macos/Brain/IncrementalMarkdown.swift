import Foundation

/// Where a growing Markdown text (a streaming answer) can be cut so the blocks before the cut never change again.
///
/// A cut sits at the start of a finished line that follows a blank line, outside a code fence, and that does not start a
/// list item (a blank line between items keeps a list going, so a list marker could still join the list above). Every
/// block `MarkdownBlock.parse` makes ends at such a line, so parsing the text before the cut and the text after it gives
/// the same blocks as parsing it whole.
///
/// A line that opens a code fence at its very start (no indent, so it cannot continue a list item, and no "|", so it
/// cannot continue a table) is a cut as well, also without a blank line before it: every block ends there and the fence
/// starts a new one. While a long code block streams, only that block is parsed again. Not after a line, since the last
/// cut, that another block may have taken a fence line into (a table row, an indented fence, `$$`, `\[`, `<details>`):
/// then a fence line further on may not open a fence in the parse.
enum MarkdownBoundary {
    /// The UTF-8 offset, counted from the start of `text`, of the last cut in it; nil when there is none past the start.
    /// `text` must itself start at a cut (or at the start of the answer): outside a fence, at the start of a line.
    static func lastStable(in text: Substring) -> Int? {
        var scanner = Scanner()
        return scanner.scan(text.utf8, after: 0)
    }

    /// Reads a growing text line by line and remembers where it stopped, so each token reads only the lines that were
    /// finished since, not the whole text after the last cut again.
    struct Scanner {
        /// UTF-8 offset of the first line not read yet (it was not finished).
        private(set) var offset = 0
        private var inFence = false
        private var previousBlank = true
        /// A block that runs to a closing line of its own was opened since the last cut.
        private var openBlock = false

        init() {}

        /// Reads the finished lines from `offset` on and returns the offset of the last cut among them; a cut is never
        /// at or before `floor` (the start of the stretch, itself a cut).
        mutating func scan<Bytes: Collection>(_ bytes: Bytes, after floor: Int) -> Int? where Bytes.Element == UInt8 {
            if let found = bytes.withContiguousStorageIfAvailable({ scan(buffer: $0, after: floor) }) { return found }
            return Array(bytes).withUnsafeBufferPointer { scan(buffer: $0, after: floor) }
        }

        private mutating func scan(buffer: UnsafeBufferPointer<UInt8>, after floor: Int) -> Int? {
            var found: Int?
            var lineStart = offset
            while lineStart < buffer.count, let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = Line.read(buffer, from: lineStart, to: newline)
                if inFence {
                    if line.isFence { inFence = false }
                    previousBlank = false
                } else if line.isBlank {
                    previousBlank = true
                } else {
                    let opensFenceAtStart = line.isFence && buffer[lineStart] == UInt8(ascii: "`") && !line.hasPipe && !openBlock
                    if lineStart > floor, (previousBlank && !line.mayStartListItem) || opensFenceAtStart {
                        found = lineStart
                        openBlock = false
                    }
                    // Lines another block may take in, so a fence line after them may not open a fence in the parse: a
                    // table row (a "|"), an indented fence (it may continue a list item), `$$`, `\[` and `<details>`.
                    if line.opensBlock || line.hasPipe || (line.isFence && !opensFenceAtStart) { openBlock = true }
                    if line.isFence { inFence = true }
                    previousBlank = false
                }
                lineStart = newline + 1
            }
            offset = lineStart
            return found
        }
    }

    /// What the scanner needs to know about one line, read from its bytes. A line whose first character (after spaces and
    /// tabs) is not ASCII is read as a String, as `trimmingCharacters(in: .whitespaces)` does, so Unicode spaces count
    /// the same.
    private struct Line {
        var isBlank = false
        var isFence = false
        var mayStartListItem = false
        var opensBlock = false
        var hasPipe = false

        static func read(_ buffer: UnsafeBufferPointer<UInt8>, from start: Int, to newline: Int) -> Line {
            // "\r\n" is one Character, so a String line before it ends before its "\r", and one more "\r" came off.
            var end = newline
            for _ in 0..<2 where end > start && buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            var first = start
            while first < end, buffer[first] == UInt8(ascii: " ") || buffer[first] == UInt8(ascii: "\t") { first += 1 }
            var line = Line()
            line.hasPipe = buffer[start..<end].contains(UInt8(ascii: "|"))
            if first == end {
                line.isBlank = true
            } else if buffer[first] >= 0x80 || (first + 3 < end && buffer[first + 3] >= 0x80) {
                let trimmed = String(decoding: buffer[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                line.isBlank = trimmed.isEmpty
                line.isFence = trimmed.hasPrefix("```")
                line.mayStartListItem = trimmed.unicodeScalars.first.map {
                    "-*•◦▪+".unicodeScalars.contains($0) || ("0"..."9").contains(Character($0))
                } ?? false
                line.opensBlock = trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") || trimmed.lowercased().hasPrefix("<details")
            } else {
                let text = buffer[first..<end]
                let lead = buffer[first]
                line.isFence = text.starts(with: fence)
                line.mayStartListItem = listLeads.contains(lead) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(lead)
                line.opensBlock = text.starts(with: math) || text.starts(with: bracketMath)
                    || text.prefix(details.count).map { $0 | 0x20 }.elementsEqual(details)
            }
            return line
        }

        private static let fence = Array("```".utf8)
        private static let math = Array("$$".utf8)
        private static let bracketMath = Array("\\[".utf8)
        /// Lowercase; compared with each byte's ASCII lowercase (`| 0x20`, which leaves "<" as it is).
        private static let details = Array("<details".utf8)
        private static let listLeads = Set("-*+".utf8)
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
    /// Where reading for the next cut goes on: the lines after `boundary` are read once, not again for every token.
    private var scanner = MarkdownBoundary.Scanner()

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
            scanner = MarkdownBoundary.Scanner()
        }
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: boundary)
        if let cut = scanner.scan(utf8, after: boundary) {
            let split = utf8.index(utf8.startIndex, offsetBy: cut)
            stable += parse(String(text[start..<split]))
            boundary = cut
            tail = parse(String(text[split...]))
        } else {
            tail = parse(String(text[start...]))
        }
        source = text
        return blocks
    }
}
