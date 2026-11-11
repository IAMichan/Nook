import SwiftUI
import AppKit

extension MarkdownBlock {
    /// Bold, italic, code, and links within an inline span. `files`: a code span that names a file by a relative path
    /// (`banner.png`) becomes a link, where there is a folder to read it from (`fileLinkBase`).
    ///
    /// Cached per text and size: `AttributedString(markdown:)` is slow, and every paragraph, bullet and table cell of every
    /// visible message asks for it again on each redraw (another message streaming in, hover, a keystroke).
    ///
    /// `citations`: the text is an answer from Nook with numbered sources, so its `[2]` and `[2, 4]` become small raised
    /// numbers (`citationMarks`) that open the source.
    static func inline(_ text: String, size: CGFloat = 14, files: Bool = false, citations: Bool = false) -> AttributedString {
        let key = "\(size)|\(files)|\(citations)|\(text)" as NSString
        if let hit = InlineCache.shared.object(forKey: key) { return hit.value }
        let value = renderInline(text, size: size, files: files, citations: citations)
        // The key holds the text in UTF-16, the value the text again with its runs.
        InlineCache.shared.setObject(InlineCache.Entry(value), forKey: key, cost: key.length * 6 + 64)
        return value
    }

    private static func renderInline(_ text: String, size: CGFloat, files: Bool, citations: Bool) -> AttributedString {
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
            let code = run.inlinePresentationIntent?.contains(.code) == true
            for (text, link) in linkPieces(String(parsed[run.range].characters), link: run.link, code: code, files: files) {
                if citations, !code, link == nil, Citations.contains(text) {
                    close()
                    result += citationMarks(text, size: size, attributes: run.attributes)
                    continue
                }
                var piece = AttributedString(text, attributes: run.attributes)
                let url = link.flatMap { isSafeLink($0) || isFileLink($0) || isCommitLink($0) ? $0 : nil }
                piece.link = url
                if code {
                    piece.font = .system(size: size * 0.85, design: .monospaced)
                    piece.backgroundColor = NookTheme.graphite
                    piece.foregroundColor = NookTheme.textStrong
                } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                    // Running text is a step softer than `paper`; bold keeps the full white, so it stands out without weight.
                    piece.foregroundColor = NookTheme.paper
                }
                if open?.url != url { close() }
                if let url { open = (url, (open?.text ?? "") + text) }
                result += piece
            }
        }
        close()
        return result
    }

    /// The scheme of a citation's link: `nook-cite:2` opens source 2 of the answer (`answerReferences`).
    static let citationScheme = "nook-cite"

    /// The source number a citation link opens, or nil when the link is not one.
    static func citationNumber(_ url: URL) -> Int? {
        guard url.scheme == citationScheme else { return nil }
        return Int(url.absoluteString.dropFirst(citationScheme.count + 1))
    }

    /// Text with `[2]` and `[3, 4]` in it, the citations as small raised numbers that open their source: "vandaag [5]"
    /// reads as "vandaag⁵", and "[2][3]" as "²˒³" instead of a row of brackets. The space before a citation goes, so the
    /// number sits against the fact it backs. Each number is marked with `CitationMark`, so the AppKit text can size it.
    private static func citationMarks(_ text: String, size: CGFloat, attributes: AttributeContainer) -> AttributedString {
        var result = AttributedString()
        var previousWasMark = false
        for piece in Citations.split(text) {
            switch piece {
            case .text(let words):
                result += AttributedString(words, attributes: attributes)
                previousWasMark = false
            case .citation(let numbers):
                for number in numbers {
                    if previousWasMark { result += mark(",", number: nil, size: size) }
                    result += mark("\(number)", number: number, size: size)
                    previousWasMark = true
                }
            }
        }
        return result
    }

    /// One raised number of a citation (or the comma between two), quieter and smaller than the text around it.
    private static func mark(_ text: String, number: Int?, size: CGFloat) -> AttributedString {
        var mark = AttributedString(text)
        mark.font = NookTheme.font(round(size * 0.7), .semibold)
        mark.baselineOffset = round(size * 0.36)
        mark.foregroundColor = NookTheme.textTertiary
        mark[CitationMark.self] = number ?? 0
        if let number { mark.link = URL(string: "\(citationScheme):\(number)") }
        return mark
    }

    /// A run's text in pieces, each with the link it opens: a code span that is a web address (`http://localhost:8080/`)
    /// or names a file (`banner.png`), and an address written out in plain text become links too, so they open in the
    /// side panel like any other.
    private static func linkPieces(_ text: String, link: URL?, code: Bool, files: Bool) -> [(text: String, link: URL?)] {
        if let link { return [(text, link)] }
        if code {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // In an agent's conversation a commit hash in code opens that commit in the session's Changes tab.
            if files, CommitReference.isHash(trimmed) { return [(text, CommitReference.link(trimmed))] }
            return [(text, codeLink(text) ?? codeFileLink(text, relative: files))]
        }
        var pieces: [(text: String, link: URL?)] = []
        var start = text.startIndex
        var matches = bareLinks(text)
        if files {
            let links = matches.map(\.range)
            for range in CommitReference.hashes(in: text) where !links.contains(where: { $0.overlaps(range) }) {
                if let url = CommitReference.link(String(text[range])) { matches.append((range, url)) }
            }
            matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        }
        for found in matches {
            if start < found.range.lowerBound { pieces.append((String(text[start..<found.range.lowerBound]), nil)) }
            pieces.append((String(text[found.range]), found.url))
            start = found.range.upperBound
        }
        if start < text.endIndex || pieces.isEmpty { pieces.append((String(text[start...]), nil)) }
        return pieces
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
        cache.totalCostLimit = 8 * 1024 * 1024
        MemoryPressure.shared.register("markdownInline", emptying: cache)
        return cache
    }()
}

