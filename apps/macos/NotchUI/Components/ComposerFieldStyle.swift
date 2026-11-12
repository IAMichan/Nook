import SwiftUI
import AppKit

/// Draws the Markdown in the composer styled while you type (`ComposerMarkdownStyle`): it sets fonts and colors on the
/// text of the field's editor, never its characters, so the binding, the lists (/, @, #, $), big pastes, undo and any
/// text drawn over the field (a ghost suggestion) see the same plain Markdown as before. Every size stays the body size,
/// so the field measures its lines as it always did. While an input method composes (marked text) it waits, and a draft
/// past `ComposerMarkdownStyle.limit` stays plain.
@MainActor
enum ComposerFieldStyle {
    private static let size: CGFloat = 14

    /// Styles the field editor that has the keyboard in the key window, when it edits `text` (the composer's words as the
    /// field shows them, `ComposerChips.display`): the Markdown when `markdown` is on, and the references (`chips`, in
    /// order) as chips on their marks.
    static func restyleFocusedEditor(expecting text: String, chips: [ContextRef] = [], markdown: Bool = true) {
        guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.delegate is NSTextField, editor.string == text else { return }
        restyle(editor, markdown: markdown)
        drawChips(chips, in: editor)
    }

    /// Where the caret of the focused field editor is (UTF-16), for telling which chip a Backspace took.
    static func focusedCaret() -> Int? {
        guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        let selection = editor.selectedRange()
        return selection.length == 0 ? selection.location : nil
    }

    /// While dictating the focused field is read-only; the words come from the microphone. Returns the editor it locked,
    /// to unlock that same one afterwards (another field may have the editor by then, and set it up for itself).
    static func lockFocusedEditor(expecting text: String) -> NSTextView? {
        guard let editor = focusedEditor(expecting: text), editor.isEditable else { return nil }
        editor.isEditable = false
        return editor
    }

    /// The selection (UTF-16) of the focused field editor while it shows `text`; nil when it shows something else.
    static func focusedSelection(expecting text: String) -> NSRange? {
        focusedEditor(expecting: text)?.selectedRange()
    }

