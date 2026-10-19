import Foundation

// Autocomplete's plain logic: when to suggest, what the model reads, and how its answer is shown and accepted. No AppKit, so
// it is tested on its own (AutocompleteTests). The shape of Suggestion, CompletionPolicy and PromptBuilder follows Typist
// (MIT, © 2026 Brody Salvucci; see THIRD-PARTY-NOTICES.md), which studied how Cotypist behaves.

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
    static func make(raw: String, before: String, after: String = "", maxWords: Int, truncated: Bool = false) -> CompletionSuggestion? {
        var text = Substring(raw.replacingOccurrences(of: "\t", with: " "))
        if let newline = text.firstIndex(where: \.isNewline) { text = text[..<newline] }
        text = Substring(text.filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } })
        if before.last?.isWhitespace ?? true { text = text.drop(while: \.isWhitespace) }

        var parts = chunks(of: text)
        if truncated, parts.count > 1, !(text.last?.isWhitespace ?? false) { parts.removeLast() }
        var result = parts.prefix(max(maxWords, 0)).joined()
        result = overlapTrimmed(result, after: after)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        guard result.contains(where: { !$0.isWhitespace }) else { return nil }
        return CompletionSuggestion(result)
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
    /// What Nook knows about the user (Memory): name, work, people. Cotypist cannot know this.
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
    var windowLength = 3_000
    /// The window's start moves only in steps this big, so consecutive prompts share a prefix and the model's cache is reused:
    /// one more letter costs one token, not a whole prompt.
    var windowStep = 1_000
    var maxContextLength = 1_200
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
        if let screen = cleaned(input.screenText) { sections.append("Visible on screen:\n" + clip(screen, to: maxContextLength)) }
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

    /// - Parameter eagerness: 0 only very sure suggestions … 1 eager.
    init(maxWords: Int = 8, eagerness: Double = 0.5) {
        self.maxWords = maxWords
        maxTokens = max(maxWords * 3, 6)
        let caution = Float(1 - min(max(eagerness, 0), 1))
        minFirstProbability = 0.02 + 0.2 * caution
        minProbability = 0.01 + 0.1 * caution
    }
}

struct CompletionResult: Equatable {
    var text: String
    /// Stopped at the token limit: the last word may be cut off.
    var truncated: Bool
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
