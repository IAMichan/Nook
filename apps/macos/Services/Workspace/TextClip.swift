import Foundation

/// Shortening and flattening text for one line of a list, a title or a step, the same way everywhere.
enum TextClip {
    /// The text on one line (line breaks become spaces), trimmed, cut at `limit` characters with "…".
    static func oneLine(_ text: String, _ limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return cut(single, limit)
    }

    /// Only the first line of the text, trimmed, cut at `limit` characters (the "…" included).
    static func firstLine(_ text: String, _ limit: Int) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// The text trimmed, and when longer than `limit` characters cut to that many (the "…" included).
    static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    /// `text` cut at `limit` characters with "…" after it; the text itself when it fits.
    static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// A title: the text on one line, cut after the last whole word that fits in `limit` characters, with "…". A single
    /// word longer than the limit is cut inside it.
    static func title(_ text: String, _ limit: Int) -> String {
        let single = text.components(separatedBy: .newlines).joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard single.count > limit else { return single }
        let head = single.prefix(limit)
        // The limit falls right after a word.
        if single[head.endIndex] == " " { return String(head) + "…" }
        // Cut at the last space, unless that would leave less than half the room filled.
        if let space = head.lastIndex(of: " "), single.distance(from: single.startIndex, to: space) >= limit / 2 {
            var kept = Substring(single[..<space])
            // "Fix the bug, then" reads "Fix the bug…", not "Fix the bug,…".
            while let last = kept.last, last == "," || last == ";" || last == ":" || last == " " || last == "-" { kept = kept.dropLast() }
            return String(kept) + "…"
        }
        return String(head) + "…"
    }

    /// The text of a message's content: a string, or the `text` of each of its parts (Gemini CLI writes both shapes),
    /// trimmed.
    static func parts(_ content: Any?) -> String {
        if let string = content as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// The text of a Claude Code (and Codex, Cursor) message's content: a string, or its `text` blocks, untrimmed.
    static func blocks(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
}
