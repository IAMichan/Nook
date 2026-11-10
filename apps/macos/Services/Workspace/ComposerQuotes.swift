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
