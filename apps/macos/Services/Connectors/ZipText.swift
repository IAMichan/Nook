import Foundation

/// A zip archive as text, so Nook can read it like any other attached file: the files it holds, then what the readable
/// ones say. The archive is unpacked into a private temporary folder that is removed again before this returns.
enum ZipText {
    /// Why an archive could not be read, in words for the person who attached it.
    enum Failure: LocalizedError, Equatable {
        /// Not a zip archive, or a damaged one.
        case unreadable(String)
        /// Unpacked it would be larger than `maxUnpackedBytes`.
        case tooBig(String)
        /// It holds no files, or none Nook can read.
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return tr("chat.attach.zipUnreadable", name)
            case .tooBig(let name): return tr("chat.attach.zipTooBig", name)
            case .empty(let name): return tr("chat.attach.zipEmpty", name)
            }
        }
    }

    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// The most an archive may hold unpacked: more is refused before anything is written (a zip bomb stays packed).
    static let maxUnpackedBytes: Int64 = 500_000_000
    /// The files listed by name.
    static let listLimit = 500
    /// One file inside is read only when it is smaller than this.
    static let fileLimit = 2_000_000

    /// The archive's files, then the text of each one `readFile` can read, until `limit` characters.
    static func read(_ url: URL, limit: Int = 400_000, readFile: (URL) throws -> String) throws -> String {
        let name = url.lastPathComponent
        guard let unpacked = unpackedSize(url) else { throw Failure.unreadable(name) }
        guard unpacked <= maxUnpackedBytes else { throw Failure.tooBig(name) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-zip-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        // unzip leaves out `../` and makes absolute paths relative, so nothing lands outside the folder.
        guard let result = try? ProcessRunner.run("/usr/bin/unzip", ["-qq", "-o", url.path, "-d", folder.path], timeout: 120),
              !result.timedOut, result.status <= 1 else { throw Failure.unreadable(name) }

        let files = entries(in: folder)
        guard !files.isEmpty else { throw Failure.empty(name) }

        var listed = files.prefix(listLimit).map(\.path).joined(separator: "\n")
        if files.count > listLimit { listed += "\n…" }
        var text = "Zip archive \(name), \(files.count) file\(files.count == 1 ? "" : "s"):\n\(listed)"
        var budget = limit - text.count
        var skipped = 0
        for file in files {
            guard budget > 0 else { skipped += 1; continue }
            guard file.size < fileLimit, !isZip(file.url), let content = try? readFile(file.url),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let part = "\n\n--- \(file.path) ---\n" + content
            let taken = part.count > budget ? String(part.prefix(budget)) + "\n…" : part
            text += taken
            budget -= taken.count
        }
        if skipped > 0 { text += "\n\n(\(skipped) more file\(skipped == 1 ? "" : "s") not read: the archive is too long.)" }
        return text
    }

    /// The files unpacked in `folder`, by their path inside the archive and sorted: no folders, links, macOS metadata
    /// (`__MACOSX`, `.DS_Store`) or hidden files.
    static func entries(in folder: URL) -> [(path: String, url: URL, size: Int)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var found: [(path: String, url: URL, size: Int)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if url.lastPathComponent == "__MACOSX" { walker.skipDescendants(); continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            found.append((String(path.dropFirst(base.count + 1)), url, values.fileSize ?? 0))
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// What the archive holds unpacked, in bytes, as its own directory says; nil when it is no zip archive.
    static func unpackedSize(_ url: URL) -> Int64? {
        // `unzip -Zt`: "3 files, 1234 bytes uncompressed, 567 bytes compressed:  54.1%".
        guard let result = try? ProcessRunner.run("/usr/bin/unzip", ["-Zt", url.path], timeout: 30), !result.timedOut else { return nil }
        // An empty archive prints "Empty zipfile." (with status 1) and has nothing to unpack.
        if result.stdout.contains("Empty zipfile") { return 0 }
        guard result.status == 0 else { return nil }
        let words = result.stdout.split(whereSeparator: { $0.isWhitespace })
        guard let index = words.firstIndex(where: { $0.hasPrefix("uncompressed") }), index > 1 else { return nil }
        return Int64(words[index - 2])
    }
}
