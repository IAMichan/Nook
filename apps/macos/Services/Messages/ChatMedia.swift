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
    /// Where the bridge fetches it from (Slack's or Beeper's address for it), while it is not on this Mac yet.
    var source: String? = nil

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
        if type.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "bmp"].contains(ext) { return .photo }
        if type.hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(ext) { return .video }
        if type.hasPrefix("audio/") || ["m4a", "mp3", "aac", "caf", "wav", "ogg", "opus", "amr"].contains(ext) { return .audio }
        return .file
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
}
