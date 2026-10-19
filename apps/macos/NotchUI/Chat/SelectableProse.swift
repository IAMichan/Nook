import SwiftUI
import AppKit

/// Headings, paragraphs, and lists that follow each other in an answer, drawn as one read-only text view so a selection
/// can run across several paragraphs. SwiftUI only selects within a single `Text`, so a drag stopped at every paragraph.
struct SelectableProse: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    var size: CGFloat = 14

    /// Whether a block is plain text that can join a selectable run.
    static func joins(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .list: return true
        default: return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
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
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.linkTextAttributes = [
            .foregroundColor: NSColor(NookTheme.iris),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        let text = Self.attributed(blocks, size: size)
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        // A streaming answer only grows: keep what the user already selected.
        let selection = view.selectedRanges
        storage.setAttributedString(text)
        context.coordinator.measure.setAttributedString(text)
        let kept = selection.filter { NSMaxRange($0.rangeValue) <= text.length }
        view.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        if let storage = view.textStorage, context.coordinator.measure.length != storage.length {
            context.coordinator.measure.setAttributedString(storage)
        }
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let used = context.coordinator.usedSize(width: proposed ?? 10_000)
        return CGSize(width: proposed ?? ceil(used.width), height: ceil(used.height))
    }

    /// Measures on its own layout stack: probing sizes on the text view's container would leave it at a probed width.
    final class Coordinator: NSObject, NSTextViewDelegate {
        let measure = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer()

        override init() {
            super.init()
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            measure.addLayoutManager(layout)
        }

        func usedSize(width: CGFloat) -> CGSize {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).size
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url, MarkdownBlock.isSafeLink(url) { NSWorkspace.shared.open(url) }
            return true
        }
    }

    // MARK: Building the text

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 400
        return cache
    }()

    /// The blocks as one attributed text, in the same sizes, colors, and spacing as the SwiftUI blocks around them.
    static func attributed(_ blocks: [MarkdownBlock], size: CGFloat) -> NSAttributedString {
        let key = "\(size)|\(NookTheme.accentHex)|\(String(describing: blocks))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            // The 10 points the answer's blocks keep between them.
            let gap: CGFloat = index == 0 ? 0 : 10
            switch block {
            case .heading(let level, let text):
                let headingSize = level <= 1 ? size + 5 : level == 2 ? size + 3 : size + 1
                let line = inline(text, size: headingSize, weight: .semibold, color: NookTheme.paper)
                append(line, style: style(before: gap + (level <= 2 ? 6 : 3), lineSpacing: 0), to: result)
            case .paragraph(let text):
                append(inline(text, size: size, weight: .regular, color: NookTheme.paper), style: style(before: gap), to: result)
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    appendItem(item, before: itemIndex == 0 ? gap : 5, size: size, to: result)
                }
            default:
                break
            }
        }
        cache.setObject(result, forKey: key)
        return result
    }

    private static func style(before: CGFloat, lineSpacing: CGFloat = 3) -> NSMutableParagraphStyle {
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
                .font: previous[.font] ?? NSFont.systemFont(ofSize: 13),
                .paragraphStyle: previous[.paragraphStyle] ?? NSParagraphStyle.default,
            ]))
        }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        result.append(paragraph)
    }

    /// A list item: its marker in a column, the text indented past it on every line, nested items further in.
    private static func appendItem(_ item: MarkdownListItem, before: CGFloat, size: CGFloat, to result: NSMutableAttributedString) {
        let indent = CGFloat(item.level) * (size + 4)
        let font = NSFont.systemFont(ofSize: size)
        let line = NSMutableAttributedString()
        let paragraph = style(before: before)
        paragraph.firstLineHeadIndent = indent
        var text = item.text
        var color = item.level == 0 ? NookTheme.paper : NookTheme.textSecondary
        if let task = MarkdownBlock.task(item.text) {
            text = task.text
            color = task.done ? NookTheme.textSecondary : NookTheme.paper
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
                .font: font, .foregroundColor: NSColor(item.level == 0 ? NookTheme.iris : NookTheme.textTertiary),
            ])
            line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            line.append(marker)
            paragraph.tabStops = [NSTextTab(textAlignment: .center, location: indent + 4), NSTextTab(textAlignment: .left, location: indent + 16)]
            paragraph.headIndent = indent + 16
        }
        line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        line.append(inline(text, size: size, weight: .regular, color: color))
        append(line, style: paragraph, to: result)
    }

    private static let bullets = ["•", "◦", "▪"]

    /// `MarkdownBlock.inline` (with its link checks) carried over to AppKit fonts and colors.
    private static func inline(_ text: String, size: CGFloat, weight: NSFont.Weight, color: Color) -> NSMutableAttributedString {
        let source = MarkdownBlock.inline(text, size: size)
        let result = NSMutableAttributedString()
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [:]
            var font: NSFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
                attributes[.backgroundColor] = NSColor(NookTheme.field)
            } else {
                font = .systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            attributes[.foregroundColor] = NSColor(run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] ?? color)
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        // A line break inside a paragraph stays a break within it, without the gap between paragraphs.
        result.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: 0, length: result.length))
        return result
    }
}
