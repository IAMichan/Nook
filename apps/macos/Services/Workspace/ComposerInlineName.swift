import Foundation

/// A name typed straight into the composer, without `@`: from the third letter the rest of a model's name shows as grey text
/// after the caret, and Tab turns what was typed into the same chip the `@` list puts in (t3code's composer does the same).
/// "opu" finds "Claude Opus 4.7", "gpt-6 s" finds "GPT-6 Sol". Commands and `@`, `#`, `$` keep their own lists.
enum ComposerInlineName {
    struct Candidate: Equatable {
        /// The name as people write it ("Claude Opus 4.7").
        var label: String
        /// What Tab puts in its place.
        var ref: ContextRef
    }

    struct Match: Equatable {
        var candidate: Candidate
        /// Where the typed words start in the text before the caret (UTF-16); they run up to the caret.
        var start: Int
        /// What was typed and goes when the chip comes in.
        var typed: String
        /// The grey text after the caret: the rest of the name, or the whole name in brackets when the typed words end it
        /// but did not start it ("opus 4.7" → " (Claude Opus 4.7)").
        var remainder: String

        /// The text with the typed words replaced by the name's chip, the caret right after it: what the `@` list puts in.
        /// Text that no longer holds the typed words where they were is left alone (caret nil).
        func accepting(in text: String) -> (text: String, caret: Int?) {
            let trigger = ComposerTrigger(kind: .mention, query: typed, token: typed,
                                          range: start..<(start + typed.utf16.count))
            return trigger.inserting(ContextRefs.link(candidate.ref), in: text)
        }
    }

    /// Under three letters, ordinary words like "he" or "ma" would keep suggesting names.
    static let minimumLetters = 3
    /// Enough for the longest name anyone types out: "Claude Opus 5.5", "GPT-5.3 Codex Spark".
    static let maximumWords = 4

    /// The name being typed before `caret` (UTF-16 in `text`): the longest run of words that starts a word of a name wins,
    /// then the earliest candidate. Nil while the caret sits inside a word, after a space, or on a command line.
    static func match(in text: String, caret: Int, candidates: [Candidate]) -> Match? {
        guard !candidates.isEmpty else { return nil }
        let utf16 = text.utf16
        guard caret >= 0, caret <= utf16.count else { return nil }
        let caretIndex = utf16.index(utf16.startIndex, offsetBy: caret)
        // Grey text drawn over the rest of a word cannot be read: only at the end of one.
        if caretIndex < text.endIndex, let next = text[caretIndex...].first, !next.isWhitespace { return nil }
        let before = text[..<caretIndex]
        let lineStart = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let line = Array(before[lineStart...])
        guard let last = line.last, !last.isWhitespace, line.first != "/" else { return nil }
        let lineOffset = before[..<lineStart].utf16.count
        for start in runStarts(line) {
            let typed = String(line[start...])
            guard typed.count >= minimumLetters, typed.first?.isLetter == true else { continue }
            let folded = typed.lowercased()
            for candidate in candidates {
                let label = candidate.label
                guard let index = wordMatch(label.lowercased(), folded) else { continue }
                let rest = String(label.dropFirst(index + typed.count))
                let remainder = rest.isEmpty && index > 0 ? " (\(label))" : rest
                // The whole name typed out: nothing left to show, and no shorter run should show it in brackets.
                guard !remainder.isEmpty else { return nil }
                let offset = lineOffset + String(line[..<start]).utf16.count
                return Match(candidate: candidate, start: offset, typed: typed, remainder: remainder)
            }
        }
        return nil
    }

    /// Where each of the last `maximumWords` words before the caret starts, the earliest (longest run) first.
    private static func runStarts(_ line: [Character]) -> [Int] {
        var starts: [Int] = []
        var index = line.count - 1
        while index >= 0, starts.count < maximumWords {
            if !isBoundary(line[index]), index == 0 || isBoundary(line[index - 1]) { starts.append(index) }
            index -= 1
        }
        return starts.reversed()
    }

    /// Where in `label` (both lowercased) a word starts with `typed`, in characters; nil when none does.
    private static func wordMatch(_ label: String, _ typed: String) -> Int? {
        let characters = Array(label), wanted = Array(typed)
        guard wanted.count <= characters.count else { return nil }
        for index in 0...(characters.count - wanted.count) {
            if index > 0, !isLabelBoundary(characters[index - 1]) { continue }
            if Array(characters[index..<(index + wanted.count)]) == wanted { return index }
        }
        return nil
    }

    /// A word in the message starts after a space or an opening bracket or quote; `@`, `#`, `$` and `/` stay attached, so
    /// their own lists keep those words.
    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "([{\"'`".contains(character)
    }

    private static func isLabelBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "-_/".contains(character)
    }

    /// The models the composer can name (`ModelMention`), once each by name: the first agent that offers a name gets it.
    static func candidates(models: [ModelMention.Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard seen.insert(model.name.lowercased()).inserted else { return nil }
            return Candidate(label: model.name, ref: ModelMention.ref(model))
        }
    }
}
