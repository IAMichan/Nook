import Foundation

/// The stickers and GIFs you sent from Nook, newest first, so the sticker panel offers them again in every chat: a copy
/// of each in Nook's support folder (the original may be a temporary file), at most `limit`. Foundation only.
enum ChatStickers {
    static let limit = 36
    private static let key = "chatStickers.recent"

    static var folder: URL { NookPaths.supportDirectory.appendingPathComponent("ChatStickers", isDirectory: true) }

    /// The ones kept, newest first, that are still there.
    static func recent(defaults: UserDefaults = .standard, in folder: URL = ChatStickers.folder) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Keeps a sticker or GIF you sent: a copy goes first in the list (the same file again moves up), the oldest beyond
    /// `limit` goes from the list and from disk.
    static func remember(_ file: URL, gif: Bool, defaults: UserDefaults = .standard, in folder: URL = ChatStickers.folder) {
        let fm = FileManager.default
        var names = defaults.stringArray(forKey: key) ?? []
        let name: String
        if file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            name = file.lastPathComponent
        } else {
            guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  let data = try? Data(contentsOf: file), data.count <= ChatMedia.maxBytes else { return }
            // The same picture sent again is kept once.
            let known = names.first { (try? Data(contentsOf: folder.appendingPathComponent($0))) == data }
            if let known {
                name = known
            } else {
                let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
                name = (gif ? "gif-" : "sticker-") + UUID().uuidString + "." + ext
                guard (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return }
            }
        }
        names.removeAll { $0 == name }
        names.insert(name, at: 0)
        for old in names.dropFirst(limit) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
        defaults.set(Array(names.prefix(limit)), forKey: key)
    }

    /// Whether a kept file was sent as a GIF rather than a sticker.
    static func isGIF(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("gif-")
    }
}
