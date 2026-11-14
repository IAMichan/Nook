import Foundation

/// The small text helpers Nook's attention code shares: folding, content words, how alike two texts are, whether a text
/// asks something, and cutting a text to a length with an ellipsis. Each used to be written again where it was needed
/// (the think-along filter, memory, research, search, the agent notices); one copy keeps them the same everywhere.
/// Foundation only; tested in Tests/NookTests/TextKitTests.swift.
enum TextKit {
    // MARK: Folding

    /// Lowercase and without accents, so "Café" matches "cafe" and "Überweisung" matches "uberweisung". Separators stay.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Words

    /// Words that say nothing about what a text is about, in the languages Nook speaks (English, Dutch, German, French, Spanish): the
    /// shared base of every stopword list. A caller with words of its own to drop adds them to this set.
    static let stopwords: Set<String> = [
        // English
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "is", "are",
        "was", "were", "be", "been", "do", "does", "did", "what", "which", "who", "whom", "when", "where", "why", "how",
        "i", "me", "my", "we", "our", "you", "your", "it", "its", "that", "this", "there", "can", "could", "would",
        "should", "have", "has", "had", "find", "show", "tell", "search", "look", "all", "any", "some", "again",
        // Dutch
        "de", "het", "een", "en", "of", "van", "naar", "op", "aan", "voor", "met", "over", "uit", "bij", "is", "zijn",
        "was", "waren", "wat", "welke", "wie", "wanneer", "waar", "waarom", "hoe", "ik", "mij", "mijn", "we", "wij",
        "ons", "onze", "je", "jij", "jouw", "die", "dat", "dit", "er", "kan", "kun", "kunt", "heb", "hebben", "had",
        "zoek", "vind", "laat", "zien", "toon", "nog", "ook", "al", "alle", "iets", "toen", "daar", "hier", "om", "te",
        // German
        "der", "die", "das", "ein", "eine", "und", "oder", "von", "zu", "im", "mit", "uber", "fur", "ist", "sind",
        "war", "wer", "wann", "wo", "warum", "wie", "ich", "mein", "meine", "wir", "du", "dein", "es",
        // French
        "le", "la", "les", "un", "une", "et", "ou", "du", "des", "au", "aux", "avec", "pour", "sur", "est", "sont",
        "que", "qui", "quoi", "quand", "pourquoi", "comment", "je", "mon", "ma", "mes", "nous", "vous", "il", "elle",
        // Spanish
        "el", "los", "las", "uno", "una", "y", "o", "del", "con", "para", "por", "sobre", "es", "son", "fue", "que",
        "quien", "cuando", "donde", "como", "yo", "mi", "mis", "nosotros", "tu", "su",
    ]

    /// A light stem for Dutch, English and German: "afspraken" and "afspraak", "meetings" and "meeting" meet. Short words
    /// are left as they are.
    static func stem(_ word: String) -> String {
        guard word.count > 5 else { return word }
        for suffix in ["ingen", "ing", "en", "es", "er", "s", "e"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// The content words of a text: folded, split on everything that is not a letter or digit, at least `minLength`
    /// characters (numbers at least `minNumberLength`), without `stopwords`, and stemmed when `stem` is on.
    static func tokens(_ text: String, stem: Bool = false, stopwords: Set<String> = [], minLength: Int = 3,
                       minNumberLength: Int? = nil) -> Set<String> {
        var result = Set<String>()
        for raw in fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            let minimum = word.allSatisfy(\.isNumber) ? (minNumberLength ?? minLength) : minLength
            guard word.count >= minimum, !stopwords.contains(word) else { continue }
            result.insert(stem ? Self.stem(word) : word)
        }
        return result
    }

    /// How much two sets of words overlap, 0…1 (Jaccard). Two empty sets are not alike.
    static func overlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// How alike two texts are by their content words, 0…1. Texts without content words are alike only when they are the
    /// same once folded.
    static func similarity(_ a: String, _ b: String, stem: Bool = false, stopwords: Set<String> = [], minLength: Int = 3) -> Double {
        let left = tokens(a, stem: stem, stopwords: stopwords, minLength: minLength)
        let right = tokens(b, stem: stem, stopwords: stopwords, minLength: minLength)
        guard !left.isEmpty, !right.isEmpty else {
            return words(a) == words(b) ? 1 : 0
        }
        return overlap(left, right)
    }

    /// The folded words of a text joined by single spaces: what is compared when a text has no content words.
    private static func words(_ text: String) -> String {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    // MARK: Questions

    /// Whether a text asks something: it holds a question mark ("Kom je morgen?", "¿Vienes?"; a Spanish opening mark and
    /// the full-width one count too).
    static func asksQuestion(_ text: String) -> Bool {
        text.contains { $0 == "?" || $0 == "¿" || $0 == "？" }
    }

    // MARK: Cutting

    /// At most `limit` characters, the ellipsis included, on what it was (no trimming when it fits). `wordBoundary`: cut
    /// at the last space before the limit, without the punctuation left at the end, so no word is broken. A text with no
    /// space in reach is cut where it is.
    static func clip(_ text: String, to limit: Int, wordBoundary: Bool = false) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let head = text.prefix(limit - 1)
        guard wordBoundary else { return String(head) + "…" }
        let word = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}
