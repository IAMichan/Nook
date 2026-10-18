import SwiftUI
import AppKit

extension MarkdownBlock {
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
}

/// Renders an answer with headings, lists, tables, charts, code blocks, call-outs, and questions, in Nook's visual style.
/// Parsed Markdown per text. SwiftUI asks for a message's body far more often than its text changes (scrolling, hover,
/// another message streaming in); parsing once per text keeps long conversations smooth.
private final class ParsedMarkdown {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}

enum MarkdownCache {
    private static let cache: NSCache<NSString, ParsedMarkdown> = {
        let cache = NSCache<NSString, ParsedMarkdown>()
        cache.countLimit = 400
        return cache
    }()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlock.parse(text)
        cache.setObject(ParsedMarkdown(blocks), forKey: key)
        return blocks
    }
}

struct MarkdownView: View {
    let text: String
    var size: CGFloat = 14
    /// When set, the options of a question at the end of the answer become buttons that answer it.
    var onChoose: ((String) -> Void)? = nil

    var body: some View {
        let blocks = MarkdownCache.blocks(text)
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
            MarkdownCodeBlock(language: language, code: code, size: size)
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

extension Callout.Kind {
    var color: Color {
        switch self {
        case .note: return NookTheme.iris
        case .tip: return NookTheme.mint
        case .warning: return NookTheme.amber
        case .danger: return NookTheme.coral
        }
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

private struct MarkdownCodeBlock: View {
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