/// A run of text blocks that select as one, or a single block drawn on its own (code, tables, charts, call-outs …).
private struct MarkdownSegment {
    /// Index of the segment's first block in the answer.
    let offset: Int
    let blocks: [MarkdownBlock]
    let prose: Bool

    static let proseLimit = 8

    /// Groups headings, paragraphs, and lists that follow each other; `kept` is a block that stays on its own.
    static func split(_ blocks: [MarkdownBlock], keeping kept: Int?) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        for (offset, block) in blocks.enumerated() {
            let prose = offset != kept && SelectableProse.joins(block)
            // At most `proseLimit` blocks per run: a streaming answer sets only its newest run again, and a finished run
            // keeps the exact blocks it had, so it stays equal.
            if prose, let last = segments.last, last.prose, last.blocks.count < proseLimit {
                segments[segments.count - 1] = MarkdownSegment(offset: last.offset, blocks: last.blocks + [block], prose: true)
            } else {
                segments.append(MarkdownSegment(offset: offset, blocks: [block], prose: prose))
            }
        }
        return segments
    }
}

/// A run of prose blocks, compared by value so SwiftUI leaves a finished run alone while the answer streams on.
private struct ProseSegment: View, Equatable {
    let blocks: [MarkdownBlock]
    let size: CGFloat

    var body: some View {
        SelectableProse(blocks: blocks, size: size)
            .alignmentGuide(.firstTextBaseline) { _ in SelectableProse.firstBaseline(blocks, size: size) }
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
        // Keyed by whole answers: by their length too, so a few long ones do not hold tens of megabytes.
        let cache = NSCache<NSString, ParsedMarkdown>()
        cache.countLimit = 400
        cache.totalCostLimit = 16 * 1024 * 1024
        MemoryPressure.shared.register("markdownBlocks", emptying: cache)
        return cache
    }()

