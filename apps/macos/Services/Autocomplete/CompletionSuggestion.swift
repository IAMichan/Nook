import Foundation

// Autocomplete's plain logic: when to suggest, what the model reads, and how its answer is shown and accepted. No AppKit, so
// it is tested on its own (AutocompleteTests).

/// A suggestion on screen: the text that would be typed at the cursor. It shrinks as words are accepted or typed through.
struct CompletionSuggestion: Equatable {
    struct AcceptOptions: Equatable {
        /// Taking a word also takes the space after it.
        var trailingSpace = false
        /// Punctuation stuck to a word ("there,") comes with it.
        var attachedPunctuation = true
    }

    private(set) var remaining: String

    init(_ text: String) { remaining = text }

    var isEmpty: Bool { remaining.isEmpty }

    /// The model's answer as a suggestion, or nil when nothing worth showing is left.
    /// - Parameters:
    ///   - before: The text before the cursor (no doubled space after a space).
    ///   - after: The rest of the line after the cursor: a suggestion that runs into it stops where it starts.
    ///   - truncated: The model hit its token limit, so the last word may be cut off; it is dropped unless it is the only one.
    ///   - unfinished: The model stopped in the middle of a word (it was no longer sure how it goes on): that word is always
    ///     dropped, a half word is never shown.
    static func make(raw: String, before: String, after: String = "", maxWords: Int, truncated: Bool = false,
                     unfinished: Bool = false) -> CompletionSuggestion? {
        var text = Substring(raw.replacingOccurrences(of: "\t", with: " "))
        if let newline = text.firstIndex(where: \.isNewline) { text = text[..<newline] }
        text = Substring(text.filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } })
        if before.last?.isWhitespace ?? true { text = text.drop(while: \.isWhitespace) }

        var parts = chunks(of: text)
        if unfinished, !(text.last?.isWhitespace ?? false), !parts.isEmpty { parts.removeLast() }
        else if truncated, parts.count > 1, !(text.last?.isWhitespace ?? false) { parts.removeLast() }
        var result = parts.prefix(max(maxWords, 0)).joined()
        result = overlapTrimmed(result, after: after)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        guard result.contains(where: { !$0.isWhitespace }), !repeats(result, before: before) else { return nil }
        return CompletionSuggestion(result)
    }

    /// A model that is lost tends to copy what was just written. Three words or more that already stand in the last lines
    /// before the cursor are not a suggestion.
    static func repeats(_ text: String, before: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return false }
        return before.suffix(300).range(of: words.joined(separator: " "), options: .caseInsensitive) != nil
    }

    /// Mid-line: when the suggestion runs into the words already after the cursor, keep only what comes before them.
    static func overlapTrimmed(_ text: String, after: String) -> String {
        let rest = after.trimmingCharacters(in: .whitespaces)
        guard rest.count >= 2 else { return text }
        var index = text.startIndex
        while index < text.endIndex {
            let startsWord = !text[index].isWhitespace && (index == text.startIndex || text[text.index(before: index)].isWhitespace)
            if startsWord {
                let tail = String(text[index...]).trimmingCharacters(in: .whitespaces)
                if tail.count >= 2, rest.range(of: tail, options: [.anchored, .caseInsensitive]) != nil
                    || tail.range(of: rest, options: [.anchored, .caseInsensitive]) != nil {
                    return String(text[..<index])
                }
            }
            index = text.index(after: index)
        }
        return text
    }

    /// The next word with the whitespace before it.
    func nextChunk(_ options: AcceptOptions = AcceptOptions()) -> String {
        guard var chunk = Self.chunks(of: Substring(remaining)).first else { return "" }
        if !options.attachedPunctuation {
            let word = chunk.drop(while: \.isWhitespace)
            if let first = word.firstIndex(where: { $0.isLetter || $0.isNumber }) {
                if let end = word[first...].firstIndex(where: { !($0.isLetter || $0.isNumber || "'’-".contains($0)) }) { chunk = chunk[..<end] }
            } else if let first = word.indices.first {
                chunk = chunk[...first]
            }
        }
        var result = String(chunk)
        if options.trailingSpace, remaining.dropFirst(result.count).first == " " { result += " " }
        return result
    }

    mutating func acceptNextChunk(_ options: AcceptOptions = AcceptOptions()) -> String {
        let chunk = nextChunk(options)
        remaining.removeFirst(chunk.count)
        return chunk
    }

    mutating func acceptAll() -> String {
        defer { remaining = "" }
        return remaining
    }

    /// The user typed `typed` themselves: if it is how the suggestion goes on, the suggestion stays (typing through).
    mutating func consume(typed: String) -> Bool {
        guard !typed.isEmpty, remaining.hasPrefix(typed) else { return false }
        remaining.removeFirst(typed.count)
        return true
    }

    /// `whitespace* non-whitespace+` pieces; trailing whitespace is dropped.
    static func chunks(of text: Substring) -> [Substring] {
        var result: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            result.append(text[start..<index])
        }
        return result
    }
}

