import SwiftUI
import AppKit

private struct QuoteSelectionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

private struct AskAboutSelectionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set where an answer has a reply box under it (a session's conversation): selected words of the answer can be
    /// quoted into it from the right-click menu, to cite a selection in the composer.
    var quoteSelection: ((String) -> Void)? {
        get { self[QuoteSelectionKey.self] }
        set { self[QuoteSelectionKey.self] = newValue }
    }

    /// Set next to `quoteSelection`: "Ask about this" in the right-click menu quotes the selected words and puts the
    /// keyboard in the reply box, to ask about them.
    var askAboutSelection: ((String) -> Void)? {
        get { self[AskAboutSelectionKey.self] }
        set { self[AskAboutSelectionKey.self] = newValue }
    }
}

/// Headings, paragraphs, and lists that follow each other in an answer, drawn as one read-only text view so a selection
/// can run across several paragraphs. SwiftUI only selects within a single `Text`, so a drag stopped at every paragraph.
struct SelectableProse: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    var size: CGFloat = 14

    /// Whether a block is plain text that can join a selectable run.
    static func joins(_ block: MarkdownBlock) -> Bool {
        switch block {
        // A paragraph with formulas is typeset on its own (`MathView`).
        case .paragraph(let text): return !MathText.containsMath(text)
        case .heading, .list: return true
        default: return false
        }
    }

    /// Distance from the top of the view to its first line's baseline, so an `HStack(alignment: .firstTextBaseline)`
    /// lines a control up with the first line (`NSViewRepresentable` with `sizeThatFits` otherwise reports 0).
    static func firstBaseline(_ blocks: [MarkdownBlock], size: CGFloat) -> CGFloat {
        if case .heading(let level, _) = blocks.first {
            let headingSize = level <= 1 ? size + 6 : level == 2 ? size + 4 : level == 3 ? size + 2 : size
            return 10 + ceil(NSFont.systemFont(ofSize: headingSize, weight: .semibold).ascender)
        }
        return ceil(NSFont.systemFont(ofSize: size).ascender)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The words selected in an answer's text view, trimmed; nil when nothing is selected.
    static func selection(of view: NSTextView) -> String? {
        let range = view.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (view.string as NSString).length else { return nil }
        let text = ComposerQuotes.normalize(ProseTextView.plain((view.string as NSString).substring(with: range)))
        return text.isEmpty ? nil : text
    }

    /// The words selected in an answer that has the keyboard in `window` (for the `selection.quote` and `selection.ask`
    /// keys); nil when the keyboard is elsewhere or nothing is selected.
    @MainActor
    static func selection(in window: NSWindow?) -> String? {
        guard let view = window?.firstResponder as? NSTextView, view.delegate is Coordinator else { return nil }
        return selection(of: view)
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = ProseTextView(usingTextLayoutManager: false)
        // Inline code draws as a rounded chip rather than the flat, line-high band of a background color.
        view.textContainer?.replaceLayoutManager(InlineCodeLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            // No underline and no color of its own: a link is in the link blue already (`inline`), a citation in its
            // grey. The pointer says they are links.
            .cursor: NSCursor.pointingHand,
        ]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.fileLinkBase = context.environment.fileLinkBase
        context.coordinator.pullRequestLinksBeside = context.environment.pullRequestLinksBeside
        context.coordinator.quote = context.environment.quoteSelection
        context.coordinator.ask = context.environment.askAboutSelection
        let references = context.environment.answerReferences
        context.coordinator.references = references
        (view as? ProseTextView)?.citationReferences = references
        let files = context.environment.fileLinkBase != nil
        let citations = !references.isEmpty
        // The same blocks as last time (a redraw on hover or while scrolling): nothing to build or compare. Comparing the
        // blocks is cheap next to describing them all for the cache key.
        let input = Coordinator.Input(blocks: blocks, size: size, files: files, accent: NookTheme.accentHex,
                                      references: references)
        guard input != context.coordinator.input else { return }
        context.coordinator.input = input
        let text = Self.withCitationLabels(Self.attributed(blocks, size: size, files: files, citations: citations), references, size: size)
        // The cache hands back the same text for the same blocks: skip comparing it character by character on every
        // redraw (hover, scrolling, another message streaming in).
        guard text !== context.coordinator.shown else { return }
        guard let storage = view.textStorage, !storage.isEqual(to: text) else {
            context.coordinator.shown = text
            return
        }
        context.coordinator.shown = text
        // A streaming answer only grows: keep what the user already selected.
        (view as? ProseTextView)?.endCitationHover()
        let selection = view.selectedRanges
        storage.setAttributedString(text)
        context.coordinator.setMeasured(text)
        let kept = selection.filter { NSMaxRange($0.rangeValue) <= text.length }
        view.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        (view as? ProseTextView)?.endCitationHover()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        if let storage = view.textStorage, context.coordinator.measure.length != storage.length {
            context.coordinator.setMeasured(storage)
        }
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let used = context.coordinator.usedSize(width: proposed ?? 10_000)
        return CGSize(width: proposed ?? ceil(used.width), height: ceil(used.height))
    }

    /// Measures on its own layout stack: probing sizes on the text view's container would leave it at a probed width.
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measure = NSTextStorage()
        /// What the text was last built from.
        struct Input: Equatable {
            let blocks: [MarkdownBlock]
            let size: CGFloat
            let files: Bool
            let accent: UInt32
            /// The answer's sources: its citations open them and name them in a hover.
            let references: [SourceReference]
        }
        var input: Input?
        /// The text last put in the view, so an unchanged redraw returns at once.
        var shown: NSAttributedString?
        /// The last measured width and its size: SwiftUI asks again for the same width on every layout pass.
        private var measured: (width: CGFloat, size: CGSize)?
        /// The session's folder, for a relative file link in the text.
        var fileLinkBase: String?
        var pullRequestLinksBeside = false
        /// Quotes selected words into the reply box, when there is one.
        var quote: ((String) -> Void)?
        /// Quotes them and puts the keyboard in the reply box.
        var ask: ((String) -> Void)?
        /// The answer's sources, for a click on a citation.
        var references: [SourceReference] = []
        /// A quote longer than this is refused: the reply should point at a passage, not repeat the answer.
        static let quoteLimit = ComposerQuotes.characterLimit

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            addLinkItems(to: menu, in: view, at: charIndex)
            guard quote != nil || ask != nil, let text = SelectableProse.selection(of: view) else { return menu }
            var index = 0
            for (title, action, wanted) in [
                (tr("ws.review.quoteSelection"), #selector(quoteSelection(_:)), quote != nil),
                (tr("selection.ask"), #selector(askAboutSelection(_:)), ask != nil),
            ] where wanted {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = text
                item.isEnabled = text.count <= Self.quoteLimit
                if !item.isEnabled { item.toolTip = tr("ws.review.quoteTooLong") }
                menu.insertItem(item, at: index)
                index += 1
            }
            menu.insertItem(.separator(), at: index)
            return menu
        }

        /// On a web link in an agent's conversation: open it in the side panel or the system browser, or copy it.
        private func addLinkItems(to menu: NSMenu, in view: NSTextView, at charIndex: Int) {
            guard pullRequestLinksBeside, let storage = view.textStorage, charIndex >= 0, charIndex < storage.length,
                  let link = storage.attribute(.link, at: charIndex, effectiveRange: nil),
                  let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
                  MarkdownBlock.isSafeLink(url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            for (offset, (title, action)) in [
                (tr("link.openInPanel"), #selector(openLinkInPanel(_:))),
                (tr("link.openSystem"), #selector(openLinkInSystem(_:))),
                (tr("link.copy"), #selector(copyLink(_:))),
            ].enumerated() {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = url
                menu.insertItem(item, at: offset)
            }
            menu.insertItem(.separator(), at: 3)
        }

        @objc private func openLinkInPanel(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            Task { @MainActor in AppModel.shared.openLinkBeside(url, forced: true) }
        }

        @objc private func openLinkInSystem(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSWorkspace.shared.open(url)
        }

        @objc private func copyLink(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }

        @objc private func quoteSelection(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            quote?(text)
        }

        @objc private func askAboutSelection(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            ask?(text)
        }
        private let layout = NSLayoutManager()
        private let container = NSTextContainer()

        override init() {
            super.init()
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            measure.addLayoutManager(layout)
        }

        /// Puts new text in the measuring stack and forgets the sizes measured for the old one.
        func setMeasured(_ text: NSAttributedString) {
            measure.setAttributedString(text)
            measured = nil
        }

        func usedSize(width: CGFloat) -> CGSize {
            if let measured, measured.width == width { return measured.size }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let size = layout.usedRect(for: container).size
            measured = (width, size)
            return size
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, let number = MarkdownBlock.citationNumber(url) {
                // One source that opens: open it. Several, or one with nothing to open (a calendar event): show what they
                // say, with a button per source that opens.
                let references = references
                MainActor.assumeIsolated {
                    let cited = (textView as? ProseTextView)?.citedReferences(at: charIndex) ?? []
                    if cited.count <= 1, let only = cited.first ?? references.first(where: { $0.number == number }),
                       SourceReference.isOpenable(only.url) {
                        AnswerCitation.open(only.number, in: references)
                    } else {
                        (textView as? ProseTextView)?.showCitationPreview(at: charIndex, pinned: true)
                    }
                }
                return true
            }
            if let url, MainActor.assumeIsolated({ MarkdownBlock.openCommitLink(url, base: fileLinkBase, beside: pullRequestLinksBeside) }) {
                return true
            }
            if let url, MarkdownBlock.isFileLink(url) {
                let base = fileLinkBase, beside = pullRequestLinksBeside
                Task { @MainActor in _ = MarkdownBlock.openFileLink(url, base: base, beside: beside) }
                return true
            }
            guard let url, MarkdownBlock.isSafeLink(url) else { return true }
            // A pull request opens in Nook (beside the session, or on the Pull requests page), an artifact beside the
            // chat next to the app that made it; in an agent's conversation every web link opens in the side panel.
            let beside = pullRequestLinksBeside
            if MainActor.assumeIsolated({ AppModel.shared.openPullRequestLink(url, beside: beside) }) {
                return true
            } else if beside {
                // In an agent's conversation any web page opens in the session's side panel (⌘-click: the system browser).
                if !MainActor.assumeIsolated({ AppModel.shared.openLinkBeside(url) }) { MainActor.assumeIsolated { DefaultBrowser.openOutside(url) } }
            } else if EmbeddedArtifact.app(for: url) != nil {
                Task { @MainActor in AppModel.shared.openArtifact(url) }
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }

    // MARK: Building the text

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 400
        cache.totalCostLimit = 8 * 1024 * 1024
        MemoryPressure.shared.register("selectableProse", emptying: cache)
        return cache
    }()

    /// What the text is built from, as a plain string (no reflection): only the blocks that draw as prose count, each
    /// with its length so two different splits of the same characters never share a key.
    private static func cacheKey(_ blocks: [MarkdownBlock]) -> String {
        var key = ""
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                key += "h\(level):\(text.utf8.count):\(text)\u{1E}"
            case .paragraph(let text):
                key += "p:\(text.utf8.count):\(text)\u{1E}"
            case .list(let items):
                key += "l\(items.count)"
                for item in items { key += ":\(item.level):\(item.number ?? ""):\(item.text.utf8.count):\(item.text)" }
                key += "\u{1E}"
            default:
                key += "-\u{1E}"
            }
        }
        return key
    }

    /// The blocks as one attributed text, in the same sizes, colors, and spacing as the SwiftUI blocks around them.
    /// `files`: a code span that names a file by a relative path becomes a link (there is a folder to read it from).
    /// `citations`: an answer from Nook with numbered sources, whose `[2]` become raised numbers that open them.
    static func attributed(_ blocks: [MarkdownBlock], size: CGFloat, files: Bool = false, citations: Bool = false) -> NSAttributedString {
        let key = "\(size)|\(files)|\(citations)|\(NookTheme.accentHex)|\(NookTheme.revision)|\(cacheKey(blocks))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            // The room the answer's blocks keep between them, so paragraphs read as paragraphs.
            let gap: CGFloat = index == 0 ? 0 : 10
            switch block {
            case .heading(let level, let text):
                let headingSize = level <= 1 ? size + 6 : level == 2 ? size + 4 : level == 3 ? size + 2 : size
                let line = inline(text, size: headingSize, weight: .semibold, color: NookTheme.paper, files: files, citations: citations)
                // A heading takes more room above than below, so it clearly belongs to the text under it.
                append(line, style: style(before: gap + 10, lineSpacing: 1), to: result)
            case .paragraph(let text):
                // Running text a step softer than headings (answers at 80 % of the text color).
                append(inline(text, size: size, weight: .regular, color: NookTheme.textStrong, files: files, citations: citations),
                       style: style(before: gap), to: result)
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    appendItem(item, before: itemIndex == 0 ? gap : 4, size: size, files: files, citations: citations, to: result)
                }
            default:
                break
            }
        }
        // The key spells the blocks out (UTF-16); the text holds them again with its attributes.
        cache.setObject(result, forKey: key, cost: key.length * 2 + result.length * 4 + 64)
        return result
    }

    /// `lineSpacing` 5 gives running text about a relaxed 1.6 line height.
    private static func style(before: CGFloat, lineSpacing: CGFloat = 5) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        return style
    }

    private static func append(_ paragraph: NSMutableAttributedString, style: NSParagraphStyle, to result: NSMutableAttributedString) {
        if result.length > 0 {
            // The line break belongs to the paragraph before it, so it takes that paragraph's style.
            let previous = result.attributes(at: result.length - 1, effectiveRange: nil)
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: previous[.font] ?? NSFont.systemFont(ofSize: 14),
                .paragraphStyle: previous[.paragraphStyle] ?? NSParagraphStyle.default,
            ]))
        }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        result.append(paragraph)
    }

    /// A list item: its marker in a column, the text indented past it on every line, nested items further in.
    private static func appendItem(_ item: MarkdownListItem, before: CGFloat, size: CGFloat, files: Bool, citations: Bool,
                                   to result: NSMutableAttributedString) {
        let indent = CGFloat(item.level) * (size + 4)
        let font = NSFont.systemFont(ofSize: size)
        let line = NSMutableAttributedString()
        let paragraph = style(before: before)
        paragraph.firstLineHeadIndent = indent
        var text = item.text
        var color = item.level == 0 ? NookTheme.textStrong : NookTheme.textSecondary
        if let task = MarkdownBlock.task(item.text) {
            text = task.text
            color = task.done ? NookTheme.textSecondary : NookTheme.textStrong
            let box = NSAttributedString(string: task.done ? "☑" : "☐", attributes: [
                .font: font, .foregroundColor: NSColor(task.done ? NookTheme.mint : NookTheme.textTertiary),
            ])
            let textStart = indent + ceil(box.size().width) + 8
            line.append(box)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
            paragraph.headIndent = textStart
        } else if let number = item.number {
            let marker = NSAttributedString(string: number, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor(NookTheme.textSecondary),
            ])
            // Numbers are right-aligned in a column of at least 16 points, so short numbers line up.
            let column = indent + max(16, ceil(marker.size().width))
            line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            line.append(marker)
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: column), NSTextTab(textAlignment: .left, location: column + 8)]
            paragraph.headIndent = column + 8
        } else {
            let bullet = bullets[min(item.level, bullets.count - 1)]
            let marker = NSAttributedString(string: bullet, attributes: [
                .font: font, .foregroundColor: NSColor(item.level == 0 ? NookTheme.textSecondary : NookTheme.textTertiary),
            ])
            line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            line.append(marker)
            paragraph.tabStops = [NSTextTab(textAlignment: .center, location: indent + 4), NSTextTab(textAlignment: .left, location: indent + 16)]
            paragraph.headIndent = indent + 16
        }
        line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        line.append(inline(text, size: size, weight: .regular, color: color, files: files, citations: citations))
        append(line, style: paragraph, to: result)
    }

    private static let bullets = ["•", "◦", "▪"]

    /// The text with each citation (the raised numbers `inline` set, `[2][3]` as one) turned into a label: a space, the
    /// first source's icon and short name, and "+2" for more, drawn as a pill by `InlineCodeLayoutManager`. It still opens
    /// the source on a click, and `ProseTextView` shows what the sources say when the pointer rests on it. A citation of a
    /// number the answer has no source for keeps its raised number.
    @MainActor
    static func withCitationLabels(_ text: NSAttributedString, _ references: [SourceReference], size: CGFloat) -> NSAttributedString {
        guard !references.isEmpty else { return text }
        var groups: [(range: NSRange, numbers: [Int])] = []
        text.enumerateAttribute(.citation, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let number = value as? Int else { return }
            if let last = groups.last, NSMaxRange(last.range) == range.location {
                groups[groups.count - 1].range.length += range.length
                if number != 0 { groups[groups.count - 1].numbers.append(number) }
            } else {
                groups.append((range, number == 0 ? [] : [number]))
            }
        }
        guard !groups.isEmpty, let copy = text.mutableCopy() as? NSMutableAttributedString else { return text }
        for (index, group) in groups.enumerated().reversed() {
            let cited = AnswerCitation.references(group.numbers, in: references)
            guard !cited.isEmpty else { continue }
            let id = "\(index)|" + cited.map { String($0.number) }.joined(separator: ",")
            copy.replaceCharacters(in: group.range, with: citationLabel(cited, id: id, size: size))
        }
        return copy
    }

    /// One citation's label (see `withCitationLabels`).
    @MainActor
    private static func citationLabel(_ cited: [SourceReference], id: String, size: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: round(size * 0.8), weight: .medium)
        let padding = InlineCodeLayoutManager.labelPadding
        // The space before it may wrap; the room for the pill's edge is its kerning.
        let result = NSMutableAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: size), .kern: padding])
        let body = NSMutableAttributedString()
        if let image = AnswerCitation.icon(cited[0], size: round(size * 0.86)) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let side = image.size.height
            attachment.bounds = CGRect(x: 0, y: round((font.capHeight - side) / 2), width: image.size.width, height: side)
            body.append(NSAttributedString(attachment: attachment))
            body.append(NSAttributedString(string: "\u{2060}"))
        }
        let nameStart = body.length
        // No break inside the label: it reads as one thing.
        body.append(NSAttributedString(string: AnswerCitation.label(cited).replacingOccurrences(of: " ", with: "\u{00A0}")))
        let first = cited[0].number
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(NookTheme.textSecondary),
            .citationLabel: id,
            .citation: first,
        ]
        if let link = URL(string: "\(MarkdownBlock.citationScheme):\(first)") { attributes[.link] = link }
        body.addAttributes(attributes, range: NSRange(location: 0, length: body.length))
        if nameStart > 0 {
            // A little room between the icon and the name.
            body.addAttribute(.kern, value: round(size * 0.25), range: NSRange(location: nameStart - 1, length: 1))
        }
        body.addAttribute(.kern, value: padding, range: NSRange(location: body.length - 1, length: 1))
        result.append(body)
        return result
    }

    /// `MarkdownBlock.inline` (with its link checks) carried over to AppKit fonts and colors.
    private static func inline(_ text: String, size: CGFloat, weight: NSFont.Weight, color: Color,
                               files: Bool, citations: Bool = false) -> NSMutableAttributedString {
        let source = MarkdownBlock.inline(text, size: size, files: files, citations: citations)
        let result = NSMutableAttributedString()
        var previousCode = false
        var previousLink: URL?
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            let code = intent.contains(.code)
            // A file link starts with the symbol of its kind of file (a React atom for `App.tsx`, braces for `nl.json`).
            if let link = run.link, link != previousLink, files, MarkdownBlock.isFileLink(link),
               let target = FileLink.parse(link.absoluteString) {
                result.append(fileGlyph(target.path, size: size, link: link))
                previousCode = false
            }
            previousLink = run.link
            // Room for the chip's padding on either side of a code span, so it never touches the words around it.
            if code != previousCode, result.length > 0 {
                result.addAttribute(.kern, value: InlineCodeLayoutManager.padding, range: NSRange(location: result.length - 1, length: 1))
            }
            previousCode = code
            var attributes: [NSAttributedString.Key: Any] = [:]
            var font: NSFont
            if let mark = run[CitationMark.self] {
                // A citation: a small raised number, grey like the source chips under the answer.
                font = .systemFont(ofSize: round(size * 0.7), weight: .semibold)
                attributes[.baselineOffset] = round(size * 0.36)
                attributes[.citation] = mark
            } else if code {
                font = .monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
                attributes[.inlineCode] = true
            } else {
                // Semibold rather than bold: bold runs already take the full white, a heavier weight made answers loud.
                font = .systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                // The whole address under the pointer, as a browser shows it, so a link says where it goes before a click.
                if run[CitationMark.self] == nil, MarkdownBlock.isSafeLink(link) { attributes[.toolTip] = link.absoluteString }
            }
            attributes[.font] = font
            // A web link takes the link blue here, a citation keeps its own grey (the view sets no color for links). A link
            // to a file or a commit reads as a neutral chip: white on the code wash, so a
            // reply full of paths stays black and white and blue keeps meaning "goes to the web".
            let linkColor: Color? = {
                guard let link = run.link, run[CitationMark.self] == nil else { return nil }
                return MarkdownBlock.isSafeLink(link) ? NookTheme.blue : NookTheme.paper
            }()
            attributes[.foregroundColor] = NSColor(linkColor ?? run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] ?? color)
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        // A line break inside a paragraph stays a break within it, without the gap between paragraphs.
        result.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The file's symbol (`FileTypeGlyph`) set in the text and opening the same link, centered on the capitals with a
    /// little room before the name. A link to an app on this Mac shows the app's own icon, a little larger.
    private static func fileGlyph(_ path: String, size: CGFloat, link: URL) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: size)
        let image = FileTypeGlyph.appIcon(for: path, size: round(size * 1.1)) ?? FileTypeGlyph.image(for: path, size: round(size * 0.8))
        let attachment = NSTextAttachment()
        attachment.image = image
        let height = image.size.height
        attachment.bounds = CGRect(x: 0, y: round((font.capHeight - height) / 2), width: image.size.width, height: height)
        let glyph = NSMutableAttributedString(attachment: attachment)
        // A word joiner, so a wrapping line never leaves the symbol behind without its name; it carries the room.
        glyph.append(NSAttributedString(string: "\u{2060}"))
        glyph.addAttributes([.link: link, .font: font], range: NSRange(location: 0, length: glyph.length))
        glyph.addAttribute(.kern, value: round(size * 0.2), range: NSRange(location: glyph.length - 1, length: 1))
        return glyph
    }
}

