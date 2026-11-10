import Foundation

// Dictation in the phone's composers (docs/COMPANION.md, "Dictation"): which of your languages to listen in, and how what
// was said joins what you already typed. Foundation only, so it is tested on the Mac (NookTests).

enum DictationLanguages {
    /// The languages to offer, in your order: each of `preferred` (BCP 47, "nl-NL", "en") matched to one the recognizer
    /// supports (the exact one, else the first with the same language), each once.
    static func offered(preferred: [String], supported: [String]) -> [String] {
        let known = supported.map { normalize($0) }
        var result: [String] = []
        for wanted in preferred.map(normalize) {
            let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
            let match = known.first { $0 == wanted } ?? known.first { $0.split(separator: "-").first.map(String.init) == language }
            if let match, !result.contains(match) { result.append(match) }
        }
        return result
    }

    /// The language to listen in: the one you picked when it is still offered, else your first.
    static func pick(saved: String?, offered: [String]) -> String? {
        if let saved, offered.contains(normalize(saved)) { return normalize(saved) }
        return offered.first
    }

    /// "nl_NL" and "nl-nl" both as "nl-NL".
    static func normalize(_ code: String) -> String {
        let parts = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first else { return code }
        return ([first.lowercased()] + parts.dropFirst().map { $0.count == 2 ? $0.uppercased() : $0 }).joined(separator: "-")
    }
}

enum DictationText {
    /// What the field holds while you speak: what you had typed, then what was heard so far, with one space between them
    /// (none after a line break or before punctuation the recognizer starts with).
    static func merge(base: String, heard: String) -> String {
        let spoken = heard.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        if base.last?.isWhitespace == true || spoken.first.map({ ",.;:!?".contains($0) }) == true { return base + spoken }
        return base + " " + spoken
    }
}
