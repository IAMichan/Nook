import Foundation

/// Passages of an answer you picked to go with your next message ("Quote" / "Ask about this" on a selection): chips in
/// the tray above the composer, each removable, sent as Markdown quotes in front of what you type.
struct ComposerQuotes: Equatable, Sendable {
    struct Quote: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        /// The chip's words: the start of the passage on one line.
        var title: String { ComposerQuotes.title(text) }
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
    mutating func add(_ text: String, id: UUID = UUID()) -> Refusal? {
        let clean = Self.normalize(text)
        guard !clean.isEmpty else { return .empty }
        guard clean.count <= Self.characterLimit else { return .tooLong }
        if items.contains(where: { $0.text == clean }) { return nil }
        guard items.count < Self.countLimit else { return .full }
        items.append(Quote(id: id, text: clean))
        return nil
    }

    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    mutating func removeAll() { items.removeAll() }

    /// The message that goes out: each passage as a Markdown quote, in the order you picked them, then what you typed.
    func message(_ text: String) -> String {
        guard !items.isEmpty else { return text }
        let quoted = items.map { quote in quote.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") }
        return (quoted + [text.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "\n\n")
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