extension String {
    var completionWordCount: Int { split(whereSeparator: \.isWhitespace).count }
}

/// Whether to ask the model at all for this cursor position.
struct CompletionPolicy: Equatable {
    /// Letters (not spaces) before the cursor.
    var minimumContext = 3
    /// Also with text after the cursor on the same line.
    var midLine = false

    func shouldComplete(before: String, after: String, hasSelection: Bool) -> Bool {
        if hasSelection { return false }
        guard before.lazy.filter({ !$0.isWhitespace }).prefix(minimumContext).count >= minimumContext else { return false }
        if midLine { return true }
        return after.prefix { !$0.isNewline }.allSatisfy(\.isWhitespace)
    }
}

/// Everything that can shape a completion.
struct CompletionContext {
    var before: String
    /// The user's own instructions: general, for this app and for this website.
    var instructions: [String] = []
    /// What Nook knows about the user (Memory): name, work, people.
    var facts: [String] = []
    /// Earlier writing of the user, for their style.
    var samples: [String] = []
    var appName: String?
    var windowTitle: String?
    /// Placeholder of the field ("Write a reply…").
    var fieldHint: String?
    var site: String?
    /// The text of the window around the field (Nook's screen reading).
    var screenText: String?
    var clipboard: String?
}

/// Lays out what the model reads. Base models continue documents, so this is a document: a short header about the author
/// and the situation, then the text before the cursor.
struct PromptBuilder {
    /// Characters of text before the cursor that are kept.
    var windowLength = 2_000
    /// The window's start moves only in steps this big, so consecutive prompts share a prefix and the model's cache is reused:
    /// one more letter costs one token, not a whole prompt.
    var windowStep = 500
    var maxContextLength = 1_600
    var maxSampleLength = 400

    func build(_ input: CompletionContext) -> String {
        var sections: [String] = []
        let instructions = input.instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !instructions.isEmpty { sections.append("About the author:\n" + instructions.joined(separator: "\n")) }
        let facts = input.facts.compactMap(cleaned)
        if !facts.isEmpty { sections.append("Facts about the author:\n" + facts.map { "- " + clip($0, to: 160) }.joined(separator: "\n")) }
        if !input.samples.isEmpty {
            let samples = input.samples.map { "- " + clip($0, to: maxSampleLength).replacingOccurrences(of: "\n", with: " ") }
            sections.append("Earlier writing by the author:\n" + samples.joined(separator: "\n"))
        }
        // The end of the screen text: what is closest to the field and newest (the last messages in a chat).
        if let screen = cleaned(input.screenText) {
            sections.append("On screen, around where the author writes (newest last):\n" + CompletionScreenText.recent(screen, limit: maxContextLength))
        }
        if let clipboard = cleaned(input.clipboard) { sections.append("Clipboard:\n" + clip(clipboard, to: maxContextLength / 2)) }
        var place: [String] = []
        if let app = cleaned(input.appName) { place.append(app) }
        if let site = cleaned(input.site) { place.append(site) }
        if let title = cleaned(input.windowTitle), title != input.appName { place.append(clip(title, to: 120)) }
        if let hint = cleaned(input.fieldHint) { place.append("“" + clip(hint, to: 80) + "”") }
        if !place.isEmpty { sections.append("The author is now writing in " + place.joined(separator: " — ") + ":") }

        // A trailing space makes the model start in the middle of a token; drop it and the suggestion's leading space later.
        var body = window(of: input.before)
        while body.last == " " || body.last == "\t" { body.removeLast() }
        return sections.isEmpty ? body : sections.joined(separator: "\n\n") + "\n\n" + body
    }

    /// The end of `text`, at most `windowLength + windowStep` long, starting at a multiple of `windowStep`.
    func window(of text: String) -> String {
        let count = text.count
        guard count > windowLength else { return text }
        return String(text.dropFirst(((count - windowLength) / windowStep) * windowStep))
    }

