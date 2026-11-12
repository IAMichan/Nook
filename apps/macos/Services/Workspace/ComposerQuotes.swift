import Foundation

/// Passages of an answer you picked to go with your next message ("Quote" / "Ask about this" on a selection): chips in
/// the tray above the composer, each removable and each with an optional note of your own, sent as Markdown quotes in
/// front of what you type, every note right under its quote.
struct ComposerQuotes: Equatable, Sendable {
    struct Quote: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        /// What you say about this passage; empty for none.
        var note: String = ""
        /// The timeline event the passage was taken from, so a click on the chip goes back to it; nil when unknown.
        var source: UUID? = nil
        /// The chip's words: your note when there is one, else the start of the passage, on one line.
        var title: String { ComposerQuotes.title(note.isEmpty ? text : note) }
    }

    /// A longer passage is refused: the message should point at a part of the answer, not repeat it.
    static let characterLimit = 4_000
    static let countLimit = 5
    static let titleLength = 48

    private(set) var items: [Quote] = []

    init() {}

    var isEmpty: Bool { items.isEmpty }

    /// Why a passage was not added.
    enum Refusal: Equatable, Sendable { case empty, tooLong, full }

    /// Adds a passage (once: the same words again are not added twice); nil when it is in, else why not.
    @discardableResult
    mutating func add(_ text: String, id: UUID = UUID(), source: UUID? = nil) -> Refusal? {
        let clean = Self.normalize(text)
        guard !clean.isEmpty else { return .empty }
        guard clean.count <= Self.characterLimit else { return .tooLong }
        if items.contains(where: { $0.text == clean }) { return nil }
        guard items.count < Self.countLimit else { return .full }
        items.append(Quote(id: id, text: clean, source: source))
        return nil
    }

    /// Sets (or with an empty text clears) your note on a quote.
    mutating func setNote(_ note: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].note = Self.normalize(String(note.prefix(Self.characterLimit)))
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func removeAll() { items.removeAll() }

    /// The message that goes out: each passage as a Markdown quote, in the order you picked them, your note on it as the
    /// paragraph right under it, then what you typed. So the agent reads which words you quoted and what you said of them.
    func message(_ text: String) -> String {
        guard !items.isEmpty else { return text }
        let quoted = items.map { quote -> String in
            let block = quote.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            return quote.note.isEmpty ? block : block + "\n\n" + quote.note
        }
        return (quoted + [text.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The event a passage was selected from: the newest one whose text holds it. The passage is the rendered text (no
    /// Markdown markers) and may wrap differently, so both sides are compared without markers, case or spacing; its first
    /// words are enough, as a long passage may run across blocks.
    static func source(of passage: String, in entries: [(id: UUID, text: String)]) -> UUID? {
        let needle = String(comparable(passage).prefix(120))
        guard needle.count >= 3 else { return nil }
        return entries.last { comparable($0.text).contains(needle) }?.id
    }

    /// Text as the source lookup compares it: no Markdown markers, folded case and diacritics, one space between words.
    static func comparable(_ text: String) -> String {
        let stripped = text.unicodeScalars.filter { !"*_`#>~|".unicodeScalars.contains($0) }
        return String(String.UnicodeScalarView(stripped))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A selection out of an answer's text view: its line separators become line breaks, its edges are trimmed.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > titleLength else { return words }
        return String(words.prefix(titleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: Replying to an answer

/// "Reply" under an agent's answer: the answer (or the part of it you selected) as a Markdown quote at the top of the
/// session's composer, with the caret under it for what you say about it. A long answer is quoted only so far, enough
/// for the agent to know which answer you mean; it has the whole of it already.
enum AnswerReply {
    /// The most of an answer a reply quotes, in characters, before it is cut with an ellipsis.
    static let characterLimit = 400

    /// What goes to the composer: `selection` when it is a part of `answer`, else the answer itself.
    static func source(answer: String, selection: String?) -> String {
        guard let selection = selection.map(ComposerQuotes.normalize), !selection.isEmpty else { return answer }
        let needle = String(ComposerQuotes.comparable(selection).prefix(120))
        guard needle.count >= 3, ComposerQuotes.comparable(answer).contains(needle) else { return answer }
        return selection
    }

    /// `text` as a Markdown quote: every line behind "> " (an empty one a bare ">"), runs of empty lines kept to one,
    /// cut at `limit` characters on a word with "…". Empty when there is nothing to quote.
    static func quote(_ text: String, limit: Int = characterLimit) -> String {
        var clean = ComposerQuotes.normalize(text)
        guard !clean.isEmpty else { return "" }
        if clean.count > limit {
            var cut = String(clean.prefix(limit))
            // On a word: back to the last space or line break, when that does not lose too much.
            if let space = cut.lastIndex(where: { $0 == " " || $0 == "\n" }), cut.distance(from: space, to: cut.endIndex) <= 40 {
                cut = String(cut[..<space])
            }
            clean = cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        var lines: [String] = []
        for line in clean.components(separatedBy: "\n") {
            var line = line
            while line.last == " " || line.last == "\t" { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if lines.last != ">" { lines.append(">") }
            } else {
                lines.append("> " + line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The draft with `quote` at its top and an empty line under it, and where the caret goes (UTF-16): right after
    /// that line, before what you had written already.
    static func inserting(_ quote: String, into draft: String) -> (text: String, caret: Int) {
        guard !quote.isEmpty else { return (draft, 0) }
        let head = quote + "\n\n"
        let rest = String(draft.drop { $0.isWhitespace })
        return (head + rest, head.utf16.count)
    }

    /// The quote a sent message of yours starts with (its leading "> " lines, markers taken off) and the words after
    /// it, so the message shows the quote as a card above them; nil when it does not start with a quote.
    static func leadingQuote(_ message: String) -> (quote: String, rest: String)? {
        let lines = message.components(separatedBy: "\n")
        var quoted: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].drop { $0 == " " }
            guard line.hasPrefix(">") else { break }
            var body = line.dropFirst()
            if body.first == " " { body = body.dropFirst() }
            quoted.append(String(body))
            index += 1
        }
        let quote = quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        let rest = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (quote, rest)
    }
}
