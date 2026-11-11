import SwiftUI
import UIKit

// An agent's answer as blocks, the way t3code's phone app reads it: headings, lists, quotes and call-outs as type, code
// and tables in a card of their own that scrolls sideways instead of wrapping, so a long answer reads as on the Mac. The
// blocks come from the Mac's own parser (`MarkdownBlock`, apps/macos/Brain/MarkdownBlock.swift, compiled into this app).

/// The blocks of one message, parsed once per text.
struct MarkdownBlocksView: View {
    let text: String
    var color: Color = Theme.textStrong

    var body: some View {
        let blocks = MarkdownParseCache.blocks(text)
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, color: color)
                    .padding(.top, Self.extraTop(block, first: index == 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A heading gets room above it, so the sections of a long answer stand apart.
    private static func extraTop(_ block: MarkdownBlock, first: Bool) -> CGFloat {
        guard !first, case .heading = block else { return 0 }
        return Theme.Spacing.sm
    }
}

/// Parsing is not free and a conversation redraws often: the blocks of the last texts are kept.
@MainActor
enum MarkdownParseCache {
    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let hit = cache[text] { return hit }
        let blocks = MarkdownBlock.parse(text)
        cache[text] = blocks
        order.append(text)
        if order.count > 120 { cache[order.removeFirst()] = nil }
        return blocks
    }
}

/// One block.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var color: Color = Theme.textStrong

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Markdown.text(text)
                .font(level <= 1 ? Theme.TextStyle.heading : level == 2 ? Theme.TextStyle.title : Theme.TextStyle.strong)
                .foregroundStyle(Theme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            prose(text)
        case .list(let items):
            MarkdownListView(items: items, color: color)
        case .code(let language, let code, let title):
            if language.lowercased() == "mermaid" {
                RichMessageText(text: "```mermaid\n" + code + "\n```", color: color)
            } else {
                MarkdownCodeBlock(language: language, code: code, title: title)
            }
        case .quote(let text):
            if let callout = Callout.detect(text) {
                MarkdownCallout(callout: callout)
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    NookDivider(vertical: true, tint: Theme.separator).frame(width: 3)
                    prose(text).foregroundStyle(Theme.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        case .rule:
            NookDivider(tint: Theme.hairline).padding(.vertical, Theme.Spacing.xs)
        case .math(let tex):
            RichMessageText(text: "$$\n" + tex + "\n$$", color: color)
        case .details(let summary, let body):
            MarkdownDetails(summary: summary, text: body, color: color)
        case .question(let text, let options):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                prose(text)
                MarkdownListView(items: options.enumerated().map { MarkdownListItem(level: 0, number: "\($0.offset + 1).", text: $0.element) },
                                 color: color)
            }
        case .pullRequest(let url):
            Link(destination: url) {
                Label(MarkdownBlock.pullRequestReference(url).map { "\($0.repo) #\($0.number)" } ?? url.absoluteString,
                      systemImage: "arrow.triangle.pull")
                    .font(Theme.TextStyle.strong)
                    .foregroundStyle(Theme.blue)
            }
        case .image(let alt, let source):
            if let url = URL(string: source), MarkdownBlock.isSafeLink(url) {
                Link(destination: url) {
                    Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo")
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(Theme.blue)
                }
            } else {
                Label(alt.isEmpty ? source : alt, systemImage: "photo")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .chart(let chart):
            Label(chart.title.isEmpty ? String(localized: "Chart") : chart.title, systemImage: "chart.bar")
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .roundedBackground(Theme.surface, radius: Theme.Radius.card)
        }
    }

    private func prose(_ text: String) -> some View {
        RichMessageText(text: text, color: color)
    }
}

/// A list with its bullets or numbers in a column of their own, nested items indented, tasks with a box.
struct MarkdownListView: View {
    let items: [MarkdownListItem]
    var color: Color = Theme.textStrong

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let task = MarkdownBlock.task(item.text)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    marker(item, task: task)
                        .frame(minWidth: item.number == nil ? 12 : 20, alignment: .trailing)
                    Markdown.text(task?.text ?? item.text)
                        .font(Theme.TextStyle.body)
                        .foregroundStyle(task?.done == true ? Theme.textTertiary : color)
                        .strikethrough(task?.done == true, color: Theme.textTertiary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, CGFloat(item.level) * Theme.Spacing.xl)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownListItem, task: (done: Bool, text: String)?) -> some View {
        if let task {
            Image(icon: task.done ? "checkmark.square.fill" : "square")
                .font(Theme.TextStyle.body)
                .foregroundStyle(task.done ? Theme.mint : Theme.textTertiary)
        } else if let number = item.number {
            Text(verbatim: number)
                .font(Theme.TextStyle.body)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        } else {
            Text(verbatim: item.level == 0 ? "•" : "◦")
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Code in a card: its language and a copy button on top, then the lines in the code font, scrolling sideways so a long
/// line never wraps into an unreadable column.
struct MarkdownCodeBlock: View {
    let language: String
    let code: String
    var title: String? = nil
    @State private var copied = false
    /// Long lines wrap instead of scrolling sideways.
    @State private var wraps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: title ?? (language.isEmpty ? String(localized: "Code") : language))
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    withAnimation(Theme.reveal) { wraps.toggle() }
                } label: {
                    Image(icon: "text.line.last.and.arrowtriangle.forward")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(wraps ? Theme.paper : Theme.textTertiary)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
                .accessibilityLabel(Text("Wrap lines"))
                Button {
                    UIPasteboard.general.string = code
                    Haptics.tap()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(icon: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(copied ? Theme.mint : Theme.textTertiary)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
                .accessibilityLabel(Text("Copy"))
            }
            .padding(.leading, Theme.Spacing.lg)
            .padding(.trailing, Theme.Spacing.xs)
            .frame(height: 30)
            NookDivider(tint: Theme.hairline)
            if wraps {
                codeText
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Spacing.lg)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    codeText.fixedSize().padding(Theme.Spacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(Theme.well, radius: Theme.Radius.card)
        .overlay(Theme.shape(Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

extension MarkdownCodeBlock {
    fileprivate var codeText: some View {
        Text(verbatim: code)
            .font(Theme.TextStyle.code)
            .foregroundStyle(Theme.textStrong)
            .lineSpacing(2)
            .textSelection(.enabled)
    }
}

/// A table that keeps its columns: it scrolls sideways when it is wider than the phone.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.md) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Markdown.text(cell).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper)
                    }
                }
                NookDivider(tint: Theme.hairline).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<max(header.count, row.count), id: \.self) { column in
                            Markdown.text(column < row.count ? row[column] : "")
                                .font(Theme.TextStyle.body)
                                .foregroundStyle(Theme.textStrong)
                                .frame(maxWidth: 260, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(Theme.surface, radius: Theme.Radius.card)
    }
}

/// `> [!NOTE]` and the like: an icon, its title and the text on a tinted card.
struct MarkdownCallout: View {
    let callout: Callout

    private var tint: Color {
        switch callout.kind {
        case .note: return Theme.blue
        case .tip: return Theme.mint
        case .warning: return Theme.amber
        case .danger: return Theme.coral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(callout.title, systemImage: callout.kind.symbol)
                .font(Theme.TextStyle.strong)
                .foregroundStyle(tint)
            if !callout.body.isEmpty {
                RichMessageText(text: callout.body)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(tint.opacity(0.1), radius: Theme.Radius.card)
    }
}

/// `<details>`: its summary as a line that opens to the rest.
struct MarkdownDetails: View {
    let summary: String
    let text: String
    var color: Color = Theme.textStrong
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button {
                withAnimation(Theme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(icon: "chevron.right")
                        .font(Theme.font(10, .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Markdown.text(summary).font(Theme.TextStyle.strong)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
            if open {
                MarkdownBlocksView(text: text, color: color)
                    .padding(.leading, Theme.Spacing.xl)
            }
        }
    }
}
