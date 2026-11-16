import Foundation

// Editing a composer that shows its references as chips (`ComposerChips`): where the caret is in the draft, what a copy
// puts on the pasteboard, and undo and redo over the draft itself, so a chip deleted or put in comes back whole.
// Foundation only, so tests can use it independently.

// MARK: Caret

extension ComposerChips {
    /// One stretch of the draft: how many UTF-16 units it takes in the field (`display`) and in the draft.
    private struct Segment {
        var shown: Int
        var source: Int
        var isChip: Bool
    }

    /// The draft in stretches: plain text (the same in both), a reference (one mark in the field), and a stray mark
    /// (nothing in the field, see `display`).
    private static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var cursor = text.startIndex
        func plain(upTo end: String.Index) {
            var run = 0
            for unit in text[cursor..<end].utf16 {
                if unit == 0xFFFC {
                    if run > 0 { result.append(Segment(shown: run, source: run, isChip: false)) }
                    run = 0
                    result.append(Segment(shown: 0, source: 1, isChip: false))
                } else {
                    run += 1
                }
            }
            if run > 0 { result.append(Segment(shown: run, source: run, isChip: false)) }
        }
        for item in ContextRefs.find(in: text) where item.range.lowerBound >= cursor {
            plain(upTo: item.range.lowerBound)
            result.append(Segment(shown: 1, source: text[item.range].utf16.count, isChip: true))
            cursor = item.range.upperBound
        }
        plain(upTo: text.endIndex)
        return result
    }

    /// The place in the draft (UTF-16) of a place in the field (`display(draft)`, UTF-16): before a chip is before its
    /// link, after it after the link.
    static func draftOffset(display offset: Int, in draft: String) -> Int {
        var shown = 0
        var source = 0
        for segment in segments(of: draft) {
            if shown >= offset { return source }
            if shown + segment.shown > offset { return source + (segment.isChip ? 0 : offset - shown) }
            shown += segment.shown
            source += segment.source
        }
        return source
    }

    /// The place in the field of a place in the draft; one inside a link counts as after its chip.
    static func displayOffset(draft offset: Int, in draft: String) -> Int {
        var shown = 0
        var source = 0
        for segment in segments(of: draft) {
            if source + segment.source > offset {
                if segment.isChip { return shown + (offset == source ? 0 : 1) }
                return shown + min(offset - source, segment.shown)
            }
            shown += segment.shown
            source += segment.source
        }
        return shown
    }

    /// A selection in the field as a range of the draft (UTF-16).
    static func draftRange(display range: Range<Int>, in draft: String) -> Range<Int> {
        let lower = draftOffset(display: range.lowerBound, in: draft)
        return lower..<max(lower, draftOffset(display: range.upperBound, in: draft))
    }

    /// The draft's text under a selection in the field: the chips in it as their links.
    static func draftSlice(display range: Range<Int>, in draft: String) -> String {
        let span = draftRange(display: range, in: draft)
        guard let start = String.Index(exactUTF16: span.lowerBound, in: draft),
              let end = String.Index(exactUTF16: span.upperBound, in: draft) else { return "" }
        return String(draft[start..<end])
    }
}

// MARK: Clipboard

/// What a copy of text with chips puts on the pasteboard: for other apps readable Markdown with a link in place of each
/// chip, and for Nook's composers the draft itself (`typeIdentifier`), so a paste there brings the chips back.
enum ComposerClipboard {
    /// The pasteboard type that carries the draft with its `nook-context` links.
    static let typeIdentifier = "nl.imdigital.nook.composer-draft"

    /// The text as Markdown other apps read: each reference a link to what it points at (a file by its path, a pull
    /// request on GitHub, a session by its Nook link), or its name where there is nothing to link to.
    static func readable(_ draft: String) -> String {
        let found = ContextRefs.find(in: draft)
        guard !found.isEmpty else { return draft }
        var result = draft
        for item in found.reversed() {
            result.replaceSubrange(item.range, with: markdown(ContextRef(kind: item.kind, id: item.id, label: item.label)))
        }
        return result
    }

