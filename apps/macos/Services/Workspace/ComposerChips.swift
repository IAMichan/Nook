import Foundation

/// References in your words (a file, a session, a pull request, an excerpt, a skill…) show in the box as chips where they
/// were put, instead of as the Markdown links the draft keeps them as. While the box has the keyboard each link is one
/// object character (`mark`) that the field draws as a chip: you type before and after it, and Backspace or Delete takes
/// the whole reference like a character. Cutting a chip and pasting it elsewhere moves the reference: the field only
/// carries the mark, so the links taken out last are kept as `spares` and given back to marks that come in. While the box
/// rests, each link reads as its short name (`resting`). The draft itself, what is saved, stashed and sent, keeps the links.
enum ComposerChips {
    /// The object replacement character: the field draws its attachment there.
    static let mark: Character = "\u{FFFC}"
    /// How many links taken out are kept for marks that are pasted back.
    static let spareLimit = 8

    /// One character of the box as the field shows it, and the text of the draft it stands for.
    private struct Piece {
        var shown: Character
        var source: String
        var isChip: Bool
    }

    /// The draft as the focused field shows it: every reference one `mark`. A stray mark in the draft is left out, so
    /// the n-th mark always stands for the n-th reference (`ContextRefs.find`).
    static func display(_ text: String) -> String {
        guard text.contains("nook-context:") || text.contains(mark) else { return text }
        return String(pieces(of: text).map(\.shown))
    }

    /// The draft as the field shows it while you type elsewhere: each reference by its short name.
    static func resting(_ text: String) -> String {
        let found = ContextRefs.find(in: text)
        guard !found.isEmpty else { return text }
        var result = text
        for item in found.reversed() { result.replaceSubrange(item.range, with: restingLabel(item.kind, item.label)) }
        return result
    }

    /// A reference by its short name: a file as `@Login.swift`, a pull request as `#12`, a skill as `$name`, the rest by
    /// its label.
    static func restingLabel(_ kind: ContextRef.Kind, _ label: String) -> String {
        switch kind {
        case .file: return "@" + label
        case .pullRequest: return "#" + label
        case .skill: return "$" + label
        case .session, .excerpt, .source, .paste, .model, .secret, .element: return label
        }
    }

    /// Where the marks are in the display text, in UTF-16 offsets (what the field's ranges count), in order.
    static func markOffsets(in display: String) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for unit in display.utf16 {
            if unit == 0xFFFC { offsets.append(offset) }
            offset += 1
        }
        return offsets
    }

    struct Edit: Equatable {
        /// The draft after the edit.
        var text: String
        /// The links the edit took out, in order.
        var removed: [String]
        /// How many of the spares went back in (taken from the end).
        var usedSpares: Int
    }

    /// The draft after the field changed what it shows from `display(old)` to `new`. Marks that stay keep their links;
    /// marks the edit took out take their links along; a mark that came in (a pasted chip) gets the last of `spares`, or
    /// is dropped when there is none. `caret` (UTF-16, after the edit) settles which of two equal neighbours went.
    static func applying(display new: String, to old: String, caret: Int? = nil, spares: [String] = []) -> Edit {
        let before = pieces(of: old)
        let shown = before.map(\.shown)
        let after = Array(new)
        if shown == after { return Edit(text: old, removed: [], usedSpares: 0) }
        let (head, tail) = span(before: shown, after: after, caret: caret, newText: new)
        // The chips in the changed stretch go back, in order, to the marks still in it (one change that typed on both
        // sides of a chip); the rest were taken out.
        var removed = before[head..<(before.count - tail)].filter(\.isChip).map(\.source)
        let incoming = after[head..<(after.count - tail)]
        // Marks beyond the ones that stayed take the newest spares, in the order they were taken out.
        let wanted = max(0, incoming.filter { $0 == mark }.count - removed.count)
        var spares = Array(spares.suffix(wanted))
        var used = 0
        var middle = ""
        for character in incoming {
            if character == mark {
                if !removed.isEmpty {
                    middle += removed.removeFirst()
                } else if !spares.isEmpty {
                    middle += spares.removeFirst()
                    used += 1
                }
            } else {
                middle.append(character)
            }
        }
        let text = before[..<head].map(\.source).joined() + middle + before[(before.count - tail)...].map(\.source).joined()
        return Edit(text: text, removed: removed, usedSpares: used)
    }

    /// How many characters at the start and at the end the edit left alone.
    private static func span(before: [Character], after: [Character], caret: Int?, newText: String) -> (head: Int, tail: Int) {
        // A pure deletion at the caret: trust the caret, so of two equal chips side by side the one you deleted goes.
        if let caret, after.count < before.count, let at = characterIndex(utf16: caret, in: newText) {
            let gone = before.count - after.count
            if at <= after.count, Array(before[..<at]) == Array(after[..<at]),
               Array(before[(at + gone)...]) == Array(after[at...]) {
                return (at, after.count - at)
            }
        }
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head,
              before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        return (head, tail)
    }

    /// The character index a UTF-16 offset falls on, or nil when it splits a character.
    private static func characterIndex(utf16 offset: Int, in text: String) -> Int? {
        var count = 0
        var units = 0
        for character in text {
            if units == offset { return count }
            if units > offset { return nil }
            units += character.utf16.count
            count += 1
        }
        return units == offset ? count : nil
    }

    private static func pieces(of text: String) -> [Piece] {
        let found = ContextRefs.find(in: text)
        var result: [Piece] = []
        result.reserveCapacity(text.count)
        var index = text.startIndex
        var next = 0
        while index < text.endIndex {
            if next < found.count, found[next].range.lowerBound <= index {
                let range = found[next].range
                if range.lowerBound == index {
                    result.append(Piece(shown: mark, source: String(text[range]), isChip: true))
                    index = range.upperBound
                }
                next += 1
                continue
            }
            let character = text[index]
            // A stray mark has no reference behind it: it is not shown, and the next edit drops it.
            if character != mark { result.append(Piece(shown: character, source: String(character), isChip: false)) }
            index = text.index(after: index)
        }
        return result
    }
}