    /// Puts the caret at `offset` (UTF-16) once the focused field shows `text`: the field takes a new value after this
    /// update, so this waits for the next turn of the run loop.
    static func placeCaret(_ offset: Int, expecting text: String) {
        DispatchQueue.main.async {
            guard let editor = focusedEditor(expecting: text) else { return }
            editor.setSelectedRange(NSRange(location: min(max(offset, 0), (text as NSString).length), length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }

    /// As `placeCaret`, for a field that is only now getting the keyboard: it tries again for a moment while the field
    /// takes it (and after AppKit's own select-all on focus), and stops trying once the field shows other words.
    static func placeCaretSoon(_ offset: Int, expecting text: String) {
        for delay in [0.0, 0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let editor = focusedEditor(expecting: text) else { return }
                editor.setSelectedRange(NSRange(location: min(max(offset, 0), (text as NSString).length), length: 0))
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
    }

    /// "Reply" on an answer (`AnswerReply`): `answer` as a quote at the top of `draft`, and once the composer has the
    /// keyboard (the caller gives it), the caret on the line under the quote. The same for every session's composer.
    static func reply(to answer: String, in draft: inout String) {
        let placed = AnswerReply.inserting(AnswerReply.quote(answer), into: draft)
        guard placed.text != draft else { return }
        draft = placed.text
        let words = ComposerAttachments.split(placed.text).body
        placeCaretSoon(ComposerChips.displayOffset(draft: min(placed.caret, words.utf16.count), in: words),
                       expecting: ComposerChips.display(words))
    }

    /// The field editor that has the keyboard in the key window, whatever it shows.
    static func focusedFieldEditor() -> NSTextView? {
        guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.delegate is NSTextField else { return nil }
        return editor
    }

    /// The field editor of the composer that has the keyboard, for Tab on a list item.
    static func focusedEditor(expecting text: String) -> NSTextView? {
        guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.string == text else { return nil }
        return editor
    }

    static func restyle(_ editor: NSTextView, markdown: Bool = true) {
        guard markdown, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        let length = storage.length
        let whole = NSRange(location: 0, length: length)
        let base = NSFont.systemFont(ofSize: size)
        let text = NSColor(NookTheme.paper)
        let spans = ComposerMarkdownStyle.spans(storage.string)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.removeAttribute(.strikethroughStyle, range: whole)
        storage.addAttribute(.font, value: base, range: whole)
        storage.addAttribute(.foregroundColor, value: text, range: whole)
        // Larger kinds first, then the inline ones on top, the markers last (so they stay dim inside bold).
        for span in spans.sorted(by: { order($0.kind) < order($1.kind) }) where NSMaxRange(span.range) <= length {
            apply(span, to: storage)
        }
        storage.endEditing()
        // What you type next starts plain; the next pass styles it.
        editor.typingAttributes[.font] = base
        editor.typingAttributes[.foregroundColor] = text
        editor.typingAttributes[.backgroundColor] = nil
    }

    private static func order(_ kind: ComposerMarkdownStyle.Kind) -> Int {
        switch kind {
        case .codeBlock, .quote, .heading: return 0
        case .listMarker, .task: return 1
        case .bold, .strike, .code: return 2
        case .italic: return 3
        case .syntax: return 4
        }
    }

    private static func apply(_ span: ComposerMarkdownStyle.Span, to storage: NSTextStorage) {
        let range = span.range
        switch span.kind {
        case .bold, .heading:
            convert(storage, range) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.paper), range: range)
        case .italic:
            convert(storage, range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        case .strike:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.textSecondary), range: range)
        case .code:
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), range: range)
            storage.addAttribute(.backgroundColor, value: NSColor(NookTheme.graphite), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.textStrong), range: range)
        case .codeBlock:
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.textStrong), range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.textSecondary), range: range)
        case .task(let done):
            storage.addAttribute(.foregroundColor, value: NSColor(done ? NookTheme.mint : NookTheme.textSecondary), range: range)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .semibold), range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.textSecondary), range: range)
        case .syntax:
            storage.addAttribute(.foregroundColor, value: NSColor(NookTheme.textTertiary), range: range)
        }
    }

    /// Changes the font of every run in `range`, so bold inside a heading or italic inside bold keep both.
    private static func convert(_ storage: NSTextStorage, _ range: NSRange, _ change: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: size)
            storage.addAttribute(.font, value: change(font), range: run)
        }
    }

    /// Every mark in the editor becomes the chip of its reference: a picture of its icon and label, with its details
    /// under the pointer. The characters stay; only their look changes. A chip left on a character that is no longer a
    /// mark (typing right after one can carry it along) is cleared first.
    private static func drawChips(_ chips: [ContextRef], in editor: NSTextView) {
        guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        guard !chips.isEmpty || storage.containsAttachments else { return }
        let offsets = ComposerChips.markOffsets(in: storage.string)
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.attachment, range: whole)
        storage.removeAttribute(.toolTip, range: whole)
        if offsets.count == chips.count {
            for (offset, ref) in zip(offsets, chips) where offset < storage.length {
                let range = NSRange(location: offset, length: 1)
                storage.addAttribute(.attachment, value: ComposerChipArt.attachment(ref, bodySize: size), range: range)
                storage.addAttribute(.toolTip, value: ComposerChipArt.details(ref), range: range)
            }
        }
        storage.endEditing()
        editor.typingAttributes[.attachment] = nil
        editor.typingAttributes[.toolTip] = nil
    }
}

/// The references a cut took out of a composer, newest last: a chip pasted back (the field only carries its mark) takes
/// the newest one, so cutting and pasting a chip moves it, also into another composer (`ComposerChips.applying`).
@MainActor
enum ComposerChipSpares {
    private(set) static var links: [String] = []

    static func update(_ edit: ComposerChips.Edit) {
        guard edit.usedSpares > 0 || !edit.removed.isEmpty else { return }
        links.removeLast(min(edit.usedSpares, links.count))
        links = Array((links + edit.removed).suffix(ComposerChips.spareLimit))
    }
}

