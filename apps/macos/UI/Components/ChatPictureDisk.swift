import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The small pictures chat bubbles draw (a photo at a bubble's size, a video's frame, a document's first page), kept on
/// disk as well as in memory, the same for every chat app. Decoding a 12-megapixel HEIC or pulling a frame out of a
/// video takes far longer than reading a small JPEG of it back: after a restart, or once memory pressure emptied the
/// memory caches, a chat full of photos and videos shows them at once instead of making each again.
///
/// Each picture is filed under its file's path, size and modification date and the variant asked for, so a file that
/// changed (still coming in, replaced) is never shown with an old picture. Kept in Nook's caches, so macOS may clear
/// them; trimmed to `limit` once per launch, the least recently written first.
enum ChatPictureDisk {
    /// How much the pictures may take on disk.
    static let limit = 300 * 1024 * 1024
    /// Files smaller than this decode about as quickly as their picture is read back: not stored.
    static let smallest = 96 * 1024

    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nook/ChatPictures", isDirectory: true)
    }

    /// The name of `url`'s picture in `variant`, nil when the file is not there (or too small to be worth it, unless
    /// `always`: a video's frame is worth keeping however small the video is).
    static func key(_ url: URL, variant: String, always: Bool = false) -> String? {
        guard url.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, always || size >= smallest else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // FNV-1a: the same name for the same file on every launch (`hashValue` changes per launch).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(url.path)|\(size)|\(Int(modified * 1000))|\(variant)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key) }

    /// The picture stored under `key`, decoded now (off the main thread, where every caller asks), or nil.
    static func image(_ key: String) -> NSImage? {
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file(key) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Keeps `image` under `key`, in the background: a JPEG, or a PNG where it is see-through (a sticker).
    static func store(_ image: NSImage, key: String, seconds: Double? = nil) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        queue.async {
            trimOnce()
            let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
            let type = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
            let target = file(key)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = target.appendingPathExtension("part")
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else { return }
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: temporary)
            if let seconds, seconds.isFinite {
                try? Data(String(seconds).utf8).write(to: target.appendingPathExtension("seconds"), options: .atomic)
            }
        }
    }

    /// How long the video whose frame is under `key` lasts, when that was stored with it.
    static func seconds(_ key: String) -> Double? {
        (try? String(contentsOf: file(key).appendingPathExtension("seconds"), encoding: .utf8)).flatMap(Double.init)
    }

    /// Writes one picture at a time, at low priority: storing never competes with showing.
    private static let queue = DispatchQueue(label: "nl.imdigital.nook.chat-pictures", qos: .utility)

    /// Trims the folder to `limit` a while after the first picture of this launch is stored, the oldest first. Runs on
    /// `queue` only, so `trimmed` is never touched at the same time.
    private static func trimOnce() {
        guard !trimmed else { return }
        trimmed = true
        queue.asyncAfter(deadline: .now() + 30) { trim() }
    }

    private nonisolated(unsafe) static var trimmed = false

    static func trim(limit: Int = limit) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
