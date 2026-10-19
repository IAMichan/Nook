import Foundation

/// An answer as it is read aloud: no Markdown, links, code or source numbers, and said sentence by sentence while it is
/// still being written, so Nook starts talking right away. Tested in SpokenTextTests.
enum SpokenText {
    /// The words of a Markdown answer, the way a person would read them out.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        // Code blocks are not read out.
        text = text.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)
        // [title](link) → title; bare links go.
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Source numbers [1], [2].
        text = text.replacingOccurrences(of: #"\s?\[\d+\]"#, with: "", options: .regularExpression)
        // Headings, list marks and quotes at the start of a line; a line of a list ends as a sentence.
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|[-*•]\s+|\d+[.)]\s+|>\s*)"#, with: "", options: .regularExpression)
            guard !line.isEmpty, line.range(of: #"^[|\-: ]+$"#, options: .regularExpression) == nil else { continue }
            if line.hasPrefix("|") {
                // A table row: its cells, separated by commas.
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            if let last = line.last, !".!?:;".contains(last) { line += "." }
            lines.append(line)
        }
        text = lines.joined(separator: " ")
        // Emphasis and inline code marks.
        text = text.replacingOccurrences(of: #"(\*\*|__|\*|_|`|~~)"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hands out the sentences of a growing answer once each is complete, so speech can start before the answer ends.
    struct Queue: Equatable {
        /// Characters of the answer already handed out.
        private(set) var consumed = 0

        /// The complete sentences that came in since the last call. `answer` is the whole answer so far.
        mutating func feed(_ answer: String) -> [String] {
            let characters = Array(answer)
            guard consumed < characters.count else { return [] }
            // The last sentence end that is followed by a space or a new line: what comes after may still grow.
            var end: Int?
            var index = characters.count - 2
            while index >= consumed {
                let character = characters[index]
                let next = characters[index + 1]
                if character == "\n" || (".!?".contains(character) && (next == " " || next == "\n")) {
                    // "3.5" or "Dr. Jansen" is not an end: a digit or a short abbreviation before the dot.
                    if character == ".", index > 0, characters[index - 1].isNumber, next != "\n" { index -= 1; continue }
                    end = index
                    break
                }
                index -= 1
            }
            guard let end else { return [] }
            let piece = String(characters[consumed...end])
            consumed = end + 1
            return Self.sentences(piece)
        }

        /// Whatever is left once the answer is complete.
        mutating func finish(_ answer: String) -> [String] {
            let characters = Array(answer)
            guard consumed < characters.count else { return [] }
            let piece = String(characters[consumed...])
            consumed = characters.count
            return Self.sentences(piece)
        }

        private static func sentences(_ piece: String) -> [String] {
            let spoken = SpokenText.plain(piece)
            return spoken.isEmpty ? [] : [spoken]
        }
    }
}