    static func markdown(_ ref: ContextRef) -> String {
        let label = ref.label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        switch ref.kind {
        case .file:
            let path = ref.id.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? ref.id
            return "[\(label)](\(path))"
        case .pullRequest:
            guard let url = pullRequestURL(ref.id) else { return ContextRefs.plainText(ref) }
            return "[#\(label)](\(url))"
        case .session:
            guard let url = SessionLink.build(id: ref.id, title: ref.label) else { return label }
            return "[\(label)](\(url.absoluteString))"
        case .source:
            guard let url = URL(string: ref.id), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return label
            }
            return "[\(label)](\(ref.id))"
        case .skill, .excerpt, .paste, .model, .secret, .element:
            return ContextRefs.plainText(ref)
        }
    }

    private static let pathCharacters: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()")
        return set
    }()

    /// `owner/repo#12` on GitHub.
    private static func pullRequestURL(_ id: String) -> String? {
        let parts = id.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]), number > 0 else { return nil }
        let repo = parts[0].split(separator: "/")
        guard repo.count == 2, repo.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        return "https://github.com/\(repo[0])/\(repo[1])/pull/\(number)"
    }

    /// A paste of `readable` that just landed before `caret` (UTF-16) in `text`, swapped for `draft` (the same text with
    /// its links), with the caret after it. Nil when the text before the caret is not that paste.
    static func restoringChips(in text: String, caret: Int, readable: String, draft: String) -> (text: String, caret: Int)? {
        let length = readable.utf16.count
        guard length > 0, readable != draft, caret >= length,
              let start = String.Index(exactUTF16: caret - length, in: text),
              let end = String.Index(exactUTF16: caret, in: text),
              text[start..<end] == readable else { return nil }
        let head = String(text[..<start]) + draft
        return (head + text[end...], head.utf16.count)
    }
}

// MARK: Undo

/// Undo and redo over the draft as a whole: every change to it (typing, a chip put in or deleted, a paste, dictation)
/// is a step, so undoing a deleted chip brings its reference back. Typing in one place, and deleting one character at a
/// time, coalesce into one step, as in a Mac text field.
struct ComposerUndo: Equatable, Sendable {
    static let limit = 100

    private(set) var undos: [String] = []
    private(set) var redos: [String] = []
    /// The run of typing or deleting the last change belongs to, and where it ends now (UTF-16).
    private var run: (kind: Kind, end: Int)?

    private enum Kind: Equatable, Sendable {
        case typing, deleting
    }

    static func == (lhs: ComposerUndo, rhs: ComposerUndo) -> Bool {
        lhs.undos == rhs.undos && lhs.redos == rhs.redos && lhs.run?.kind == rhs.run?.kind && lhs.run?.end == rhs.run?.end
    }

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }

    /// The draft changed from `old` to `new`. `separate` keeps it out of a run (a chip chosen, a paste, dictation).
    mutating func record(old: String, new: String, separate: Bool = false) {
        guard old != new else { return }
        let change = Self.change(from: old, to: new)
        let kind: Kind?
        if separate {
            kind = nil
        } else if change.removed.isEmpty, change.inserted.count == 1, change.inserted != "\n" {
            kind = .typing
        } else if change.inserted.isEmpty, change.removed.count == 1 {
            kind = .deleting
        } else {
            kind = nil
        }
        redos.removeAll()
        if let kind, let run, run.kind == kind, continues(run, change, kind) {
            self.run = (kind, kind == .typing ? change.start + change.inserted.utf16.count : change.start)
            return
        }
        undos.append(old)
        if undos.count > Self.limit { undos.removeFirst(undos.count - Self.limit) }
        run = kind.map { ($0, $0 == .typing ? change.start + change.inserted.utf16.count : change.start) }
    }

    private func continues(_ run: (kind: Kind, end: Int), _ change: Change, _ kind: Kind) -> Bool {
        switch kind {
        case .typing: return change.start == run.end
        // Backspace ends where the last one started; Delete starts where it did.
        case .deleting: return change.start + change.removed.utf16.count == run.end || change.start == run.end
        }
    }

    /// The caret moved or the box lost the keyboard: the next change starts a step of its own.
    mutating func endRun() { run = nil }

    /// The draft before the last step, and the caret (UTF-16) after what came back. `current` goes to redo.
    mutating func undo(current: String) -> (text: String, caret: Int)? {
        guard let previous = undos.popLast() else { return nil }
        redos.append(current)
        run = nil
        return (previous, Self.caret(from: current, to: previous))
    }

    /// The draft the last undo left, and the caret after what came back. `current` goes back to undo.
    mutating func redo(current: String) -> (text: String, caret: Int)? {
        guard let next = redos.popLast() else { return nil }
        undos.append(current)
        run = nil
        return (next, Self.caret(from: current, to: next))
    }

    private struct Change {
        /// Where the change starts (UTF-16).
        var start: Int
        var removed: String
        var inserted: String
    }

    /// The one stretch that differs between two texts, by characters.
    private static func change(from old: String, to new: String) -> Change {
        let before = Array(old), after = Array(new)
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head,
              before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        let start = String(before[..<head]).utf16.count
        return Change(start: start, removed: String(before[head..<(before.count - tail)]),
                      inserted: String(after[head..<(after.count - tail)]))
    }

    /// After going from `current` to `target`, the caret goes right after the stretch that changed.
    private static func caret(from current: String, to target: String) -> Int {
        let change = change(from: current, to: target)
        return change.start + change.inserted.utf16.count
    }
}
