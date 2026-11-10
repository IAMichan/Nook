import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The chats' own pictures for the iPhone companion (`CompanionFeature.avatars`): which picture a chat has, as a short
/// version the phone keeps it under (`InboxChatDigest.avatar`), and the picture itself as a small square JPEG
/// (`ChatAvatar`), made from the same file the Chats tab on the Mac shows.
enum CompanionAvatars {
    /// The version of the picture at `path`: its path and when the file last changed, hashed, so a new picture in the same
    /// place counts as new. Nil when there is no file. Looked up again at most once a minute per file, since the inbox is
    /// listed every time it changes.
    @MainActor
    static func version(_ path: String?, now: Date = Date()) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let known = versions[path], now.timeIntervalSince(known.checked) < 60 { return known.version }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let version = modified.map { date in
            let seed = Data((path + "|" + String(Int(date.timeIntervalSince1970))).utf8)
            return PureSHA256.hash(seed).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        if versions.count > 2_000 { versions.removeAll(keepingCapacity: true) }
        versions[path] = (version, now)
        return version
    }

    @MainActor private static var versions: [String: (version: String?, checked: Date)] = [:]

    /// The pictures of these chats (path and version each), made off the main thread; a picture that cannot be read or is
    /// too big after shrinking is left out, and the whole answer stays within one frame.
    static func pictures(_ chats: [(chat: String, path: String, version: String)]) async -> [ChatAvatar] {
        await Task.detached(priority: .utility) {
            var made: [ChatAvatar] = []
            var total = 0
            for chat in chats.prefix(ChatAvatar.batch) {
                guard let data = jpeg(URL(fileURLWithPath: chat.path), side: ChatAvatar.side),
                      data.count <= ChatAvatar.maxBytes, total + data.count <= ChatAvatar.batch * ChatAvatar.maxBytes else { continue }
                total += data.count
                made.append(ChatAvatar(chat: chat.chat, version: chat.version, jpeg: data.base64EncodedString()))
            }
            return made
        }.value
    }

    /// The picture as a JPEG, cropped to a square in its middle and `side` pixels across.
    static func jpeg(_ url: URL, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side * 2,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(thumbnail.width, thumbnail.height)
        let crop = CGRect(x: (thumbnail.width - edge) / 2, y: (thumbnail.height - edge) / 2, width: edge, height: edge)
        guard let square = thumbnail.cropping(to: crop),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
