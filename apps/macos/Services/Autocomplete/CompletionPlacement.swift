import Foundation

/// Where suggestions go on screen, from what an app says through Accessibility. Apps answer in many ways and some answers are
/// wrong: a rect in the screen's corner, a whole paragraph, a field as big as the page, a cursor left behind after scrolling.
/// These rules decide which answers to trust, so a suggestion is either right after the typed text or not shown at all.
///
/// All rects are in AppKit screen coordinates (origin bottom left).
enum CompletionPlacement {
    /// The cursor as the app reported it, when it can be believed: about a line high, on a screen, and inside its window and
    /// its field. A cursor much taller than the text (a paragraph with spacing) keeps its bottom, where the text is.
    static func checkedCaret(_ caret: CGRect?, field: CGRect?, window: CGRect?, screens: [CGRect], fontSize: CGFloat?) -> CGRect? {
        guard var caret, caret.height >= 4, caret.height <= 200, caret.minX.isFinite, caret.minY.isFinite else { return nil }
        if let fontSize, fontSize > 0, caret.height > fontSize * 2.6 {
            caret = CGRect(x: caret.minX, y: caret.minY, width: 0, height: (fontSize * 1.25).rounded())
        }
        let point = CGPoint(x: caret.minX, y: caret.midY)
        if !screens.isEmpty, !screens.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) { return nil }
        if let window, !window.insetBy(dx: -4, dy: -4).contains(point) { return nil }
        if let field, !field.insetBy(dx: -4, dy: -4).contains(point) { return nil }
        return caret
    }

    /// The field's frame, when it can be believed: it has a size and lies in its window. Some apps report a field at the
    /// screen's corner or with no size; such a frame would only put cards in the wrong place or turn a good cursor away.
    static func checkedField(_ field: CGRect?, window: CGRect?) -> CGRect? {
        guard let field, field.width > 1, field.height > 1 else { return nil }
        if let window, window.width > 1, window.height > 1, !field.intersects(window) { return nil }
        return field
    }

    /// Where a card or the emoji picker goes: under the cursor, or under the field when it is a single line. A note or a long
    /// message is one tall field, and under (or, without room, above) it is far from where you type: without a cursor there
    /// is no good place, so nothing is shown.
    static func cardAnchor(caret: CGRect?, field: CGRect?, fontSize: CGFloat?) -> CGRect? {
        if let caret { return caret }
        guard let field, field.height <= max(40, (fontSize ?? 13) * 2.8) else { return nil }
        return field
    }

    /// The cursor worked out from where it was at an earlier read of the same field, for apps that only sometimes say where
    /// it is: the text typed since, on the same line, moves it right by its width. Nil when the text went another way (a
    /// letter taken back, a new line, much more typed) or would run past the field's edge (the line wrapped).
    static func carried(from last: CGRect, before lastBefore: String, to before: String, field: CGRect?,
                        width: (String) -> CGFloat) -> CGRect? {
        guard before.hasPrefix(lastBefore) else { return nil }
        let typed = before.dropFirst(lastBefore.count)
        guard typed.count <= 60, !typed.contains(where: \.isNewline) else { return nil }
        let x = last.minX + (typed.isEmpty ? 0 : width(String(typed)))
        if let field, x > field.maxX - 2 { return nil }
        return CGRect(x: x, y: last.minY, width: 0, height: last.height)
    }

    /// After Nook typed `typed` behind `base`, the field shows `actual`: when the app took in only some of its characters (it
    /// reads one character per key event), how many to delete before typing it again one by one. Nil when it all arrived, or
    /// the text changed in another way (autocorrect, smart quotes, the user), which is not Nook's to undo.
    static func droppedCharacters(typed: String, base: String, actual: String) -> Int? {
        guard actual.hasPrefix(base) else { return nil }
        let got = actual.dropFirst(base.count)
        // Nothing at all may still be on its way, or the key went somewhere else: only a part that arrived says enough.
        guard !got.isEmpty, got.count < typed.count else { return nil }
        // Every character that arrived is one of the typed ones, in order: some were lost on the way.
        var rest = Substring(typed)
        for character in got {
            guard let index = rest.firstIndex(of: character) else { return nil }
            rest = rest[rest.index(after: index)...]
        }
        return got.count
    }
}
