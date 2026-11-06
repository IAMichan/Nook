import Foundation

// A session's folder and terminals on the phone, to read. The Mac decides what leaves it: only inside the session's folder,
// no secrets by name, and within the size of one answer. Foundation only, tested on its own.

/// One terminal of a session: its last lines.
struct TerminalDigest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var running: Bool
    var output: String
}

/// One folder, or one file's text.
struct FolderDigest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var name: String
        var isFolder: Bool
        var size: Int?
        var id: String { name }
    }

    /// Relative to the session's folder; empty is the folder itself.
    var path: String
    var entries: [Entry]? = nil
    var text: String? = nil
    /// The file was longer than one answer holds, or is no text.
    var truncated: Bool? = nil
    var binary: Bool? = nil
}

enum CompanionWorkspace {
    static let maxTextBytes = 128 * 1024
    /// What a file may take once it is JSON: tabs and quotes double, and a frame holds 256 KB when sealed.
    static let maxEncodedBytes = 200 * 1024
    static let maxEntries = 500
    static let maxTerminalLines = 200

    /// `.git` and what holds keys by its name: these never go to the phone.
    static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".git" || lower == ".ssh" || lower == ".aws" || lower == ".npmrc" || lower == ".netrc" { return true }
        if lower == ".env" || lower.hasPrefix(".env.") { return !lower.hasSuffix(".example") && !lower.hasSuffix(".sample") }
        if lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") { return true }
        return [".pem", ".key", ".p12", ".pfx", ".keychain"].contains { lower.hasSuffix($0) }
    }

    /// The real path of `relative` in `folder`, or nil when it leaves the folder or passes a secret. Links are followed first,
    /// so one that points out of the folder stays out. `resolve` is the file system's; tests give their own.
    static func path(_ relative: String, in folder: String,
                     resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(".."), !parts.contains(where: isSecret), !relative.hasPrefix("/") else { return nil }
        let root = resolve(folder)
        // A session in ~/.ssh or ~/.aws is all secret, whatever its files are called.
        guard !root.split(separator: "/").map(String.init).contains(where: isSecret) else { return nil }
        let full = resolve(([folder] + parts).joined(separator: "/"))
        guard full == root || full.hasPrefix(root + "/") else { return nil }
        // A link inside the folder can hide a secret's real name.
        guard !full.dropFirst(root.count).split(separator: "/").map(String.init).contains(where: isSecret) else { return nil }
        return full
    }

    /// A file's bytes as an answer.
    static func digest(path: String, data: Data) -> FolderDigest {
        var head = data.prefix(maxTextBytes)
        guard !head.contains(0) else { return FolderDigest(path: path, binary: true) }
        // A cut can fall inside a character of up to four bytes.
        var text = String(data: head, encoding: .utf8)
        for drop in 1...3 where text == nil && data.count > maxTextBytes { text = String(data: head.dropLast(drop), encoding: .utf8) }
        guard var text else { return FolderDigest(path: path, binary: true) }
        var shortened = data.count > maxTextBytes
        while (try? JSONEncoder().encode(text))?.count ?? 0 > maxEncodedBytes, !text.isEmpty {
            text = String(text.prefix(text.count / 2))
            shortened = true
        }
        head = Data()
        return FolderDigest(path: path, text: text, truncated: shortened ? true : nil)
    }

    /// The terminals in one answer: as many as fit, each cut from its top when needed.
    static func fitting(_ terminals: [TerminalDigest]) -> [TerminalDigest] {
        var room = maxEncodedBytes
        return terminals.compactMap { terminal in
            var terminal = terminal
            while (try? JSONEncoder().encode(terminal))?.count ?? 0 > room, !terminal.output.isEmpty {
                terminal.output = String(terminal.output.suffix(terminal.output.count / 2))
            }
            let size = (try? JSONEncoder().encode(terminal))?.count ?? 0
            guard size <= room else { return nil }
            room -= size
            return terminal
        }
    }

    /// A folder's entries: folders first, without secrets, cut at `maxEntries`.
    static func listing(path: String, entries: [FolderDigest.Entry]) -> FolderDigest {
        let shown = entries.filter { !isSecret($0.name) }
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
        return FolderDigest(path: path, entries: Array(shown.prefix(maxEntries)), truncated: shown.count > maxEntries ? true : nil)
    }
}
