import Foundation

/// Tidies the title a shell sets for its terminal (OSC 0/2) before it shows on a tab.
/// zsh and bash default to "user@host:~/path/to/folder"; the panel already shows the folder, so the tab keeps only its name.
enum TerminalTitle {
    static func display(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "user@host:rest" (or "user@host: rest") → "rest".
        if let colon = title.firstIndex(of: ":") {
            let prefix = title[..<colon]
            if prefix.contains("@"), !prefix.contains(where: \.isWhitespace) {
                title = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        // A bare path → its last folder; "~" and "/" stay as they are.
        if title.hasPrefix("/") || title.hasPrefix("~") {
            let trimmed = title.count > 1 && title.hasSuffix("/") ? String(title.dropLast()) : title
            if trimmed == "~" || trimmed == "/" { return trimmed }
            if let last = trimmed.split(separator: "/").last, !last.isEmpty { return String(last) }
        }
        return title.isEmpty ? raw : title
    }
}