    private func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func clip(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}

enum CompletionTextAnalysis {
    /// The word just finished: letters followed by one separator at the end. Names, acronyms and words with digits are
    /// skipped, spell checkers misjudge those.
    static func justCompletedWord(in text: String) -> (word: String, separator: Character)? {
        guard let separator = text.last, separator == " " || ",.!?;:".contains(separator) else { return nil }
        var word = ""
        for character in text.dropLast().reversed() {
            if character.isLetter || character == "'" || character == "’" { word.append(character) }
            else if character.isWhitespace || "(\"“".contains(character) { break }
            else { return nil }
        }
        word = String(word.reversed())
        guard word.count >= 3, word.dropFirst().allSatisfy(\.isLowercase) else { return nil }
        return (word, separator)
    }

    /// The last whole word before the cursor that is worth checking for a typo, and the text after it: the separator just
    /// typed ("gedaam "), punctuation and a space ("gedaam, "), or that and the start of the next word ("gedaam en"). So a
    /// fix is still offered while the next word is being typed, instead of only in the moment between the two.
    static func recentlyFinishedWord(in text: String) -> (word: String, tail: String)? {
        let partial = text.reversed().prefix { $0.isLetter }.count
        guard partial > 0 else { return finishedWord(endingAt: text) }
        let head = String(text.dropLast(partial))
        guard partial <= 20, head.last == " ", let found = finishedWord(endingAt: head) else { return nil }
        return (found.word, found.tail + String(text.suffix(partial)))
    }

    /// A word followed by one separator, or by punctuation and a space.
    private static func finishedWord(endingAt text: String) -> (word: String, tail: String)? {
        if let (word, separator) = justCompletedWord(in: text) { return (word, String(separator)) }
        guard text.last == " ", let mark = text.dropLast().last, ",.!?;:".contains(mark),
              let found = justCompletedWord(in: String(text.dropLast())) else { return nil }
        return (found.word, String(mark) + " ")
    }

    /// Whether a spell checker's guess is a believable fix for `word`: one word, and at most one change for a short word or two
    /// for a longer one (a letter added, left out, replaced, or two swapped). Guesses further away change what was meant.
    static func isLikelyFix(_ candidate: String, for word: String) -> Bool {
        guard !candidate.isEmpty, candidate != word, candidate.allSatisfy({ $0.isLetter || "'’-".contains($0) }) else { return false }
        return editDistance(candidate.lowercased(), word.lowercased()) <= (word.count <= 4 ? 1 : 2)
    }

    /// Damerau–Levenshtein distance (optimal string alignment): swapping two neighbouring letters counts as one change.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1) }
            }
        }
        return table[a.count][b.count]
    }

    /// A selection worth offering other words for: one word, no line breaks.
    static func isSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (2...30).contains(trimmed.count) && trimmed.allSatisfy { $0.isLetter || "'’-".contains($0) }
    }
}

/// How much the model may suggest and how sure it must be.
struct CompletionOptions: Equatable {
    var maxWords: Int
    var maxTokens: Int
    /// Show nothing when the model is less sure than this of the first token: a wrong suggestion costs more than none.
    var minFirstProbability: Float
    /// Stop the suggestion where the model's certainty drops below this.
    var minProbability: Float
    /// How sure the model must stay of the suggestion as a whole (the product of its tokens' probabilities): a suggestion
    /// ends where it drifts off, so long ones do not wander away from what you mean.
    var minSequenceProbability: Float
    /// The cursor is in the middle of a word: the engine reads the prompt without it and lets the model write it out again
    /// (token healing), so the word is not split into odd tokens that make the model guess wildly.
    var heal = false

    /// - Parameter eagerness: 0 only very sure suggestions … 1 eager.
    init(maxWords: Int = 8, eagerness: Double = 0.5) {
        self.maxWords = maxWords
        maxTokens = max(maxWords * 3, 6)
        let caution = Float(1 - min(max(eagerness, 0), 1))
        minFirstProbability = 0.05 + 0.3 * caution
        minProbability = 0.02 + 0.13 * caution
        minSequenceProbability = 0.01 + 0.09 * caution
    }

    /// For the suggestion after one that was taken whole. Every suggestion ends where the model got unsure, so the next one
    /// starts at an unsure point: with the usual bar the chain stopped after two or three suggestions. The user is writing
    /// along with the model, so it may go on with less certainty.
    func continuing() -> CompletionOptions {
        var options = self
        options.minFirstProbability *= 0.4
        options.minProbability *= 0.6
        options.minSequenceProbability *= 0.4
        return options
    }
}

