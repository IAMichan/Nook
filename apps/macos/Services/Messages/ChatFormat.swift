import Foundation

/// A chat message's own markup, read the way the chat apps show it, the same for every app: *bold*, _italic_,
/// ~strikethrough~ and `code` (WhatsApp and Slack write them like this; **bold** and __italic__ as Markdown has them),
/// ```code blocks```, quotes ("> …") and lists ("• …", "- …", "1. …"). Foundation only, so it can be tested anywhere;
/// `ChatMessageText` draws it.
enum ChatFormat {
    /// A piece of text with its style.
    struct Span: Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var strike = false
        var code = false
    }

    /// One line or block of a message.
    enum Block: Equatable, Sendable {
        case paragraph([Span])
        case quote([Span])
        /// A list item: its marker ("•", "1.") and its text.
        case item(String, [Span])
        case code(String)
    }

    /// The blocks of a message: lines in a row of the same kind stay together.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(spans(paragraph.joined(separator: "\n")))) }
            if !quote.isEmpty { blocks.append(.quote(spans(quote.joined(separator: "\n")))) }
            paragraph = []
            quote = []
        }
        var lines = text.components(separatedBy: "\n")[...]
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                // A code block runs to the next ``` (on the same line or a later one), or to the end.
                var body = String(trimmed.dropFirst(3))
                if let end = body.range(of: "```") {
                    blocks.append(.code(String(body[..<end.lowerBound])))
                    let rest = String(body[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { paragraph.append(rest) }
                    continue
                }
                var code: [String] = body.isEmpty ? [] : [body]
                while let next = lines.popFirst() {
                    if let end = next.range(of: "```") {
                        body = String(next[..<end.lowerBound])
                        if !body.isEmpty { code.append(body) }
                        break
                    }
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(trimmed) {
                flush()
                blocks.append(.item(item.marker, spans(item.text)))
            } else {
                if !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Nothing that shows: only spaces, line breaks and invisible marks (a zero-width space, a direction mark, a lone
    /// variation selector). A message with only that and no file is no bubble of its own.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace || scalar.properties.isVariationSelector
                || [.format, .control].contains(scalar.properties.generalCategory)
        }
    }

    /// The message as plain text, without its markup: for a chat's line in a list and for what is copied.
    static func plain(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .paragraph(let spans), .quote(let spans): return spans.map(\.text).joined()
            case .item(let marker, let spans): return marker + " " + spans.map(\.text).joined()
            case .code(let code): return code
            }
        }.joined(separator: "\n")
    }

    /// "• milk", "- milk", "* milk", "1. milk", "2) milk" as a list item; a bold "*word*" is no item.
    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        for bullet in ["• ", "- ", "* ", "◦ ", "▪ "] where line.hasPrefix(bullet) {
            let text = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("•", text)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (String(digits) + ".", text)
    }

    /// The styled pieces of a text. A marker only counts around a word: "*bold*" is bold, "5 * 3 * 2" and
    /// "file_name_here" are not, and a web address is left as it is.
    static func spans(_ text: String) -> [Span] {
        var result: [Span] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                let end = rest.firstIndex(where: \.isWhitespace) ?? text.endIndex
                plain += text[index..<end]
                index = end
            } else if let found = styled(text, at: index) {
                if !plain.isEmpty { result.append(Span(text: plain)) }
                plain = ""
                result += found.0
                index = found.1
            } else {
                plain.append(text[index])
                index = text.index(after: index)
            }
        }
        if !plain.isEmpty { result.append(Span(text: plain)) }
        return result
    }

    /// The styled pieces that start at `index`, if a marker opens there, and where they end.
    private static func styled(_ text: String, at index: String.Index) -> ([Span], String.Index)? {
        let rest = text[index...]
        // A marker opens at the start, or after a space or punctuation, never inside a word.
        if index > text.startIndex {
            let before = text[text.index(before: index)]
            if before.isLetter || before.isNumber { return nil }
        }
        for (marker, style) in [("`", "code"), ("**", "bold"), ("__", "italic"), ("*", "bold"), ("_", "italic"), ("~", "strike")] {
            guard rest.hasPrefix(marker) else { continue }
            let inner = rest.dropFirst(marker.count)
            guard let first = inner.first, !first.isWhitespace, first != marker.first else { continue }
            guard let close = closing(marker, in: inner, code: style == "code") else { continue }
            let body = String(inner[..<close])
            let end = inner.index(close, offsetBy: marker.count)
            // It closes before a space or punctuation, never inside a word ("a*b*c" stays as it is).
            if end < text.endIndex, text[end].isLetter || text[end].isNumber { continue }
            if style == "code" { return ([Span(text: body, code: true)], end) }
            // Styles inside styles ("*_both_*") keep both.
            var spans = Self.spans(body)
            for i in spans.indices {
                switch style {
                case "bold": spans[i].bold = true
                case "italic": spans[i].italic = true
                default: spans[i].strike = true
                }
            }
            return (spans, end)
        }
        return nil
    }

    /// Where a marker closes on the same line: not right after a space (that is no closing marker).
    private static func closing(_ marker: String, in text: Substring, code: Bool) -> String.Index? {
        var search = text.startIndex
        while let range = text.range(of: marker, range: search..<text.endIndex) {
            let body = text[..<range.lowerBound]
            if body.contains("\n") { return nil }
            if let last = body.last, code || !last.isWhitespace { return range.lowerBound }
            search = range.upperBound
        }
        return nil
    }
}
