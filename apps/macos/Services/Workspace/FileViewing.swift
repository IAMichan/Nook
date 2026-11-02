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

/// A text file opened to edit in Nook's file viewer: its text with `\n` breaks, and how to write it back the way it was
/// (its encoding, a byte order mark, Windows line breaks), so saving one changed line leaves the rest of the file alone.
struct FileEditText: Equatable, Sendable {
    var text: String
    var encoding: String.Encoding = .utf8
    var byteOrderMark = false
    var windowsBreaks = false
    /// When the file was last written, to notice a change on disk (an agent, another editor) before saving over it.
    var modified: Date?
}

enum FileSaveResult: Equatable, Sendable {
    /// Written; the file's new modification date.
    case saved(Date?)
    /// Someone else wrote the file after it was opened: saving would overwrite that.
    case changedOnDisk
    case failed(String)
}

extension FileViewing {
    /// The text of a file to edit; nil for a file that is not text, too large, or not readable.
    static func editable(path: String) -> FileEditText? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), data.count <= largestText else { return nil }
        return editable(data, modified: modificationDate(path))
    }

    static func editable(_ data: Data, modified: Date? = nil) -> FileEditText? {
        var file = FileEditText(text: "", modified: modified)
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let decoded = String(data: data, encoding: .utf16) else { return nil }
            file.encoding = .utf16
            text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        } else {
            if data.prefix(8192).contains(0) { return nil }
            if let decoded = String(data: data, encoding: .utf8) {
                // Foundation may drop the mark while decoding: look at the bytes.
                file.byteOrderMark = data.starts(with: [0xEF, 0xBB, 0xBF])
                text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
            } else if let decoded = String(data: data, encoding: .isoLatin1) {
                file.encoding = .isoLatin1
                text = decoded
            } else {
                return nil
            }
        }
        file.windowsBreaks = text.contains("\r\n")
        file.text = text.replacingOccurrences(of: "\r\n", with: "\n")
        return file
    }

    /// The bytes of `text` written the way `file` was: its line breaks, mark and encoding. Text that no longer fits a
    /// Latin-1 file is written as UTF-8 rather than lost.
    static func encode(_ text: String, as file: FileEditText) -> Data {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        if file.windowsBreaks { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
        if file.byteOrderMark { out = "\u{FEFF}" + out }
        return out.data(using: file.encoding) ?? Data(out.utf8)
    }

    /// Writes the edited text over the file. In place, not through a temporary file, so the file keeps its permissions
    /// (a `.env` readable only by you), its links and its extended attributes. Unless `overwrite`, a file written by
    /// someone else since it was opened is left alone (`changedOnDisk`).
    static func save(_ text: String, as file: FileEditText, to path: String, overwrite: Bool = false) -> FileSaveResult {
        if !overwrite, let opened = file.modified, let now = modificationDate(path), now != opened { return .changedOnDisk }
        do {
            try encode(text, as: file).write(to: URL(fileURLWithPath: path))
            return .saved(modificationDate(path))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