    /// Texts parsed most recently, newest last, each with its parse kept for the next token. A text that continues one
    /// of them is the same answer one token further: only the text after its last finished block is parsed again
    /// (`IncrementalMarkdown`), and the shorter text is dropped from the cache, so a streaming answer keeps one entry
    /// instead of one per token, which pushed the parsed finished messages out of the cache and made them parse again.
    private static var recent: [IncrementalMarkdown<MarkdownBlock>] = []
    private static let recentLimit = 8
    private static let lock = NSLock()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        lock.lock()
        var parse = IncrementalMarkdown<MarkdownBlock>()
        if let earlier = recent.firstIndex(where: { $0.continues(text) }) {
            parse = recent.remove(at: earlier)
            cache.removeObject(forKey: parse.source as NSString)
        }
        let blocks = parse.update(text, parse: MarkdownBlock.parse)
        recent.append(parse)
        if recent.count > recentLimit { recent.removeFirst() }
        lock.unlock()
        // The answer as the key (UTF-16) and its blocks, which hold the text again.
        cache.setObject(ParsedMarkdown(blocks), forKey: key, cost: key.length * 4 + 64)
        return blocks
    }
}

private struct FileLinkBaseKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct PullRequestLinksBesideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The folder a relative file link in an answer is read from: the session's folder in an agent's conversation. Without
    /// it, only absolute paths open.
    var fileLinkBase: String? {
        get { self[FileLinkBaseKey.self] }
        set { self[FileLinkBaseKey.self] = newValue }
    }

    /// In an agent's conversation: a pull request or artifact link opens in the session's side panel, not on the Pull requests page.
    var pullRequestLinksBeside: Bool {
        get { self[PullRequestLinksBesideKey.self] }
        set { self[PullRequestLinksBesideKey.self] = newValue }
    }
}

extension MarkdownBlock {
    /// A commit hash Nook linked in an agent's answer (`CommitReference`).
    static func isCommitLink(_ url: URL) -> Bool { url.scheme == CommitReference.scheme && CommitReference.hash(in: url) != nil }

    /// In an agent's conversation, a commit hash or a GitHub commit page opens that commit in the session's Changes tab
    /// when its folder has it (a GitHub page it does not have opens as a page). False: not a commit link here.
    @MainActor
    static func openCommitLink(_ url: URL, base: String?, beside: Bool) -> Bool {
        guard beside, let base, let hash = CommitReference.hash(in: url) else { return isCommitLink(url) }
        AppModel.shared.openCommitBeside(hash, folder: base, fallback: url.scheme == CommitReference.scheme ? nil : url)
        return true
    }

    /// A link to a file (`src/app.swift:12:3`, `./README.md`, `file:///…`) rather than to a web page or a mail address.
    static func isFileLink(_ url: URL) -> Bool {
        guard !isSafeLink(url) else { return false }
        return FileLink.parse(url.absoluteString) != nil
    }

    /// The link of a code span that names a file (`FileLink.named`), as written; a relative path only when `relative`.
    static func codeFileLink(_ code: String, relative: Bool) -> URL? {
        let text = code.trimmingCharacters(in: .whitespaces)
        guard let target = FileLink.named(text), relative || target.path.hasPrefix("/") || target.path.hasPrefix("~") else { return nil }
        return URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text)
    }

    /// Opens a file link in Nook's own viewer at its line (`AppModel.openFileInNook`), beside the session in an agent's
    /// conversation. A bare name that is not in the session's folder itself is looked up inside it (`FileLink.locate`).
    /// False when it is not a file link or cannot be placed (a relative path without a folder).
    @MainActor
    static func openFileLink(_ url: URL, base: String?, beside: Bool) -> Bool {
        guard isFileLink(url), let target = FileLink.parse(url.absoluteString),
              let resolved = FileLink.resolve(target, base: base) else { return false }
        if FileManager.default.fileExists(atPath: resolved.path) {
            AppModel.shared.openFileInNook(resolved, beside: beside)
            return true
        }
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { FileLink.find(target, base: base) }.value
            AppModel.shared.openFileInNook(found ?? resolved, beside: beside)
        }
        return true
    }
}

struct MarkdownView: View, Equatable {
    @Environment(\.fileLinkBase) private var fileLinkBase
    @Environment(\.pullRequestLinksBeside) private var pullRequestLinksBeside
    @Environment(\.answerReferences) private var answerReferences
    let text: String
    var size: CGFloat = 14
    /// When set, the options of a question at the end of the answer become buttons that answer it. Read off the main
    /// actor only by `==`, and only for whether it is set.
    nonisolated(unsafe) var onChoose: ((String) -> Void)? = nil
    /// Builds only the blocks in view: for a whole document in a scroll view of its own (a Markdown file in the side
    /// panel), where drawing every paragraph, table and code block at once held the main thread for seconds. An answer
    /// in a conversation is already a row of a lazy timeline and stays eager.
    var lazy = false