struct CompletionResult: Equatable {
    var text: String
    /// Stopped at the token limit: the last word may be cut off.
    var truncated: Bool
    /// Stopped in the middle of a word because the model was no longer sure.
    var unfinished = false
}

/// Token healing: the end of a prompt that stops in the middle of a word is taken off and written again by the model. A word
/// cut off by the cursor ("morg") tokenizes unlike any text the model learned from; read without it, the model chooses
/// among the tokens that spell it ("morgen", "morgens") and goes on from a whole word.
enum CompletionHealing {
    /// The longest piece of word that is healed.
    static let maxLength = 24

    /// The prompt without the word the cursor is in, and that word with the spaces before it (empty when the prompt ends
    /// with a space or punctuation, or the word is all there is).
    static func split(_ prompt: String) -> (stem: String, pending: String) {
        var word = prompt.endIndex
        while word > prompt.startIndex {
            let previous = prompt.index(before: word)
            let character = prompt[previous]
            guard character.isLetter || character.isNumber || character == "'" || character == "’" else { break }
            word = previous
        }
        guard word < prompt.endIndex, prompt.distance(from: word, to: prompt.endIndex) <= maxLength else { return (prompt, "") }
        var start = word
        while start > prompt.startIndex, prompt[prompt.index(before: start)] == " " { start = prompt.index(before: start) }
        guard start > prompt.startIndex else { return (prompt, "") }
        return (String(prompt[..<start]), String(prompt[start...]))
    }

    /// Whether a token's bytes fit what still has to be written: it spells the start of it, or all of it and more.
    static func fits(_ piece: [UInt8], _ required: [UInt8]) -> Bool {
        guard !piece.isEmpty else { return false }
        return piece.count >= required.count ? piece.starts(with: required) : required.starts(with: piece)
    }

    /// Whether `text` goes on with the word before it (a letter, digit or apostrophe first), so stopping before it would
    /// leave half a word.
    static func continuesWord(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isLetter || first.isNumber || "'’".contains(first)
    }
}

/// The text of the window around the field, for the prompt.
enum CompletionScreenText {
    /// Only the lines that read as text (a message, a paragraph), not the buttons, labels and menus around them: those make
    /// the model write like a user interface. Short chat messages stay when they read as a sentence ("Kom je morgen?",
    /// "Ja, prima."): a reply depends on them most.
    static func prose(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isProse)
            .joined(separator: "\n")
    }

    static func isProse(_ line: String) -> Bool {
        let words = line.completionWordCount
        if words >= 4 { return true }
        guard let last = line.last, words >= 2 || last == "?" else { return false }
        return ".?!".contains(last)
    }

    /// The last whole lines of `text` within `limit` characters (a line longer than that is cut from the front).
    static func recent(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var kept: [Substring] = []
        var length = 0
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if length + line.count + 1 > limit { break }
            kept.append(line)
            length += line.count + 1
        }
        if kept.isEmpty { return "…" + String(text.suffix(limit)) }
        return "…\n" + kept.reversed().joined(separator: "\n")
    }
}

/// Curly quotes, as macOS's "Use smart quotes and dashes" setting would give: text Nook types itself skips the app's own
/// substitution, so it does it here.
enum CompletionTypography {
    /// - Parameter previous: the character before the text (decides whether a quote opens or closes).
    static func smartQuotes(_ text: String, after previous: Character?) -> String {
        let characters = Array(text)
        var result = ""
        var last = previous
        for (index, character) in characters.enumerated() {
            let opens = last == nil || last!.isWhitespace || "([{“‘".contains(last!)
            switch character {
            case "\"": result.append(opens ? "“" : "”")
            case "'":
                // Dutch 's, 't, 'n, 'k ("'s avonds") take an apostrophe, not an opening quote.
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let after = index + 2 < characters.count ? characters[index + 2] : nil
                let elision = next.map { "stnk".contains($0) } == true && !(after?.isLetter ?? false)
                result.append(opens && !elision ? "‘" : "’")
            default: result.append(character)
            }
            last = result.last
        }
        return result
    }
}

enum CompletionStreaming {
    /// Words in `text` that are finished: all of them when it ends in a space or punctuation, otherwise all but the last
    /// (the model may still be writing it).
    static func finishedWords(_ text: String) -> Int {
        let words = text.completionWordCount
        guard let last = text.last else { return 0 }
        if last.isWhitespace || ".,!?;:".contains(last) { return words }
        return max(0, words - 1)
    }
}
