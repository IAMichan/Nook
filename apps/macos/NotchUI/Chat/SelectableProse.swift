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
        let text = ComposerQuotes.normalize((view.string as NSString).substring(with: range))
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
        let view = NSTextView(usingTextLayoutManager: false)
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
        let files = context.environment.fileLinkBase != nil
        let citations = !references.isEmpty
        // The same blocks as last time (a redraw on hover or while scrolling): nothing to build or compare. Comparing the
        // blocks is cheap next to describing them all for the cache key.
        let input = Coordinator.Input(blocks: blocks, size: size, files: files, accent: NookTheme.accentHex,
                                      references: references)
        guard input != context.coordinator.input else { return }
        context.coordinator.input = input
        let text = Self.withCitationHelp(Self.attributed(blocks, size: size, files: files, citations: citations), references)
        // The cache hands back the same text for the same blocks: skip comparing it character by character on every
        // redraw (hover, scrolling, another message streaming in).
        guard text !== context.coordinator.shown else { return }
        guard let storage = view.textStorage, !storage.isEqual(to: text) else {
            context.coordinator.shown = text
            return
        }
        context.coordinator.shown = text
        // A streaming answer only grows: keep what the user already selected.
        let selection = view.selectedRanges
        storage.setAttributedString(text)
        context.coordinator.setMeasured(text)
        let kept = selection.filter { NSMaxRange($0.rangeValue) <= text.length }
        view.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept
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
                let references = references
                Task { @MainActor in AnswerCitation.open(number, in: references) }
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
                if !MainActor.assumeIsolated({ AppModel.shared.openLinkBeside(url) }) { NSWorkspace.shared.open(url) }
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
        MemoryPressure.shared.register("selectableProse") { [cache] _ in cache.removeAllObjects() }
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

    /// The text with a hover on each citation that names its source; the text itself when there is nothing to name.
    static func withCitationHelp(_ text: NSAttributedString, _ references: [SourceReference]) -> NSAttributedString {
        guard !references.isEmpty else { return text }
        var found = false
        text.enumerateAttribute(.citation, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        guard found, let copy = text.mutableCopy() as? NSMutableAttributedString else { return text }
        copy.enumerateAttribute(.citation, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let number = value as? Int, let help = MainActor.assumeIsolated({ AnswerCitation.help(number, in: references) }) else { return }
            copy.addAttribute(.toolTip, value: help, range: range)
        }
        return copy
    }

    /// `MarkdownBlock.inline` (with its link checks) carried over to AppKit fonts and colors.
    private static func inline(_ text: String, size: CGFloat, weight: NSFont.Weight, color: Color,
                               files: Bool, citations: Bool = false) -> NSMutableAttributedString {
        let source = MarkdownBlock.inline(text, size: size, files: files, citations: citations)
        let result = NSMutableAttributedString()
        var previousCode = false
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            let code = intent.contains(.code)
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
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            // A link takes the link blue here, a citation keeps its own grey (the view sets no color for links).
            let linkColor = run.link != nil && run[CitationMark.self] == nil ? NookTheme.blue : nil
            attributes[.foregroundColor] = NSColor(linkColor ?? run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] ?? color)
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        // A line break inside a paragraph stays a break within it, without the gap between paragraphs.
        result.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: 0, length: result.length))
        return result
    }
}

extension NSAttributedString.Key {
    /// Marks an inline code span in an answer's text view; `InlineCodeLayoutManager` draws its chip.
    static let inlineCode = NSAttributedString.Key("NookInlineCode")
    /// Marks a citation's raised number with its source's number (0 for the comma between two).
    static let citation = NSAttributedString.Key("NookCitation")
}

/// Draws inline code as a rounded chip that hugs the code's glyphs: as tall as the monospaced font with a little room
/// around it, split per line when a span wraps, and without the trailing space at a line's end.
final class InlineCodeLayoutManager: NSLayoutManager {
    /// Room between the chip's edge and its code, matched by the kerning around the span.
    static let padding: CGFloat = 3
    private static let fill = NSColor(NookTheme.graphite)
    private static let stroke = NSColor(NookTheme.line2)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Chips first, so a selection still draws over them.
        drawCodeChips(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
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