    /// The same text at the same size draws the same: a row that redraws on hover or while scrolling past skips it.
    nonisolated static func == (a: MarkdownView, b: MarkdownView) -> Bool {
        a.text == b.text && a.size == b.size && a.lazy == b.lazy && (a.onChoose == nil) == (b.onChoose == nil)
    }

    var body: some View {
        let blocks = MarkdownCache.blocks(text)
        let choices = onChoose == nil ? nil : MarkdownBlock.trailingChoices(blocks)
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.lg) { segments(blocks, choices: choices) }
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) { segments(blocks, choices: choices) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { [fileLinkBase, pullRequestLinksBeside, answerReferences] url in
            if let number = MarkdownBlock.citationNumber(url) {
                MainActor.assumeIsolated { AnswerCitation.open(number, in: answerReferences) }
                return .handled
            }
            if MainActor.assumeIsolated({ MarkdownBlock.openCommitLink(url, base: fileLinkBase, beside: pullRequestLinksBeside) }) {
                return .handled
            }
            if MarkdownBlock.isFileLink(url) {
                return MainActor.assumeIsolated { MarkdownBlock.openFileLink(url, base: fileLinkBase, beside: pullRequestLinksBeside) }
                    ? .handled : .discarded
            }
            guard MarkdownBlock.isSafeLink(url) else { return .discarded }
            // A pull request opens in Nook: beside the session, or on the Pull requests page.
            if MainActor.assumeIsolated({ AppModel.shared.openPullRequestLink(url, beside: pullRequestLinksBeside) }) { return .handled }
            // In an agent's conversation any web page opens in the session's side panel (⌘-click: the system browser).
            if pullRequestLinksBeside {
                // Your own browser: while Nook is the default browser that is the one you had before, not Nook again.
                return MainActor.assumeIsolated {
                    if !AppModel.shared.openLinkBeside(url) { DefaultBrowser.openOutside(url) }
                    return .handled
                }
            }
            // An artifact opens beside the chat, next to the app that made it.
            guard EmbeddedArtifact.app(for: url) != nil else { return .systemAction }
            Task { @MainActor in AppModel.shared.openArtifact(url) }
            return .handled
        })
    }

    private func segments(_ blocks: [MarkdownBlock], choices: (index: Int, options: [String])?) -> some View {
        ForEach(MarkdownSegment.split(blocks, keeping: choices?.index), id: \.offset) { segment in
            if let choices, choices.index == segment.offset {
                ChoiceList(options: choices.options, size: size) { onChoose?($0) }
            } else if segment.prose {
                // Segments are keyed by their first block, which a streaming answer never moves; equal blocks
                // skip the text view's update, so only the segment still being written is set again.
                ProseSegment(blocks: segment.blocks, size: size).equatable()
            } else {
                view(for: segment.blocks[0])
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text) where MathText.containsMath(text):
            // Running text with formulas in it: typeset as a whole, so the formulas sit in the line.
            MathView(text: text, size: size)
        case .heading, .paragraph, .list:
            ProseSegment(blocks: [block], size: size)
        case .math(let tex):
            if MathText.renderingEnabled {
                MathView(text: tex, display: true, size: size)
            } else {
                MarkdownCodeBlock(language: "math", code: tex, size: size)
            }
        case .code(let language, let code, let title):
            MarkdownCodeBlock(language: language, code: code, title: title, size: size)
        case .details(let summary, let body):
            MarkdownDetailsBlock(summary: summary, text: body, size: size)
        case .image(let alt, let source):
            MarkdownImageBlock(alt: alt, source: source)
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
                            Text("•").foregroundStyle(NookTheme.textSecondary)
                            paragraph(option)
                        }
                    }
                }
            }
        case .quote(let text):
            if let callout = Callout.detect(text) {
                CalloutBlock(callout: callout, size: size)
            } else {
                HStack(spacing: NookTheme.Spacing.lg) {
                    Rectangle().fill(NookTheme.textStrong.opacity(0.35)).frame(width: 2)
                    paragraph(text, color: NookTheme.textStrong)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, size: size).equatable()
        case .rule:
            NookDivider().padding(.vertical, 4)
        case .pullRequest:
            // Lives in the tray above the composer (`PullRequestWatchStrip`), where it can be followed and shows its checks.
            EmptyView()
        }
    }

    private func paragraph(_ text: String, color: Color = NookTheme.textStrong) -> some View {
        Text(MarkdownBlock.inline(text, size: size, files: fileLinkBase != nil, citations: !answerReferences.isEmpty))
            .font(NookTheme.font(size))
            .lineSpacing(5)
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
    @Environment(\.fileLinkBase) private var fileLinkBase
    let callout: Callout
    let size: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Image(icon: callout.kind.symbol)
                .font(NookTheme.font(size - 1, .medium))
                .foregroundStyle(callout.kind.color)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Text(callout.title)
                    .font(NookTheme.font(size - 1, .semibold))
                    .foregroundStyle(callout.kind.color)
                if !callout.body.isEmpty {
                    Text(MarkdownBlock.inline(callout.body, size: size, files: fileLinkBase != nil))
                        .font(NookTheme.font(size))
                        .lineSpacing(4)
                        .foregroundStyle(NookTheme.textStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(NookTheme.Spacing.lg)
        // Tinted, without an edge: the color says what kind of note it is, the fill keeps it apart from the text.
        .roundedBackground(callout.kind.color.opacity(0.08), radius: NookTheme.Radius.panel)
    }
}

// MARK: Code

private struct MarkdownCodeBlock: View {
    @Environment(\.fileLinkBase) private var fileLinkBase
    let language: String
    let code: String
    var title: String? = nil
    let size: CGFloat
    /// HTML, SVG and Mermaid: shown as what they draw instead of their source.
    @State private var rendered = false
    /// Long lines wrap instead of scrolling sideways.
    @State private var wraps = false
    /// How far the code and its language sit from the block's edge.
    private static let inset: CGFloat = 14

    /// A shell block runs in a terminal in the session's folder; not one that ends mid-command or hides control characters.
    private var runnable: Bool {
        guard fileLinkBase != nil, CodeBlockStyle.isShell(language) else { return false }
        return CodeBlockStyle.canRun(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The file (or else the language) on the left, the actions as quiet symbol buttons on the right.
            HStack(spacing: NookTheme.Spacing.xxs) {
                if let title {
                    Image(icon: "doc.text")
                        .font(NookTheme.font(10, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(title)
                        .font(NookTheme.mono(11))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(language.isEmpty ? title : "\(title) · \(language)")
                        .padding(.leading, NookTheme.Spacing.xxs)
                } else {
                    Text(language.isEmpty ? "code" : language)
                        .font(NookTheme.mono(11))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                Spacer()
                if CodeRenderView.canRender(language) {
                    ToolbarIconButton(rendered ? "chevron.left.forwardslash.chevron.right" : "eye",
                                      rendered ? tr("code.source") : tr("code.preview")) { rendered.toggle() }
                }
                if !rendered {
                    ToolbarIconButton("arrow.turn.down.left", wraps ? tr("code.noWrap") : tr("code.wrap"), selected: wraps) {
                        wraps.toggle()
                    }
                }
                if runnable, let base = fileLinkBase {
                    ToolbarIconButton("play", tr("code.runInTerminal")) {
                        AppModel.shared.openTerminal(in: base, command: CodeBlockStyle.command(code), title: title)
                    }
                }
                CopyIconButton(tr("button.copy")) { code }
            }
            .padding(.leading, Self.inset)
            .padding(.trailing, NookTheme.Spacing.sm)
            .padding(.top, NookTheme.Spacing.sm)
            if rendered {
                CodeRenderView(language: language, code: code)
                    .frame(height: 280)
                    .roundedClip(NookTheme.Radius.chip)
                    .padding(8)
            } else if wraps {
                codeText.fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    codeText.fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .roundedBackground(NookTheme.well, radius: NookTheme.Radius.control)
    }

    /// The code in the colors of its language (`SyntaxTokenizer`), or plain when Nook does not know it.
    private var codeText: some View {
        Group {
            if let colored = CodeBlockStyle.highlighted(code, language: language, title: title) {
                Text(colored)
            } else {
                Text(code).foregroundStyle(NookTheme.textStrong)
            }
        }
        .font(NookTheme.mono(size - 1))
        .lineSpacing(3)
        .textSelection(.enabled)
        .padding(.horizontal, Self.inset)
        .padding(.top, NookTheme.Spacing.xs)
        .padding(.bottom, NookTheme.Spacing.lg)
    }
}

/// Colors and actions of a code block in an answer.
enum CodeBlockStyle {
    private static let cache = BoundedCache<String, AttributedString>(limit: 200)
    /// Past this a block stays plain: coloring it on every token of a streaming answer would cost more than it gives.
    static let colorLimit = 20_000

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "shell", "console", "shellsession", "powershell", "pwsh", "ps1"]

    static func isShell(_ language: String) -> Bool { shells.contains(language) }

    /// The language a fence names, as the tokenizer knows it; the file name decides when the fence names none.
    static func syntax(_ language: String, title: String?) -> SyntaxLanguage? {
        let aliases: [String: String] = [
            "typescript": "ts", "javascript": "js", "tsx": "tsx", "jsx": "jsx", "python": "py", "py": "py", "rust": "rs",
            "golang": "go", "yml": "yaml", "shell": "sh", "console": "sh", "zsh": "zsh", "bash": "sh", "sh": "sh",
            "markdown": "md", "md": "md", "xml": "xml", "svg": "svg", "vue": "vue", "svelte": "svelte", "jsonc": "jsonc",
            "json5": "json5", "scss": "scss", "less": "less"
        ]
        if !language.isEmpty, let known = SyntaxLanguage.detect(path: "x." + (aliases[language] ?? language)) { return known }
        return title.flatMap { SyntaxLanguage.detect(path: $0) }
    }

    /// The code with its tokens colored; nil for a language the tokenizer does not know, or a very long block.
    static func highlighted(_ code: String, language: String, title: String?) -> AttributedString? {
        guard let syntax = syntax(language, title: title) else { return nil }
        return highlighted(code, syntax: syntax)
    }

    static func highlighted(_ code: String, syntax: SyntaxLanguage) -> AttributedString? {
        guard code.utf16.count <= colorLimit else { return nil }
        let key = syntax.rawValue + "\u{0}" + code
        if let hit = cache.value(for: key) { return hit }
        var result = AttributedString()
        var carry = SyntaxTokenizer.Carry.none
        for (index, line) in code.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let (tokens, next) = SyntaxTokenizer.tokenize(line, language: syntax, carry: carry)
            carry = next
            let units = Array(line.utf16)
            for segment in DiffSyntax.segments(length: units.count, tokens: tokens, changed: nil) {
                var part = AttributedString(String(decoding: units[segment.start..<segment.end], as: UTF16.self))
                part.foregroundColor = segment.kind.map(DiffSyntaxStyle.color) ?? NookTheme.textStrong
                result += part
            }
        }
        cache.set(result, for: key)
        return result
    }

    /// A block that can be run as it is: not empty, not ending on a line continuation, and with no control characters
    /// that could hide what it does.
    static func canRun(_ code: String) -> Bool {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasSuffix("\\") else { return false }
        return !text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\n" && scalar != "\t") || scalar.value == 0x7F
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        }
    }

    /// The command a shell block runs: without the `$ ` prompts a model often writes in front of each line.
    static func command(_ code: String) -> String {
        let lines = code.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let prompted = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix("$ ") }
        return (prompted ? lines.map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 } : lines).joined(separator: "\n")
    }
}

// MARK: Questions

/// The options of a question as cards to tap: the tap is the answer.
struct ChoiceList: View {
    let options: [String]
    let size: CGFloat
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                ChoiceRow(letter: String(UnicodeScalar(UInt8(65 + min(index, 25)))), option: option, size: size) {
                    choose(Self.plain(option))
                }
            }
        }
    }

    /// The reply is the option without its Markdown markers.
    static func plain(_ option: String) -> String {
        option.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

/// One option of a question: its letter, the option, and an arrow that shows under the pointer.
private struct ChoiceRow: View {
    let letter: String
    let option: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Text(letter)
                    .font(NookTheme.rounded(size - 2.5, .semibold))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(NookTheme.smoke))
                Text(MarkdownBlock.inline(option, size: size))
                    .font(NookTheme.font(size))
                    .foregroundStyle(NookTheme.paper)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(icon: "arrow.up.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .roundedBackground(hovering ? NookTheme.graphite : NookTheme.field, radius: NookTheme.Radius.panel)
            .roundedHitShape(NookTheme.Radius.panel)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

// MARK: Table

private struct TableBlock: View, Equatable {
    @Environment(\.fileLinkBase) private var fileLinkBase
    let header: [String]
    let rows: [[String]]
    let size: CGFloat
    @State private var showChart = false

    nonisolated static func == (a: TableBlock, b: TableBlock) -> Bool {
        a.header == b.header && a.rows == b.rows && a.size == b.size
    }

    private var chart: ChatChart? { ChartRescue.chart(fromTable: header, rows: rows, title: "") }

    /// A column of only numbers is right-aligned, so digits line up.
    private func numeric(_ column: Int) -> Bool {
        !rows.isEmpty && rows.allSatisfy { column < $0.count && (ChartRescue.tableNumber($0[column]) != nil || $0[column].isEmpty || $0[column] == "-" || $0[column] == "–") }
    }

    var body: some View {
        // Once per body: the chart and which columns are numbers do not change cell by cell.
        let chart = self.chart
        let numbers = (0..<header.count).map { numeric($0) }
        VStack(alignment: .leading, spacing: 8) {
            if let chart {
                NookTabBar(items: [
                    .init(value: false, title: tr("table.table"), symbol: "tablecells"),
                    .init(value: true, title: tr("table.chart"), symbol: "chart.bar.xaxis")
                ], selected: showChart) { value in
                    withAnimation(NookTheme.swap) { showChart = value }
                }
                if showChart { ChatChartView(chart: chart) } else { grid(numbers) }
            } else {
                grid(numbers)
            }
            if !showChart || chart == nil {
                HStack {
                    Spacer(minLength: 0)
                    TableCopyMenu(header: header, rows: rows)
                }
                .padding(.top, -NookTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Split into small typed parts: as one expression the grid takes the compiler too long to type-check.
    private func grid(_ numbers: [Bool]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: NookTheme.Spacing.xxl, verticalSpacing: 0) {
                headerRow(numbers)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Divider().overlay(NookTheme.line2).gridCellColumns(header.count)
                    bodyRow(row, index: rowIndex)
                }
            }
            .padding(.vertical, NookTheme.Spacing.xxs)
        }
    }

    private func headerRow(_ numbers: [Bool]) -> some View {
        GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                headerCell(cell, numeric: numbers[column])
            }
        }
    }

    private func headerCell(_ cell: String, numeric: Bool) -> some View {
        let alignment: HorizontalAlignment = numeric ? .trailing : .leading
        return Text(MarkdownBlock.inline(cell, size: size, files: fileLinkBase != nil))
            .font(NookTheme.font(size, .semibold))
            .foregroundStyle(NookTheme.paper)
            .gridColumnAlignment(alignment)
            .padding(.vertical, NookTheme.Spacing.md)
    }

    private func bodyRow(_ row: [String], index: Int) -> some View {
        return GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                bodyCell(cell, column: column)
            }
        }
    }

    private func bodyCell(_ cell: String, column: Int) -> some View {
        let weight: Font.Weight = column == 0 ? .medium : .regular
        return Text(MarkdownBlock.inline(cell, size: size, files: fileLinkBase != nil))
            .font(NookTheme.font(size, weight))
            .monospacedDigit()
            .foregroundStyle(NookTheme.textStrong)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, NookTheme.Spacing.md)
    }
}
