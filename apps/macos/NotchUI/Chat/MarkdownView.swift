import SwiftUI
import AppKit

extension MarkdownBlock {
    /// Bold, italic, code, and links within an inline span.
    ///
    /// Cached per text and size: `AttributedString(markdown:)` is slow, and every paragraph, bullet and table cell of every
    /// visible message asks for it again on each redraw (another message streaming in, hover, a keystroke).
    static func inline(_ text: String, size: CGFloat = 14) -> AttributedString {
        let key = "\(size)|\(text)" as NSString
        if let hit = InlineCache.shared.object(forKey: key) { return hit.value }
        let value = renderInline(text, size: size)
        InlineCache.shared.setObject(InlineCache.Entry(value), forKey: key)
        return value
    }

    private static func renderInline(_ text: String, size: CGFloat) -> AttributedString {
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

/// Rendered inline Markdown, by size and text (see `MarkdownBlock.inline`).
private enum InlineCache {
    final class Entry {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    static let shared: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 3_000
        return cache
    }()
}

/// A run of text blocks that select as one, or a single block drawn on its own (code, tables, charts, call-outs …).
private struct MarkdownSegment {
    /// Index of the segment's first block in the answer.
    let offset: Int
    let blocks: [MarkdownBlock]
    let prose: Bool

    /// Groups headings, paragraphs, and lists that follow each other; `kept` is a block that stays on its own.
    static func split(_ blocks: [MarkdownBlock], keeping kept: Int?) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        for (offset, block) in blocks.enumerated() {
            let prose = offset != kept && SelectableProse.joins(block)
            if prose, let last = segments.last, last.prose {
                segments[segments.count - 1] = MarkdownSegment(offset: last.offset, blocks: last.blocks + [block], prose: true)
            } else {
                segments.append(MarkdownSegment(offset: offset, blocks: [block], prose: prose))
            }
        }
        return segments
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

    /// Texts parsed most recently, newest last. A text that continues one of them is the same answer one token further:
    /// the shorter one is dropped from the cache, so a streaming answer keeps one entry instead of one per token, which
    /// pushed the parsed finished messages out of the cache and made them parse again.
    private static var recent: [String] = []
    private static let recentLimit = 8
    private static let lock = NSLock()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlock.parse(text)
        cache.setObject(ParsedMarkdown(blocks), forKey: key)
        lock.lock()
        if let earlier = recent.firstIndex(where: { $0.utf8.count < text.utf8.count && text.utf8.starts(with: $0.utf8) }) {
            cache.removeObject(forKey: recent.remove(at: earlier) as NSString)
        }
        recent.append(text)
        if recent.count > recentLimit { recent.removeFirst() }
        lock.unlock()
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
            ForEach(MarkdownSegment.split(blocks, keeping: choices?.index), id: \.offset) { segment in
                if let choices, choices.index == segment.offset {
                    ChoiceList(options: choices.options, size: size) { onChoose?($0) }
                } else if segment.prose {
                    SelectableProse(blocks: segment.blocks, size: size)
                } else {
                    view(for: segment.blocks[0])
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
        case .heading, .paragraph, .list:
            SelectableProse(blocks: [block], size: size)
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
        .cardBackground(callout.kind.color.opacity(0.09), stroke: callout.kind.color.opacity(0.25), radius: 10)
    }
}

// MARK: Code

private struct MarkdownCodeBlock: View {
    let language: String
    let code: String
    let size: CGFloat
    @State private var copied = false
    /// HTML, SVG and Mermaid: shown as what they draw instead of their source.
    @State private var rendered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(NookTheme.mono(size - 3))
                    .foregroundStyle(NookTheme.textTertiary)
                Spacer()
                if CodeRenderView.canRender(language) {
                    Button { rendered.toggle() } label: {
                        Label(rendered ? tr("code.source") : tr("code.preview"),
                              systemImage: rendered ? "chevron.left.forwardslash.chevron.right" : "eye")
                            .font(NookTheme.font(size - 3, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                Button {
                    Pasteboard.copy(code)
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
            if rendered {
                CodeRenderView(language: language, code: code)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            } else {
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
        }
        .cardBackground(NookTheme.field, stroke: NookTheme.line2.opacity(0.6), radius: 10)
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
                    .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: 10)
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

    // Split into small typed parts: as one expression the grid takes the compiler too long to type-check.
    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                headerRow
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Divider().overlay(NookTheme.line2).gridCellColumns(header.count)
                    bodyRow(row, index: rowIndex)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .cardBackground(NookTheme.field, stroke: NookTheme.line2.opacity(0.6), radius: 10)
    }

    private var headerRow: some View {
        GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                headerCell(cell, column: column)
            }
        }
    }

    private func headerCell(_ cell: String, column: Int) -> some View {
        let alignment: HorizontalAlignment = numeric(column) ? .trailing : .leading
        return Text(MarkdownBlock.inline(cell, size: size))
            .font(NookTheme.font(size - 1.5, .semibold))
            .foregroundStyle(NookTheme.textSecondary)
            .gridColumnAlignment(alignment)
            .padding(.vertical, 8)
    }

    private func bodyRow(_ row: [String], index: Int) -> some View {
        let shade: Color = index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.02)
        return GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                bodyCell(cell, column: column)
            }
        }
        .background(shade)
    }

    private func bodyCell(_ cell: String, column: Int) -> some View {
        let weight: Font.Weight = column == 0 ? .medium : .regular
        return Text(MarkdownBlock.inline(cell, size: size))
            .font(NookTheme.font(size - 0.5, weight))
            .monospacedDigit()
            .foregroundStyle(NookTheme.paper)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
    }
}
