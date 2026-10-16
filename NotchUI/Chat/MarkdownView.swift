import SwiftUI
import AppKit

/// A block within a Markdown answer.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([(number: String, text: String)])
    case code(language: String, code: String)
    case chart(ChatChart)
    /// A question from the answer with options to pick from (a ```question block).
    case question(text: String, options: [String])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    private static let brRegex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let headingRegex = try? NSRegularExpression(pattern: #"^#{1,6}\s"#)
    private static let ruleRegex = try? NSRegularExpression(pattern: #"^([-*_]\s*){3,}$"#)
    private static let tableDividerRegex = try? NSRegularExpression(pattern: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#)
    private static let bulletRegex = try? NSRegularExpression(pattern: #"^\s*[-*•+]\s+"#)
    private static let numberRegex = try? NSRegularExpression(pattern: #"^\s*\d{1,3}[.)]\s+"#)

    private static func matches(_ text: String, _ rx: NSRegularExpression?) -> Bool {
        guard let rx else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func stripPrefix(_ text: String, _ rx: NSRegularExpression?) -> String {
        guard let rx else { return text }
        return rx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Cleans up artifacts models sometimes output: trailing backslashes (hard breaks), `<br>`, and Windows line endings.
    static func clean(_ text: String) -> String {
        var normalized = text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        if normalized.contains("<"), let rx = brRegex {
            normalized = rx.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\n")
        }
        guard normalized.contains("\\") else { return normalized }
        return normalized
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\\" || trimmed == "\\\\" { return "" }
                if line.hasSuffix("\\"), !line.hasSuffix("\\\\") { return String(line.dropLast()) }
                return line
            }
            .joined(separator: "\n")
    }

    private static let chartLanguages: Set<String> = ["chart", "chartjs", "vega", "vega-lite", "mermaid", "json"]

    /// `{"question": "...", "options": ["a", {"label": "b"}]}` as the model writes it in a ```question block.
    private static func question(from body: String) -> MarkdownBlock? {
        guard let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["question"] as? String else { return nil }
        let options = ((object["options"] as? [Any]) ?? []).compactMap { item -> String? in
            if let label = item as? String { return label }
            return (item as? [String: Any])?["label"] as? String
        }
        return options.count >= 2 ? .question(text: text, options: options) : nil
    }

    /// Options at the end of an answer that closes a question: the last list after a paragraph that asks something.
    static func trailingChoices(_ blocks: [MarkdownBlock]) -> (index: Int, options: [String])? {
        guard blocks.count >= 2, case .paragraph(let ask) = blocks[blocks.count - 2],
              ask.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") || ask.contains("?") && ask.hasSuffix(":") else { return nil }
        let last = blocks.count - 1
        switch blocks[last] {
        case .bullets(let items) where (2...6).contains(items.count): return (last, items.map(stripTask))
        case .numbered(let items) where (2...6).contains(items.count): return (last, items.map(\.text))
        default: return nil
        }
    }

    /// `[ ]` / `[x]` task markers at the start of a list item.
    static func task(_ item: String) -> (done: Bool, text: String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where item.hasPrefix(marker) {
            return (done, String(item.dropFirst(marker.count)))
        }
        return nil
    }

    private static func stripTask(_ item: String) -> String { task(item)?.text ?? item }

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

        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

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
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let body = code.joined(separator: "\n")
                if language == "question", let block = question(from: body) {
                    blocks.append(block)
                } else if chartLanguages.contains(language), let chart = ChartRescue.chart(fromCode: body, language: language, title: "") {
                    blocks.append(.chart(chart))
                } else {
                    blocks.append(.code(language: language, code: body))
                }
                continue
            }
            // Heading
            if matches(trimmed, headingRegex) {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(level: level, text: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            // Horizontal rule
            if matches(trimmed, ruleRegex) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            // Table: a header row with | followed by a divider row.
            if trimmed.contains("|"), index + 1 < lines.count,
               matches(lines[index + 1].trimmingCharacters(in: .whitespaces), tableDividerRegex) {
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
            if matches(line, bulletRegex) {
                flush()
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if matches(current, bulletRegex) {
                        let indent = current.prefix { $0 == " " || $0 == "\t" }.count
                        let text = stripPrefix(current, bulletRegex)
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
            if matches(line, numberRegex) {
                flush()
                var items: [(number: String, text: String)] = []
                while index < lines.count, matches(lines[index], numberRegex) {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    let digits = String(current.prefix { $0.isNumber })
                    let text = stripPrefix(current, numberRegex)
                    items.append((digits + ".", text))
                    index += 1
                    // Blank lines between list items are treated as part of the list.
                    if index + 1 < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty, matches(lines[index + 1], numberRegex) {
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
    static func inline(_ text: String, size: CGFloat = 14) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        // Answers can repeat text from mails or web pages: only web and mail links stay clickable, and a link whose text
        // hides where it goes gets its real host next to it.
        var result = AttributedString()
        var open: (url: URL, text: String)?
        func close() {
            guard let link = open else { return }
            open = nil
            if let host = link.url.host?.lowercased(), !link.text.lowercased().contains(host) {
                var suffix = AttributedString(" (\(host))")
                suffix.foregroundColor = NookTheme.textTertiary
                result += suffix
            }
        }
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            let url = run.link.flatMap { isSafeLink($0) ? $0 : nil }
            if run.link != nil, url == nil { piece.link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.font = .system(size: size - 1.5, design: .monospaced)
                piece.backgroundColor = NookTheme.field
                piece.foregroundColor = NookTheme.paper
            }
            if open?.url != url { close() }
            if let url { open = (url, (open?.text ?? "") + String(piece.characters)) }
            result += piece
        }
        close()
        return result
    }

    static func isSafeLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http": return url.host != nil && url.user == nil
        case "mailto": return true
        default: return false
        }
    }
}

/// Renders an answer with headings, lists, tables, charts, code blocks, call-outs, and questions, in Nook's visual style.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 14
    /// When set, the options of a question at the end of the answer become buttons that answer it.
    var onChoose: ((String) -> Void)? = nil

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        let choices = onChoose == nil ? nil : MarkdownBlock.trailingChoices(blocks)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                if let choices, choices.index == offset {
                    ChoiceList(options: choices.options, size: size) { onChoose?($0) }
                } else {
                    view(for: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            MarkdownBlock.isSafeLink(url) ? .systemAction : .discarded
        })
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlock.inline(text, size: size))
                .font(NookTheme.font(level <= 1 ? size + 5 : level == 2 ? size + 3 : size + 1, .semibold))
                .foregroundStyle(NookTheme.paper)
                .padding(.top, level <= 2 ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            paragraph(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let task = MarkdownBlock.task(item) {
                            Image(systemName: task.done ? "checkmark.square.fill" : "square")
                                .font(.system(size: size - 1))
                                .foregroundStyle(task.done ? NookTheme.mint : NookTheme.textTertiary)
                            paragraph(task.text, color: task.done ? NookTheme.textSecondary : NookTheme.paper)
                        } else {
                            Text("•").foregroundStyle(NookTheme.iris)
                            paragraph(item)
                        }
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
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
        case .code(let language, let code):
            CodeBlock(language: language, code: code, size: size)
        case .chart(let chart):
            ChatChartView(chart: chart)
        case .question(let text, let options):
            VStack(alignment: .leading, spacing: 8) {
                paragraph(text)
                if onChoose != nil {
                    ChoiceList(options: options, size: size) { onChoose?($0) }
                } else {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(NookTheme.iris)
                            paragraph(option)
                        }
                    }
                }
            }
        case .quote(let text):
            if let callout = Callout.detect(text) {
                CalloutBlock(callout: callout, size: size)
            } else {
                HStack(spacing: 10) {
                    Rectangle().fill(NookTheme.line2).frame(width: 3)
                    paragraph(text, color: NookTheme.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, size: size)
        case .rule:
            Rectangle().fill(NookTheme.line2).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func paragraph(_ text: String, color: Color = NookTheme.paper) -> some View {
        Text(MarkdownBlock.inline(text, size: size))
            .font(NookTheme.font(size))
            .lineSpacing(3)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Call-outs

/// A quote that starts with `[!NOTE]`, `[!TIP]`, `[!WARNING]` (also Dutch: Let op, Tip, Waarschuwing) becomes a call-out.
struct Callout {
    enum Kind {
        case note, tip, warning, danger
        var symbol: String {
            switch self {
            case .note: return "info.circle.fill"
            case .tip: return "lightbulb.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .note: return NookTheme.iris
            case .tip: return NookTheme.mint
            case .warning: return NookTheme.amber
            case .danger: return NookTheme.coral
            }
        }
    }

    let kind: Kind
    let title: String
    let body: String

    static func detect(_ text: String) -> Callout? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let keys: [(String, Kind, String)] = [
            ("note", .note, "Notitie"), ("info", .note, "Info"), ("tip", .tip, "Tip"), ("important", .warning, "Belangrijk"),
            ("warning", .warning, "Let op"), ("let op", .warning, "Let op"), ("waarschuwing", .warning, "Waarschuwing"),
            ("caution", .danger, "Voorzichtig"), ("danger", .danger, "Gevaar"), ("opmerking", .note, "Opmerking")
        ]
        let lower = first.lowercased()
        for (key, kind, title) in keys {
            if lower.hasPrefix("[!\(key)]") {
                let after = String(first.dropFirst(key.count + 3)).trimmingCharacters(in: .whitespaces)
                return Callout(kind: kind, title: title, body: [after, rest].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            // "**Let op:** tekst" / "**Tip**: tekst"
            for prefix in ["**\(key):**", "**\(key)**:", "**\(key)**"] where lower.hasPrefix(prefix) {
                let after = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return Callout(kind: kind, title: title, body: [after, rest].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
        return nil
    }
}

private struct CalloutBlock: View {
    let callout: Callout
    let size: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: callout.kind.symbol)
                .font(.system(size: size))
                .foregroundStyle(callout.kind.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(callout.title)
                    .font(NookTheme.font(size - 1.5, .semibold))
                    .foregroundStyle(callout.kind.color)
                if !callout.body.isEmpty {
                    Text(MarkdownBlock.inline(callout.body, size: size))
                        .font(NookTheme.font(size))
                        .lineSpacing(3)
                        .foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(callout.kind.color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(callout.kind.color.opacity(0.25), lineWidth: 1))
    }
}

// MARK: Code

private struct CodeBlock: View {
    let language: String
    let code: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(NookTheme.mono(size - 3))
                    .foregroundStyle(NookTheme.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? tr("button.copied") : tr("button.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(NookTheme.font(size - 3, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(NookTheme.mono(size - 1.5))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NookTheme.line2.opacity(0.6), lineWidth: 1))
    }
}

// MARK: Questions

/// The options of a question as cards to tap: the tap is the answer.
struct ChoiceList: View {
    let options: [String]
    let size: CGFloat
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { choose(Self.plain(option)) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(UnicodeScalar(UInt8(65 + min(index, 25)))))
                            .font(NookTheme.font(size - 2, .bold))
                            .foregroundStyle(NookTheme.iris)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(NookTheme.iris.opacity(0.16)))
                        Text(MarkdownBlock.inline(option, size: size))
                            .font(NookTheme.font(size, .medium))
                            .foregroundStyle(NookTheme.paper)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(NookTheme.line2, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The reply is the option without its Markdown markers.
    static func plain(_ option: String) -> String {
        option.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

// MARK: Table

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let size: CGFloat
    @State private var showChart = false

    private var chart: ChatChart? { ChartRescue.chart(fromTable: header, rows: rows, title: "") }

    /// A column of only numbers is right-aligned, so digits line up.
    private func numeric(_ column: Int) -> Bool {
        !rows.isEmpty && rows.allSatisfy { column < $0.count && (ChartRescue.number($0[column]) != nil || $0[column].isEmpty || $0[column] == "-" || $0[column] == "–") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chart {
                Picker("", selection: $showChart) {
                    Label(tr("table.table"), systemImage: "tablecells").tag(false)
                    Label(tr("table.chart"), systemImage: "chart.bar.xaxis").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                if showChart { ChatChartView(chart: chart) } else { grid }
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        Text(MarkdownBlock.inline(cell, size: size))
                            .font(NookTheme.font(size - 1.5, .semibold))
                            .foregroundStyle(NookTheme.textSecondary)
                            .gridColumnAlignment(numeric(column) ? .trailing : .leading)
                            .padding(.vertical, 8)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Divider().overlay(NookTheme.line2).gridCellColumns(header.count)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(MarkdownBlock.inline(cell, size: size))
                                .font(NookTheme.font(size - 0.5, column == 0 ? .medium : .regular))
                                .monospacedDigit()
                                .foregroundStyle(NookTheme.paper)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 7)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.02))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NookTheme.line2.opacity(0.6), lineWidth: 1))
    }
}
