import XCTest

final class IncrementalMarkdownTests: XCTestCase {
    /// Answers that stress the cuts: code fences with blank lines, loose lists, tables, quotes, Windows line endings.
    private let samples: [String] = [
        "# Plan\n\nFirst a paragraph\nthat runs on.\n\nAnd another one.\n",
        "Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n\n```\n\nAfter the code.\n\n```\nunterminated\n\nstill code",
        "Steps:\n\n- one\n- two\n\n- three after a blank\n\n  - nested\n\n1. first\n\n2. second\n10) tenth\n\nDone.",
        "| Name | Value |\n| --- | ---: |\n| a | 1 |\n| b | 2 |\n\nText under the table.\n\n| x |\n|--|\n",
        "> quoted\n> more\n\nplain\n\n> [!NOTE] a note\n\n***\n\n## End",
        "Line one\r\n\r\nLine two\r\n\r\n- item\r\n\r\n- item two\r\n",
        "\n\n\nStarts with blanks\n\n   \n\t\nTabs and spaces as blank lines\n\n```\n```\n\nx",
        "- a\n  continued\n\nNot a list\n\n* b\n\n+ c\n\n• d\n\n3 apples are not a list\n\nend",
    ]

    func testStreamingGivesTheSameBlocksAsAFullParse() {
        for sample in samples {
            var state = IncrementalMarkdown<String>()
            var prefix = ""
            for character in sample {
                prefix.append(character)
                XCTAssertEqual(state.update(prefix, parse: Self.reference), Self.reference(prefix), "prefix: \(prefix.debugDescription)")
            }
        }
    }

    func testFinishedBlocksAreKeptWhileStreaming() {
        var state = IncrementalMarkdown<String>()
        var parsed: [String] = []
        let text = "# Title\n\nA paragraph.\n\nAnother paragraph\nthat keeps growing"
        _ = state.update(text, parse: { parsed.append($0); return Self.reference($0) })
        parsed.removeAll()
        _ = state.update(text + " and growing", parse: { parsed.append($0); return Self.reference($0) })
        XCTAssertEqual(parsed, ["Another paragraph\nthat keeps growing and growing"], "only the tail is parsed again")
        XCTAssertEqual(state.stable.count, 2)
    }

    func testATextThatDoesNotContinueIsParsedWhole() {
        var state = IncrementalMarkdown<String>()
        _ = state.update("First answer.\n\nMore.", parse: Self.reference)
        let blocks = state.update("Other answer.\n\nElse.", parse: Self.reference)
        XCTAssertEqual(blocks, Self.reference("Other answer.\n\nElse."))
        XCTAssertEqual(state.update("Other", parse: Self.reference), ["p:Other"], "a shorter text starts over")
    }

    func testNoCutInsideAFenceOrBeforeAListItem() {
        XCTAssertNil(MarkdownBoundary.lastStable(in: "```\na\n\nb\n"[...]))
        XCTAssertNil(MarkdownBoundary.lastStable(in: "- a\n\n- b\n"[...]))
        XCTAssertNil(MarkdownBoundary.lastStable(in: "a\n\nunfinished line"[...]), "the line at a cut must be finished")
        XCTAssertEqual(MarkdownBoundary.lastStable(in: "a\n\nb\n"[...]), 3)
        XCTAssertEqual(MarkdownBoundary.lastStable(in: "é\n\nb\n"[...]), 4, "offsets count UTF-8 bytes")
    }

    #if os(macOS)
    /// With the app's own parser (not part of the Linux core run): incremental equals full on the same answers.
    func testTheAppParserAgrees() {
        for sample in samples {
            var state = IncrementalMarkdown<MarkdownBlock>()
            var prefix = ""
            for character in sample {
                prefix.append(character)
                let incremental = state.update(prefix, parse: MarkdownBlock.parse)
                XCTAssertEqual(String(describing: incremental), String(describing: MarkdownBlock.parse(prefix)), prefix.debugDescription)
            }
        }
    }
    #endif

    /// A small stand-in for `MarkdownBlock.parse` with the same block rules: fences run to their closing fence (or the
    /// end), lists keep going over a blank line before another item, tables and quotes end at a blank line.
    static func reference(_ raw: String) -> [String] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        func isItem(_ s: String) -> Bool {
            s.range(of: #"^\s*[-*•◦▪+]\s+"#, options: .regularExpression) != nil
                || s.range(of: #"^\s*\d{1,3}[.)]\s+"#, options: .regularExpression) != nil
        }
        func isDivider(_ s: String) -> Bool {
            trim(s).range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil
        }
        var blocks: [String] = []
        var paragraph: [String] = []
        func flush() {
            let text = trim(paragraph.joined(separator: "\n")).trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append("p:" + text) }
            paragraph.removeAll()
        }
        var i = 0
        while i < lines.count {
            let line = lines[i], t = trim(line)
            if t.isEmpty { flush(); i += 1; continue }
            if t.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !trim(lines[i]).hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                blocks.append("code:\(t.dropFirst(3)):" + code.joined(separator: "\n"))
                continue
            }
            if t.hasPrefix("#") { flush(); blocks.append("h:" + t); i += 1; continue }
            if t.contains("|"), i + 1 < lines.count, isDivider(lines[i + 1]) {
                flush()
                var rows = [t]
                i += 2
                while i < lines.count, lines[i].contains("|"), !trim(lines[i]).isEmpty { rows.append(trim(lines[i])); i += 1 }
                blocks.append("table:" + rows.joined(separator: "/"))
                continue
            }
            if isItem(line) {
                flush()
                var items: [String] = []
                while i < lines.count {
                    if isItem(lines[i]) {
                        items.append(trim(lines[i]))
                    } else if trim(lines[i]).isEmpty {
                        guard i + 1 < lines.count, isItem(lines[i + 1]) else { break }
                    } else if lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += " " + trim(lines[i])
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append("list:" + items.joined(separator: "/"))
                continue
            }
            if t.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count, trim(lines[i]).hasPrefix(">") { quote.append(trim(lines[i])); i += 1 }
                blocks.append("quote:" + quote.joined(separator: "/"))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }
}
