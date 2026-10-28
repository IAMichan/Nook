import Foundation

// What Nook's own file viewer shows for a file link: the file's text as lines, with the syntax tokens of each line
// (`SyntaxTokenizer`), or, for a picture, a PDF or another file that is not text, a Quick Look preview. Foundation only,
// so it is tested on its own and runs off the main thread.

enum FileViewContent: Equatable, Sendable {
    /// Text: its lines, and the tokens of each (empty for a language the tokenizer does not know).
    case text(lines: [String], tokens: [[SyntaxToken]])
    /// Not text (a picture, a PDF, an archive …) or too large to read as lines: shown by Quick Look.
    case preview
    /// A folder: shown in Finder instead.
    case folder
    case missing
}

enum FileViewing {
    /// Larger files go to Quick Look: thousands of lines of colored rows would make the panel slow.
    static let largestText = 2 * 1024 * 1024

    /// Files Quick Look shows better than their bytes, whatever they contain.
    static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns",
        "pdf", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "aiff",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf",
        "zip", "gz", "tar", "dmg",
    ]

    static func load(path: String) -> FileViewContent {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return .missing }
        if isFolder.boolValue { return .folder }
        if previewExtensions.contains((path as NSString).pathExtension.lowercased()) { return .preview }
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= largestText, let data = try? Data(contentsOf: url) else { return .preview }
        guard let text = decode(data) else { return .preview }
        let lines = split(text)
        return .text(lines: lines, tokens: tokens(lines, path: path))
    }

    /// The text of a file that holds text: UTF-8 (or UTF-16 with its mark); nil for bytes that are not text.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        // A zero byte in the first part never occurs in text: it is a binary file.
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// The lines as an editor numbers them: a trailing newline does not start an empty last line, and `\r\n` is one break.
    static func split(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// The tokens of every line, a block comment or a multi-line string carried from one line to the next.
    static func tokens(_ lines: [String], path: String) -> [[SyntaxToken]] {
        guard let language = SyntaxLanguage.detect(path: path) else { return Array(repeating: [], count: lines.count) }
        var carry = SyntaxTokenizer.Carry.none
        return lines.map { line in
            let (tokens, next) = SyntaxTokenizer.tokenize(line, language: language, carry: carry)
            carry = next
            return tokens
        }
    }

    /// The line to show first: the link's line, kept inside the file.
    static func clampedLine(_ line: Int?, count: Int) -> Int? {
        guard let line, count > 0 else { return nil }
        return min(max(line, 1), count)
    }
}
