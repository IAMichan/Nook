import Foundation

/// Web addresses and file paths in a line of terminal output, so ⌘-click can open them:
/// a local address in Nook's browser, any other in your browser, and a path (`src/app.swift:12:3`) in your editor at
/// that line. The patterns are adapted from MIT-licensed code (see THIRD-PARTY-NOTICES.md).
enum TerminalLinks {
    enum Kind: Equatable { case url, path }

    struct Match: Equatable {
        var kind: Kind
        var text: String
        /// Offsets in characters (`Character`), as the terminal counts columns.
        var start: Int
        var end: Int
    }

    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s"'`<>]+"#, options: [.caseInsensitive])
    // A bare path starts only where a segment can start, so long output without separators is not scanned at every suffix.
    private static let path = try! NSRegularExpression(
        pattern: #"(?:~/|\.{1,2}/|/)[^\s"'`<>]+|(?<![\p{L}\p{M}\p{N}._-])[\p{L}\p{M}\p{N}._-]+(?:/[\p{L}\p{M}\p{N}._-]+)+(?::\d+){0,2}"#)
    private static let quotedPath = try! NSRegularExpression(
        pattern: #"(["'`])((?:~/|\.{1,2}/|/|[\p{L}\p{M}\p{N}._ -]+/)[^\r\n]*?|[\p{L}\p{M}\p{N}._ -]+\.[\p{L}\p{M}\p{N}_-]+(?::\d+){0,2})\1((?::\d+){0,2})"#)
    // A question mark may be part of a file name; only request lines with a query are left alone (`GET /api?x=1`).
    private static let requestRoute = try! NSRegularExpression(
        pattern: #"(?:^|[\s"'`])(?:GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|CONNECT|TRACE|proxying)\s+["'`]?(?:/|[A-Za-z0-9_-]+/)[^\s?]*\?\S*"#)

    static func extract(_ line: String) -> [Match] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let routes = requestRoute.matches(in: line, range: full).map { $0.range }
        var found: [(Kind, NSRange, String)] = []

        func collides(_ range: NSRange) -> Bool {
            found.contains { NSIntersectionRange($0.1, range).length > 0 }
        }

        for match in url.matches(in: line, range: full) {
            let text = trimClosing(ns.substring(with: match.range), kind: .url)
            guard !text.isEmpty else { continue }
            let range = NSRange(location: match.range.location, length: (text as NSString).length)
            if !collides(range) { found.append((.url, range, text)) }
        }
        for match in quotedPath.matches(in: line, range: full) {
            let inner = match.range(at: 2)
            let position = match.range(at: 3)
            let positionText = position.location == NSNotFound ? "" : ns.substring(with: position)
            let text = ns.substring(with: inner) + positionText
            guard !text.isEmpty, !isURL(text) else { continue }
            // A position after the quotes also spans the closing quote.
            let length = inner.length + (positionText.isEmpty ? 0 : positionText.utf16.count + 1)
            let range = NSRange(location: inner.location, length: length)
            if !collides(range) { found.append((.path, range, text)) }
        }
        for match in path.matches(in: line, range: full) {
            let text = trimClosing(ns.substring(with: match.range), kind: .path)
            guard !text.isEmpty, !isURL(text) else { continue }
            let range = NSRange(location: match.range.location, length: (text as NSString).length)
            if !collides(range) { found.append((.path, range, text)) }
        }

        return found
            .filter { kind, range, _ in kind == .url || !routes.contains { NSIntersectionRange($0, range).length > 0 } }
            .sorted { $0.1.location < $1.1.location }
            .compactMap { kind, range, text in
                guard let lower = Range(range, in: line) else { return nil }
                let start = line.distance(from: line.startIndex, to: lower.lowerBound)
                let end = line.distance(from: line.startIndex, to: lower.upperBound)
                return Match(kind: kind, text: text, start: start, end: end)
            }
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

    /// Sentence punctuation after a link is not part of it, nor a closing bracket that was never opened. A path also drops
    /// a trailing colon: compilers print `file:line:col:`.
    private static func trimClosing(_ value: String, kind: Kind) -> String {
        var output = value
        let trailing: Set<Character> = kind == .path ? [".", ",", ";", ":", "!", "?"] : [".", ",", ";", "!", "?"]
        while let last = output.last, trailing.contains(last) { output.removeLast() }
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] as [(Character, Character)] {
            while output.last == close {
                let opens = output.filter { $0 == open }.count
                let closes = output.filter { $0 == close }.count
                if opens >= closes { break }
                output.removeLast()
            }
        }
        return output
    }
}
