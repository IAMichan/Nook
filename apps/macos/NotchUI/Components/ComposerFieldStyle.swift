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

    /// Styles the field editor that has the keyboard in the key window, when it edits `text` (the composer's words).
    static func restyleFocusedEditor(expecting text: String) {
        guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.delegate is NSTextField, editor.string == text else { return }
        restyle(editor)
    }

    /// The field editor of the composer that has the keyboard, for Tab on a list item.
    static func focusedEditor(expecting text: String) -> NSTextView? {
        guard let editor = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.string == text else { return nil }
        return editor
    }

    static func restyle(_ editor: NSTextView) {
        guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
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
}