/// An answer's text view that copies its words without the file symbols set before file links (`fileGlyph`), which
/// would paste as a stray object character.
final class ProseTextView: NSTextView {
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2060}", with: "")
    }

    // MARK: Citations

    /// The answer's sources. With them the view follows the pointer, to show what a citation's sources say.
    var citationReferences: [SourceReference] = [] {
        didSet { if oldValue.isEmpty != citationReferences.isEmpty { updateTrackingAreas() } }
    }
    private var citationTracking: NSTrackingArea?
    /// The label under the pointer, and the sentence it backs, lit while it is there.
    private var hoveredLabel: (id: String, range: NSRange)?
    private var litClaim: NSRange?
    private var preview: NSPopover?
    /// The label the preview shows, and whether a click opened it (it then stays until a click elsewhere).
    private var previewLabel: String?
    private var previewPinned = false
    private var pendingShow: DispatchWorkItem?
    private var watch: Timer?
    private var missedChecks = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let citationTracking { removeTrackingArea(citationTracking) }
        citationTracking = nil
        // Only an answer with sources follows the pointer: an agent's long transcript pays nothing.
        guard !citationReferences.isEmpty else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        citationTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !citationReferences.isEmpty else { return }
        setHovered(label(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endCitationHover() }
    }

    /// The sources the citation at `index` names.
    func citedReferences(at index: Int) -> [SourceReference] {
        guard let storage = textStorage, index >= 0, index < storage.length,
              let id = storage.attribute(.citationLabel, at: index, effectiveRange: nil) as? String else { return [] }
        return Self.references(id, in: citationReferences)
    }

    private static func references(_ id: String, in references: [SourceReference]) -> [SourceReference] {
        let numbers = id.split(separator: "|").last.map { $0.split(separator: ",").compactMap { Int($0) } } ?? []
        return AnswerCitation.references(numbers, in: references)
    }

    /// Shows what the sources of the citation at `index` say; `pinned` (after a click) keeps it until a click elsewhere.
    func showCitationPreview(at index: Int, pinned: Bool) {
        guard let storage = textStorage, index >= 0, index < storage.length else { return }
        var range = NSRange()
        guard let id = storage.attribute(.citationLabel, at: index, longestEffectiveRange: &range,
                                         in: NSRange(location: 0, length: storage.length)) as? String else { return }
        showPreview(id: id, range: range, pinned: pinned)
    }

    /// Lets go of a hovered citation and closes its preview: the text is about to change or the view leaves.
    func endCitationHover() {
        pendingShow?.cancel()
        pendingShow = nil
        setHovered(nil, closing: false)
        closePreview()
    }

    /// The citation's label under `point`, if the pointer is on one.
    private func label(at point: NSPoint) -> (id: String, range: NSRange)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inner = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inner, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -InlineCodeLayoutManager.labelPadding, dy: -2).contains(inner) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let id = storage.attribute(.citationLabel, at: index, longestEffectiveRange: &range,
                                         in: NSRange(location: 0, length: storage.length)) as? String else { return nil }
        return (id, range)
    }

    private func setHovered(_ label: (id: String, range: NSRange)?, closing: Bool = true) {
        guard label?.id != hoveredLabel?.id else { return }
        if let litClaim, let layoutManager, NSMaxRange(litClaim) <= (textStorage?.length ?? 0) {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: litClaim)
        }
        litClaim = nil
        hoveredLabel = label
        (layoutManager as? InlineCodeLayoutManager)?.hoveredLabel = label?.id
        pendingShow?.cancel()
        pendingShow = nil
        if let label {
            // The sentence the citation backs lights up, so you see what the source is for.
            let claim = claimRange(before: label.range.location)
            if claim.length > 0 {
                layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(NookTheme.iris).withAlphaComponent(0.16),
                                                     forCharacterRange: claim)
                litClaim = claim
            }
            if previewLabel != label.id {
                // Moving from one label to the next swaps the preview at once; a first hover waits a moment, so passing
                // over a label does not flash one.
                let show = DispatchWorkItem { [weak self] in self?.showPreview(id: label.id, range: label.range, pinned: false) }
                pendingShow = show
                DispatchQueue.main.asyncAfter(deadline: .now() + (preview?.isShown == true ? 0 : 0.25), execute: show)
            }
        }
        needsDisplay = true
    }

    /// From a citation back to the start of its sentence: a line's start, the end of the sentence before it, or the
    /// citation before it in the same sentence.
    private func claimRange(before location: Int) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: location, length: 0) }
        let text = storage.string as NSString
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0xA0 }
        var start = location
        while start > 0 {
            let c = text.character(at: start - 1)
            if c == 0x0A || c == 0x2028 || c == 0x09 { break }
            if storage.attribute(.citationLabel, at: start - 1, effectiveRange: nil) != nil { break }
            if [0x2E, 0x21, 0x3F, 0x3B].contains(c), start < location, isSpace(text.character(at: start)) { break }
            start -= 1
        }
        let skip = CharacterSet.whitespaces.union(.punctuationCharacters)
        while start < location, let scalar = UnicodeScalar(text.character(at: start)), skip.contains(scalar) { start += 1 }
        var end = location
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func showPreview(id: String, range: NSRange, pinned: Bool) {
        guard window != nil, let layoutManager, let textContainer, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let cited = Self.references(id, in: citationReferences)
        guard !cited.isEmpty else { return }
        let claimRange = claimRange(before: range.location)
        let claim = Self.plain((storage.string as NSString).substring(with: claimRange))
        // The label's own box, without the space before it.
        var labelRange = range
        if labelRange.length > 1, (storage.string as NSString).character(at: labelRange.location) == 0x20 {
            labelRange = NSRange(location: labelRange.location + 1, length: labelRange.length - 1)
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: labelRange, actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        anchor.origin.x += textContainerOrigin.x
        anchor.origin.y += textContainerOrigin.y

        let content = NSHostingController(rootView: CitationPreview(references: cited, claim: claim))
        content.sizingOptions = .preferredContentSize
        let popover = preview ?? NSPopover()
        popover.behavior = pinned ? .transient : .applicationDefined
        popover.animates = preview?.isShown != true
        popover.contentViewController = content
        if popover.isShown { popover.positioningRect = anchor } else { popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY) }
        preview = popover
        previewLabel = id
        previewPinned = pinned
        startWatching()
    }

    /// While a hover preview shows, checks the pointer: it closes once the pointer has left both the label and the
    /// preview for a moment, so it can be moved onto the preview to press Open.
    private func startWatching() {
        watch?.invalidate()
        missedChecks = 0
        guard !previewPinned else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
    }

    private func checkPointer() {
        guard let preview, preview.isShown else { closePreview(); return }
        let onPreview = preview.contentViewController?.view.window?.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) ?? false
        if hoveredLabel != nil || onPreview {
            missedChecks = 0
            return
        }
        missedChecks += 1
        if missedChecks >= 2 { closePreview() }
    }

    private func closePreview() {
        watch?.invalidate()
        watch = nil
        if preview?.isShown == true { preview?.performClose(nil) }
        preview = nil
        previewLabel = nil
        previewPinned = false
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
        return pboard.setString(Self.plain(text), forType: .string)
    }
}

