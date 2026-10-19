import Foundation

/// How a piece of typed text becomes a prompt for the model, and how the model's answer becomes a suggestion.
enum CompletionText {
    /// How much of what comes before the cursor the model reads, in characters.
    static let contextCharacters = 1_500
    /// A suggestion is at most this many words: short ones are accepted far more often than long ones.
    static let maxWords = 12
    /// Fewer letters than this and there is nothing to continue yet.
    static let minimumCharacters = 3

    /// The text the model continues: the end of what is before the cursor, starting at a word boundary.
    static func prompt(before: String) -> String {
        guard before.count > contextCharacters else { return before }
        let tail = String(before.suffix(contextCharacters))
        guard let space = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) else { return tail }
        return String(tail[tail.index(after: space)...])
    }

    /// Whether to suggest at all: enough typed, and the cursor at the end of its line (text after the cursor would be
    /// pushed aside by an insertion in the middle of a sentence).
    static func shouldSuggest(before: String, after: String) -> Bool {
        let typed = before.filter { !$0.isWhitespace }
        guard typed.count >= minimumCharacters else { return false }
        guard after.allSatisfy({ $0 == " " || $0 == "\t" }) || after.isEmpty else { return false }
        return true
    }

    /// The model's raw answer as a suggestion: one line, no doubled space, a limited number of words, nothing trailing.
    /// Nil when nothing useful is left.
    static func clean(_ raw: String, before: String) -> String? {
        var text = raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: " ")
        if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        text = text.filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
        if before.last?.isWhitespace == true { text = String(text.drop { $0 == " " || $0 == "\t" }) }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        text = limitWords(text)
        let visible = text.filter { !$0.isWhitespace }
        return visible.isEmpty ? nil : text
    }

    private static func limitWords(_ text: String) -> String {
        var words = 0
        var inWord = false
        for index in text.indices {
            if text[index].isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
                if words > maxWords {
                    var cut = String(text[..<index])
                    while let last = cut.last, last.isWhitespace { cut.removeLast() }
                    return cut
                }
            }
        }
        return text
    }
}

/// The key that accepts a suggestion.
enum CompletionAcceptKey: String, CaseIterable, Identifiable {
    case tab, optionTab

    var id: String { rawValue }
    static let tabKeyCode: UInt16 = 48

    var symbol: String { self == .tab ? "⇥" : "⌥⇥" }

    /// `optionDown` and `othersDown` come from the key event's modifier flags.
    func matches(keyCode: UInt16, optionDown: Bool, othersDown: Bool) -> Bool {
        guard keyCode == Self.tabKeyCode, !othersDown else { return false }
        return self == .optionTab ? optionDown : !optionDown
    }
}
