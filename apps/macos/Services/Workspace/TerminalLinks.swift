import Foundation

/// Web addresses and file paths in a line of terminal output, so ⌘-click can open them: a local address in Nook's
/// browser, any other in your browser, and a path (`src/app.swift:12:3`) in your editor at that line.
///
/// The line is read in two passes over its characters. First quoted text that names a file (`"My Folder/read me.txt":4`),
/// which may hold spaces; then every word: an address starting with `http://` or `https://`, or a path (starting at `/`,
/// `./`, `../` or `~/`, or words joined by slashes such as `src/app.swift:12`). Sentence punctuation and closing brackets
/// that were never opened are cut off the end; the path of an HTTP request line with a query (`GET /api?id=3`) is left
/// alone, since it names a route, not a file.
enum TerminalLinks {
    enum Kind: Equatable { case url, path }

    struct Match: Equatable {
        var kind: Kind
        var text: String
        /// Offsets in characters (`Character`), as the terminal counts columns.
        var start: Int
        var end: Int
    }

    private static let quotes: Set<Character> = ["\"", "'", "`"]
    /// Words before a route in a server's request log.
    private static let requestWords: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT",
                                                    "TRACE", "proxying"]

    static func extract(_ line: String) -> [Match] {
        let characters = Array(line)
        var found = quotedPaths(characters)
        var previousWord = ""
        for (start, end) in words(characters) {
            let word = String(characters[start..<end])
            defer { previousWord = word }
            guard let match = link(inWord: characters, start: start, end: end, after: previousWord),
                  !found.contains(where: { $0.start < match.end && match.start < $0.end }) else { continue }
            found.append(match)
        }
        return found.sorted { $0.start < $1.start }
    }

    /// The link under a column, if any.
    static func link(in line: String, at column: Int) -> Match? {
        extract(line).first { $0.start <= column && column < $0.end }
    }

    static func isURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// Whether an address is on this Mac, so it opens in Nook's own browser beside the session.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1" || host == "[::1]"
            || host.hasSuffix(".localhost")
    }

    // MARK: Quoted paths

    /// Text between a pair of the same quotes that reads as a file, with a `:line:column` straight after the closing quote.
    private static func quotedPaths(_ characters: [Character]) -> [Match] {
        var matches: [Match] = []
        var index = 0
        while index < characters.count {
            let quote = characters[index]
            guard quotes.contains(quote),
                  let close = characters[(index + 1)...].firstIndex(of: quote) else { index += 1; continue }
            let inner = String(characters[(index + 1)..<close])
            if looksLikeQuotedFile(inner) {
                let position = positionLength(characters, from: close + 1)
                let suffix = String(characters[(close + 1)..<(close + 1 + position)])
                matches.append(Match(kind: .path, text: inner + suffix, start: index + 1,
                                     end: position > 0 ? close + 1 + position : close))
            }
            index = close + 1
        }
        return matches
    }

    private static func looksLikeQuotedFile(_ text: String) -> Bool {
        guard !text.isEmpty, !isURL(text), !text.contains(where: \.isNewline) else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return true }
        let segments = text.split(separator: "/", omittingEmptySubsequences: false)
        let named = segments.allSatisfy { !$0.isEmpty && $0.allSatisfy { isNameCharacter($0) || $0 == " " } }
        if segments.count > 1 { return named }
        // One name: only a file with an extension ("read me.txt").
        guard named, let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        return text[text.index(after: dot)...].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            && text.index(after: dot) != text.endIndex
    }

    // MARK: Words

    /// Runs of characters between spaces, quotes and angle brackets, as (start, end) offsets.
    private static func words(_ characters: [Character]) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var start: Int?
        for (index, character) in characters.enumerated() {
            let breaks = character.isWhitespace || quotes.contains(character) || character == "<" || character == ">"
            if breaks {
                if let begin = start { result.append((begin, index)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { result.append((begin, characters.count)) }
        return result
    }

    /// The address or path a word holds, trimmed, with its offsets in the line.
    private static func link(inWord characters: [Character], start: Int, end: Int, after previous: String) -> Match? {
        let word = String(characters[start..<end])
        let lower = word.lowercased()
        if let scheme = lower.range(of: "https://") ?? lower.range(of: "http://") {
            let offset = lower.distance(from: lower.startIndex, to: scheme.lowerBound)
            let text = trimmed(String(word.dropFirst(offset)), kind: .url)
            guard text.count > "http://".count else { return nil }
            return Match(kind: .url, text: text, start: start + offset, end: start + offset + text.count)
        }
        // Opening brackets before a path belong to the sentence: "(see src/a.swift)".
        let leading = word.prefix { $0 == "(" || $0 == "[" || $0 == "{" }.count
        let text = trimmed(String(word.dropFirst(leading)), kind: .path)
        guard !text.isEmpty, isPath(text) else { return nil }
        if requestWords.contains(previous), text.contains("?") { return nil }
        return Match(kind: .path, text: text, start: start + leading, end: start + leading + text.count)
    }

    private static func isPath(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") {
            return text.count > 1 && text != "~/"
        }
        // Words joined by slashes, maybe followed by a line and a column.
        let characters = Array(text)
        var end = characters.count
        for _ in 0..<2 {
            guard let colon = characters[..<end].lastIndex(of: ":"), colon + 1 < end,
                  characters[(colon + 1)..<end].allSatisfy(\.isASCII), characters[(colon + 1)..<end].allSatisfy(\.isNumber) else { break }
            end = colon
        }
        let segments = String(characters[..<end]).split(separator: "/", omittingEmptySubsequences: false)
        return segments.count > 1 && segments.allSatisfy { !$0.isEmpty && $0.allSatisfy(isNameCharacter) }
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
    }

    /// The length of a `:line` or `:line:column` starting at `index`, or 0.
    private static func positionLength(_ characters: [Character], from index: Int) -> Int {
        var length = 0
        for _ in 0..<2 {
            let colon = index + length
            guard colon < characters.count, characters[colon] == ":" else { break }
            var digits = colon + 1
            while digits < characters.count, characters[digits].isASCII, characters[digits].isNumber { digits += 1 }
            guard digits > colon + 1 else { break }
            length = digits - index
        }
        return length
    }

    /// Sentence punctuation after a link is not part of it, nor a closing bracket that was never opened. A path also drops
    /// a trailing colon: compilers print `file:line:col:`.
    private static func trimmed(_ value: String, kind: Kind) -> String {
        var output = value
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        let sentence: Set<Character> = kind == .path ? [".", ",", ";", ":", "!", "?"] : [".", ",", ";", "!", "?"]
        while let last = output.last {
            if sentence.contains(last) {
                output.removeLast()
            } else if let open = pairs[last], output.filter({ $0 == open }).count < output.filter({ $0 == last }).count {
                output.removeLast()
            } else {
                break
            }
        }
        return output
    }
}