extension NSAttributedString.Key {
    /// Marks an inline code span in an answer's text view; `InlineCodeLayoutManager` draws its chip.
    static let inlineCode = NSAttributedString.Key("NookInlineCode")
    /// Marks a citation's raised number with its source's number (0 for the comma between two).
    static let citation = NSAttributedString.Key("NookCitation")
    /// Marks a citation's label (`SelectableProse.withCitationLabels`): "index|2,3", the label's place in the text and
    /// the numbers of its sources. `InlineCodeLayoutManager` draws its pill.
    static let citationLabel = NSAttributedString.Key("NookCitationLabel")
}

/// Draws inline code as a rounded chip that hugs the code's glyphs: as tall as the monospaced font with a little room
/// around it, split per line when a span wraps, and without the trailing space at a line's end.
final class InlineCodeLayoutManager: NSLayoutManager {
    /// Room between the chip's edge and its code, matched by the kerning around the span.
    static let padding: CGFloat = 3
    /// Room between a citation label's pill and its icon and name, matched by the kerning around it.
    static let labelPadding: CGFloat = 5
    private static let fill = NSColor(NookTheme.graphite)
    private static let stroke = NSColor(NookTheme.line2)
    /// The citation label under the pointer (its `citationLabel` value): its pill takes the accent.
    var hoveredLabel: String?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Chips first, so a selection still draws over them.
        drawCodeChips(forGlyphRange: glyphsToShow, at: origin)
        drawCitationLabels(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// A citation's label as a capsule around its icon and name; in the accent while the pointer is on it.
    private func drawCitationLabels(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.citationLabel, in: characters) { value, range, _ in
            guard let id = value as? String, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let hovered = id == hoveredLabel
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                let first = self.location(forGlyphAt: part.location)
                // The last glyph's box takes in the kerning after it: the room on the pill's right.
                let lastBox = self.boundingRect(forGlyphRange: NSRange(location: NSMaxRange(part) - 1, length: 1), in: container)
                let baseline = lineRect.minY + first.y
                let left = lineRect.minX + first.x - Self.labelPadding
                let right = lastBox.maxX
                let top = baseline - font.ascender - 2
                let bottom = baseline - font.descender + 2
                let pill = NSRect(x: left + origin.x, y: top + origin.y, width: max(0, right - left), height: bottom - top)
                let path = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: pill.height / 2, yRadius: pill.height / 2)
                (hovered ? NSColor(NookTheme.iris).withAlphaComponent(0.22) : Self.fill).setFill()
                path.fill()
                (hovered ? NSColor(NookTheme.iris).withAlphaComponent(0.55) : Self.stroke).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func drawCodeChips(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = storage.string as NSString
        storage.enumerateAttribute(.inlineCode, in: characters) { value, range, _ in
            guard value != nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                var part = NSIntersectionRange(glyphs, lineGlyphs)
                // A span that wraps leaves its space at the end of the line: the chip stops at the last glyph.
                while part.length > 0 {
                    let index = self.characterIndexForGlyph(at: NSMaxRange(part) - 1)
                    guard index < text.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: index)) ?? " ") else { break }
                    part.length -= 1
                }
                guard part.length > 0 else { return }
                let first = self.location(forGlyphAt: part.location)
                let lastIndex = NSMaxRange(part) - 1
                let last = self.location(forGlyphAt: lastIndex)
                let lastWidth = font.advancement(forCGGlyph: self.cgGlyph(at: lastIndex)).width
                let baseline = lineRect.minY + first.y
                let left = max(lineRect.minX, lineRect.minX + first.x - Self.padding)
                let right = lineRect.minX + last.x + lastWidth + Self.padding
                let top = baseline - font.ascender - 1.5
                let bottom = baseline - font.descender + 1.5
                let chip = NSRect(x: left + origin.x, y: top + origin.y, width: right - left, height: bottom - top)
                let radius = min(NookTheme.Radius.chip, chip.height / 3)
                let path = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                Self.fill.setFill()
                path.fill()
                Self.stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}
