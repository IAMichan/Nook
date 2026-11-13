import AppKit
import SwiftUI

/// The grey text after the caret in a composer, drawn by autocomplete's own `GhostOverlay`, so it looks and sits exactly like
/// a suggestion of Nook's autocomplete in other apps. Two kinds: the rest of a name typed without `@` (`ComposerInlineName`,
/// Tab makes it a chip) and the rest of the sentence (`ComposerCompleter`, Tab takes a word, ⇧Tab all of it). While it
/// shows, autocomplete stands aside in the field (`AutocompleteController.standAside`): one grey text at a time, and Tab is
/// the composer's.
@MainActor
final class ComposerInlineGhost {
    static let shared = ComposerInlineGhost()

    enum Shown: Equatable {
        case name(ComposerInlineName.Match)
        /// The rest of the sentence, for the draft's words `words` with the caret at `caret` (UTF-16).
        case text(CompletionSuggestion, words: String, caret: Int)

        var remainder: String {
            switch self {
            case .name(let match): return match.remainder
            case .text(let suggestion, _, _): return suggestion.remaining
            }
        }
    }

    private let overlay = GhostOverlay()
    /// What is on screen and the field it was drawn for.
    private(set) var shown: Shown?
    private weak var editor: NSTextView?
    /// A name Escape sent away: it stays away until the typed words change.
    private var dismissed: (typed: String, start: Int)?
    /// The field's text and caret the ghost was drawn for: the caret moving on its own (a click, an arrow) hides it.
    private var drawnFor: (text: String, caret: Int)?

    private init() {
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
            let view = note.object as? NSTextView
            MainActor.assumeIsolated { ComposerInlineGhost.shared.selectionChanged(in: view) }
        }
    }

    /// Typing moves the caret too; that change is the text pipeline's. Only a move over the same text hides the ghost.
    private func selectionChanged(in view: NSTextView?) {
        guard let view, view === editor, let drawnFor, view.string == drawnFor.text else { return }
        let selection = view.selectedRange()
        if selection.length > 0 || selection.location != drawnFor.caret { hide() }
    }

    /// Shows a name after the caret of `editor`, or hides the ghost when there is none (or it was sent away).
    func show(_ match: ComposerInlineName.Match?, in editor: NSTextView?) {
        if let dismissed, match?.typed != dismissed.typed || match?.start != dismissed.start { self.dismissed = nil }
        guard let match, dismissed == nil else { return hide() }
        show(.name(match), in: editor)
    }

    /// Shows `shown` after the caret of `editor`; hides the ghost when it cannot be drawn there.
    func show(_ shown: Shown, in editor: NSTextView?) {
        guard let editor, let window = editor.window, !editor.hasMarkedText() else { return hide() }
        let selection = editor.selectedRange()
        guard selection.length == 0 else { return hide() }
        var actual = NSRange()
        let caret = editor.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: &actual)
        guard caret.height > 1 else { return hide() }
        let visible = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
        let font = editor.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var drawnShown = shown
        let drawn = overlay.showGhost(shown.remainder, at: CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height),
                                      font: font, color: NSColor(NookTheme.textTertiary), limit: visible.maxX - 4)
        guard !drawn.isEmpty else { return hide() }
        // Only what is on screen can be taken: Tab must never put in words you did not see.
        if case .text(_, let words, let at) = shown, drawn.count < shown.remainder.count {
            drawnShown = .text(CompletionSuggestion(drawn), words: words, caret: at)
        }
        self.shown = drawnShown
        self.editor = editor
        drawnFor = (editor.string, selection.location)
        AutocompleteController.shared.standAside(true)
    }

    /// Escape: this name goes until the typed words change; a sentence goes until the next key.
    func dismiss() {
        if case .name(let match) = shown { dismissed = (match.typed, match.start) }
        hide()
    }

    func hide() {
        overlay.hide()
        guard shown != nil else { return }
        shown = nil
        editor = nil
        drawnFor = nil
        AutocompleteController.shared.standAside(false)
    }

    /// What is on screen for this field, if anything.
    func shown(for editor: NSTextView?) -> Shown? {
        guard let shown, let editor, editor === self.editor else { return nil }
        return shown
    }

    /// The name on screen for this field, if any.
    func match(for editor: NSTextView?) -> ComposerInlineName.Match? {
        if case .name(let match) = shown(for: editor) { return match }
        return nil
    }

    /// The sentence on screen, carried over to `words` (the draft's words now): what is left of it when the change put its
    /// beginning in at its caret (typed through, or a word taken with Tab). Nil otherwise.
    func carried(into words: String) -> Shown? {
        guard case .text(let suggestion, let before, let caret) = shown else { return nil }
        let old = before.utf16, new = words.utf16
        guard new.count > old.count, caret <= old.count else { return nil }
        let added = new.count - old.count
        // The words before the caret and after it are the same; something was put in between.
        guard new.prefix(caret).elementsEqual(old.prefix(caret)), new.suffix(old.count - caret).elementsEqual(old.suffix(old.count - caret)),
              let start = String.Index(exactUTF16: caret, in: words), let end = String.Index(exactUTF16: caret + added, in: words),
              let rest = ComposerCompletion.carried(suggestion, inserted: String(words[start..<end])) else { return nil }
        return .text(rest, words: words, caret: caret + added)
    }
}
