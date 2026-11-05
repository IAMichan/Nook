import Foundation

/// A file that came with a chat message, the same for every chat app: a photo, a video, a GIF, a sticker, an audio or
/// voice message, or any other file. A bridge that can fetch the file keeps it on this Mac (`path`) and the chat shows
/// it as itself; until then, or when it cannot be fetched, the chat shows what it is. Foundation only, so it can be
/// tested anywhere; `ChatBubble.init(_:time:)` turns it into what a bubble draws.
struct ChatMedia: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photo, video, gif, sticker, audio, voice, file
    }

    var kind: Kind
    /// The file's own name, when it has one ("plan.pdf").
    var name: String? = nil
    /// Where the file is on this Mac, once Nook has it.
    var path: String? = nil
    /// How long a video or an audio message lasts.
    var seconds: Double? = nil
    /// Where the bridge fetches it from (Slack's or the chat helper's address for it), while it is not on this Mac yet.
    var source: String? = nil
    /// Its app keeps it where no bridge reaches (Teams' files in SharePoint or OneDrive): it will never be on this Mac, so
    /// the chat names it at once instead of waiting for it. Any app says so the same way; nil: it can be fetched.
    var outOfReach: Bool? = nil

    /// A picture that is not on this Mac but can still come: its chat shows a photo-shaped tile until it is here.
    var isPictureComing: Bool {
        guard outOfReach != true else { return false }
        return shownKind == .photo || shownKind == .gif
    }

    /// The file on this Mac, if it is (still) there.
    var url: URL? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// What the chat calls it while it is not on this Mac, and what is copied for it: the file's name, else its kind.
    var label: String {
        if kind == .file, let name, !name.isEmpty { return name }
        switch kind {
        case .photo: return tr("whatsapp.file.photo")
        case .video: return tr("whatsapp.file.video")
        case .gif: return tr("chat.media.gif")
        case .sticker: return tr("chat.media.sticker")
        case .audio: return tr("chat.media.audio")
        case .voice: return tr("whatsapp.file.voice")
        case .file: return tr("whatsapp.file.document")
        }
    }

    /// The kind of a file by what its app says of it: its MIME type, its name, and whether the app calls it a sticker,
    /// a GIF or a voice message. A GIF is a GIF whether it comes as one or as a short silent video the app loops.
    static func kind(mimeType: String?, name: String? = nil, sticker: Bool = false, gif: Bool = false,
                     voice: Bool = false) -> Kind {
        if sticker { return .sticker }
        let type = (mimeType ?? "").lowercased()
        let ext = ((name ?? "") as NSString).pathExtension.lowercased()
        if gif || type == "image/gif" || ext == "gif" { return .gif }
        if voice { return .voice }
        if type.hasPrefix("image/") || Self.pictureExtensions.contains(ext) { return .photo }
        if type.hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(ext) { return .video }
        if type.hasPrefix("audio/") || ["m4a", "mp3", "aac", "caf", "wav", "ogg", "opus", "amr"].contains(ext) { return .audio }
        return .file
    }

    /// The names a photo ends in, also when its app sends it as a document.
    private static let pictureExtensions: Set<String> = ["jpg", "jpeg", "jfif", "png", "heic", "heif", "webp", "tif", "tiff",
                                                         "bmp", "avif"]

    /// How the chat shows the file: as its kind, except a document that is a photo, a GIF, a video or a sound by its
    /// name (a photo sent "as a document" in WhatsApp, a picture attached to a Slack or Teams message), which shows as
    /// that, the same in every app.
    var shownKind: Kind {
        guard kind == .file else { return kind }
        return Self.kind(mimeType: nil, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? path)
    }

    /// Whether a fetched file is whole: there, not empty, and not written to for `quiet` seconds. An app or a helper
    /// hands a file over the moment it exists, often while it still writes it; a photo decoded then shows (and is
    /// cached) half grey, and a video does not play at all.
    static func isSettled(_ url: URL, quiet: TimeInterval = 1.5, now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else { return false }
        guard let modified = attributes[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(modified) >= quiet
    }

    /// The MIME type of a video by its first bytes, for a file whose name does not say (a chat helper's "dbe80cq9", a
    /// "video.bin"): an MP4, QuickTime or 3GP file names its brand right after "ftyp". Nil for anything else.
    static func videoMIMEType(head: Data) -> String? {
        let bytes = [UInt8](head.prefix(12))
        guard bytes.count == 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" else { return nil }
        let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
        if brand == "qt  " { return "video/quicktime" }
        if brand.hasPrefix("M4A") { return "audio/mp4" }
        if brand.hasPrefix("3g") { return "video/3gpp" }
        return "video/mp4"
    }

    /// The largest file a bridge fetches by itself to show in a chat; a larger one opens in its app.
    static let maxBytes = 25_000_000

    /// Where bridges keep the files they fetched: in Nook's caches, so macOS may clear them; a chat then shows the kind
    /// again until the bridge fetches it anew.
    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nook/ChatMedia", isDirectory: true)
    }

    /// A safe place for a fetched file: `key` (the message's id) decides the folder, `name` the file name, so a file is
    /// fetched once and a name from a chat can never reach outside the folder.
    static func destination(key: String, name: String) -> URL {
        let safeKey = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.suffix(120))
        var file = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if file.isEmpty { file = "file" }
        return folder.appendingPathComponent(safeKey, isDirectory: true).appendingPathComponent(String(file.suffix(120)))
    }

    /// Where a chat's profile picture from `source` (the address its app gives for it) is kept: a file of its own per
    /// picture, named after where it came from. A changed picture comes from another address, so it gets another file and
    /// another path, and every list that showed the old one decodes the new one instead of keeping the old face cached
    /// by its path. The same address keeps its file, so a picture is fetched once.
    static func avatarDestination(key: String, source: String, ext: String = "jpg") -> URL {
        // FNV-1a: the same name for the same address on every launch (`hashValue` changes per launch).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let safeExt = ext.filter { $0.isLetter || $0.isNumber }.prefix(5)
        return destination(key: key, name: "avatar-" + String(hash, radix: 16) + "." + (safeExt.isEmpty ? "jpg" : String(safeExt)))
    }

    /// The profile picture kept for `key` before, whichever address it came from, to show at once while its app is
    /// asked whether it changed: the newest file in its folder.
    static func savedAvatar(key: String) -> String? {
        let dir = destination(key: key, name: "avatar.jpg").deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { $0.lastPathComponent.hasPrefix("avatar") }.max { date($0) < date($1) }?.path
    }

    /// Removes the pictures `key` had before `kept`, once `kept` is its picture.
    static func dropOtherAvatars(key: String, keeping kept: URL) {
        let dir = kept.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != kept.lastPathComponent && file.lastPathComponent.hasPrefix("avatar") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension ChatMedia {
    /// How many of a read's files a bridge fetches at the same time: a chat with several photos shows them together
    /// instead of one after another, without asking a service for dozens at once.
    static let parallelFetches = 4

    /// `messages` with the files `fetch` brought to this Mac (it returns where it put one, nil when it could not), for
    /// every message whose file is not here yet, `parallelFetches` at a time. The messages keep their order. The same
    /// for every bridge that fetches its files itself (Slack, the chat helper).
    @MainActor
    static func fetchingFiles(_ messages: [InboxMessage], limit: Int = parallelFetches,
                              fetch: @escaping @MainActor (InboxMessage) async -> String?) async -> [InboxMessage] {
        var result = messages
        let wanted = messages.indices.filter { messages[$0].media != nil && messages[$0].media?.path == nil }
        guard !wanted.isEmpty else { return result }
        await withTaskGroup(of: (Int, String?).self) { group in
            var next = wanted.makeIterator()
            for _ in 0..<max(limit, 1) {
                guard let index = next.next() else { break }
                let message = messages[index]
                group.addTask { @MainActor in (index, await fetch(message)) }
            }
            while let (index, path) = await group.next() {
                if let more = next.next() {
                    let message = messages[more]
                    group.addTask { @MainActor in (more, await fetch(message)) }
                }
                if let path { result[index].media?.path = path }
            }
        }
        return result
    }
}
