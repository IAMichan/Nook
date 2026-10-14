import SwiftUI

/// A block within a Markdown answer.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([(number: String, text: String)])
    case code(String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    /// Cleans up artifacts models sometimes output: trailing backslashes (hard breaks), `<br>`, and Windows line endings.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\\" || trimmed == "\\\\" { return "" }
                if line.hasSuffix("\\"), !line.hasSuffix("\\\\") { return String(line.dropLast()) }
                return line
            }
            .joined(separator: "\n")
    }

    static func parse(_ raw: String) -> [MarkdownBlock] {
        let lines = clean(raw).components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        func match(_ line: String, _ pattern: String) -> Bool {
            line.range(of: pattern, options: .regularExpression) != nil
        }

        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let bullet = #"^\s*[-*•+]\s+"#
        let number = #"^\s*\d{1,3}[.)]\s+"#

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            // Code block
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            // Heading
            if match(trimmed, #"^#{1,6}\s"#) {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(level: level, text: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            // Horizontal rule
            if match(trimmed, #"^([-*_]\s*){3,}$"#) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            // Table: a header row with | followed by a divider row.
            if trimmed.contains("|"), index + 1 < lines.count,
               match(lines[index + 1].trimmingCharacters(in: .whitespaces), #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[index])
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // Bulleted list
            if match(line, bullet) {
                flush()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if match(current, bullet) {
                        let indent = current.prefix { $0 == " " || $0 == "\t" }.count
                        let text = current.replacingOccurrences(of: bullet, with: "", options: .regularExpression)
                        items.append((indent >= 2 ? "◦ " : "") + text)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += " " + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }
            // Numbered list
            if match(line, number) {
                flush()
                var items: [(number: String, text: String)] = []
                while index < lines.count, match(lines[index], number) {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    let digits = String(current.prefix { $0.isNumber })
                    let text = current.replacingOccurrences(of: number, with: "", options: .regularExpression)
                    items.append((digits + ".", text))
                    index += 1
                    // Blank lines between list items are treated as part of the list.
                    if index + 1 < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty, match(lines[index + 1], number) {
                        index += 1
                    }
                }
                blocks.append(.numbered(items))
                continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    /// Bold, italic, code, and links within an inline span.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Renders an answer with headings, lists, tables, and code blocks, in Nook's visual style.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlock.inline(text))
                .font(NookTheme.font(level <= 2 ? size + 3 : size + 1, .semibold))
                .foregroundStyle(NookTheme.paper)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            paragraph(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(NookTheme.iris)
                        paragraph(item)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.number)
                            .font(NookTheme.font(size, .semibold))
                            .foregroundStyle(NookTheme.textSecondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        paragraph(item.text)
                    }
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(NookTheme.mono(size - 1.5))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.field))
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(NookTheme.line2).frame(width: 3)
                paragraph(text, color: NookTheme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, size: size)
        case .rule:
            Rectangle().fill(NookTheme.line2).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func paragraph(_ text: String, color: Color = NookTheme.paper) -> some View {
        Text(MarkdownBlock.inline(text))
            .font(NookTheme.font(size))
            .lineSpacing(3)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(MarkdownBlock.inline(cell))
                        .font(NookTheme.font(size - 1, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                        .padding(.vertical, 6)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(NookTheme.line2)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownBlock.inline(cell))
                            .font(NookTheme.font(size - 0.5))
                            .foregroundStyle(NookTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.field))
    }
}