/// The field editor a dictation made read-only, to give it back afterwards only if the same field still has it.
@MainActor
final class ComposerEditorLock {
    private weak var editor: NSTextView?
    private weak var field: AnyObject?

    func lock(expecting text: String) {
        guard let editor = ComposerFieldStyle.lockFocusedEditor(expecting: text) else { return }
        self.editor = editor
        field = editor.delegate
    }

    func unlock() {
        if let editor, editor.delegate === field { editor.isEditable = true }
        editor = nil
        field = nil
    }
}

/// How a reference looks as a chip in the composer: its kind's icon and its label on a rounded plate, drawn once per
/// kind and label.
@MainActor
enum ComposerChipArt {
    private static var cache: [String: NSImage] = [:]
    private static let height: CGFloat = 18
    private static let longestLabel = 32

    static func attachment(_ ref: ContextRef, bodySize: CGFloat) -> NSTextAttachment {
        let image = self.image(ref)
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centered on the capital letters of the text around it.
        let body = NSFont.systemFont(ofSize: bodySize)
        attachment.bounds = CGRect(x: 0, y: (body.capHeight - height) / 2, width: image.size.width, height: height)
        return attachment
    }

    /// What shows under the pointer: the kind, then the path, the pull request or the name.
    static func details(_ ref: ContextRef) -> String {
        switch ref.kind {
        case .file, .pullRequest, .model: return kindName(ref.kind) + "\n" + ref.id
        case .session, .excerpt, .source, .skill, .paste, .secret: return kindName(ref.kind) + "\n" + ref.label
        }
    }

    static func kindName(_ kind: ContextRef.Kind) -> String {
        switch kind {
        case .file: return tr("compose.chip.file")
        case .session: return tr("compose.chip.session")
        case .pullRequest: return tr("compose.chip.pullRequest")
        case .excerpt: return tr("compose.chip.excerpt")
        case .source: return tr("compose.chip.source")
        case .skill: return tr("compose.chip.skill")
        case .paste: return tr("compose.chip.paste")
        case .model: return tr("compose.chip.model")
        case .secret: return tr("compose.chip.secret")
        }
    }

    /// The same icons the `@`, `#` and `$` lists show for these kinds.
    static func symbol(_ kind: ContextRef.Kind) -> String {
        switch kind {
        case .file: return "doc"
        case .session: return "bubble.left.and.text.bubble.right"
        case .pullRequest: return "number"
        case .excerpt: return "text.alignleft"
        case .source: return "link"
        case .skill: return "wand.and.stars"
        case .paste: return "doc.on.clipboard"
        case .model: return "cpu"
        case .secret: return "key.fill"
        }
    }

    private static func image(_ ref: ContextRef) -> NSImage {
        let label = ref.label.count > longestLabel ? String(ref.label.prefix(longestLabel - 1)) + "…" : ref.label
        let key = ref.kind.rawValue + "|" + label
        if let cached = cache[key] { return cached }
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(NookTheme.textStrong),
        ])
        let symbol = NookIcon.nsImage(symbol(ref.kind))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        let pad = NookTheme.Spacing.sm
        let iconWidth = symbol.map { $0.size.width + NookTheme.Spacing.xs } ?? 0
        let textSize = text.size()
        let size = NSSize(width: ceil(pad + iconWidth + textSize.width + pad), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(NookTheme.graphite).setFill()
            NSBezierPath(roundedRect: rect, xRadius: NookTheme.Radius.chip, yRadius: NookTheme.Radius.chip).fill()
            var x = pad
            if let symbol {
                let box = NSRect(x: x, y: (rect.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
                let tinted = NSImage(size: symbol.size, flipped: false) { area in
                    symbol.draw(in: area)
                    NSColor(NookTheme.textSecondary).set()
                    area.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: box)
                x += iconWidth
            }
            text.draw(at: NSPoint(x: x, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.accessibilityDescription = kindName(ref.kind) + ", " + label
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
