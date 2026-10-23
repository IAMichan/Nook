import Foundation

/// What you send in a chat besides text, the same for every chat app: a file (a photo, a video, a GIF, a sticker, an
/// audio or voice message, any document) with an optional caption, a poll, a place, or a contact card. The Chats tab
/// builds it; each app's bridge turns it into that app's own request (`WASend` for the WhatsApp gateways and Nook's chat helper,
/// `TelegramData.content` for Telegram). Foundation only, so it can be tested anywhere.
enum ChatOutgoing: Equatable, Sendable {
    case file(ChatAttachment)
    case poll(ChatPollDraft)
    case location(ChatPlace)
    case contact(ChatContactCard)

    /// What can go out besides text; a chat app says which of these it can send (`ChatOutgoing.Kind.everything`…).
    enum Kind: String, CaseIterable, Sendable {
        case photo, video, gif, sticker, audio, voice, file, poll, location, contact

        init(_ media: ChatMedia.Kind) {
            switch media {
            case .photo: self = .photo
            case .video: self = .video
            case .gif: self = .gif
            case .sticker: self = .sticker
            case .audio: self = .audio
            case .voice: self = .voice
            case .file: self = .file
            }
        }

        /// Everything WhatsApp and Telegram send themselves.
        static let everything = Set(allCases)
        /// What an app sends when it has no polls of its own (the apps Nook's chat helper links): files, and a place or a contact as text.
        static let noPolls = everything.subtracting([.poll])
    }

    var kind: Kind {
        switch self {
        case .file(let attachment): return Kind(attachment.kind)
        case .poll: return .poll
        case .location: return .location
        case .contact: return .contact
        }
    }

    /// One line for the chat list and for Nook, as a received one reads ("📊 Lunch?", "📍 Café de Jaren").
    var line: String {
        switch self {
        case .file(let attachment):
            let caption = attachment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = ChatMedia(kind: attachment.kind, name: attachment.name).label
            return caption.isEmpty ? label : "\(label): \(caption)"
        case .poll(let poll): return "📊 " + poll.question
        case .location(let place): return "📍 " + place.title
        case .contact(let card): return "👤 " + card.name
        }
    }

    /// The same as plain text, for an app that cannot send it as itself (a place or a contact in a chat the helper links).
    var text: String {
        switch self {
        case .file(let attachment): return attachment.caption
        case .poll(let poll): return (["📊 " + poll.question] + poll.cleanOptions.map { "• " + $0 }).joined(separator: "\n")
        case .location(let place): return ["📍 " + place.title, place.mapsLink].joined(separator: "\n")
        case .contact(let card): return ["👤 " + card.name, card.phone].joined(separator: "\n")
        }
    }
}

/// A file on this Mac to send: what it goes as (a photo, a sticker, a voice message…), its name and type, and the caption
/// typed with it.
struct ChatAttachment: Equatable, Sendable, Identifiable {
    var id = UUID().uuidString
    var path: String
    var kind: ChatMedia.Kind
    var name: String
    var mimeType: String
    var bytes: Int
    /// How long a recorded voice message lasts.
    var seconds: Double? = nil
    var caption = ""

    /// The largest file Nook sends: what the WhatsApp gateways accept for a document.
    static let maxBytes = 50_000_000

    var url: URL { URL(fileURLWithPath: path) }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    /// A file chosen, dropped or recorded, sent as `kind`, or else as what it looks like (`ChatMedia.kind`). Nil when it
    /// is not a readable file.
    init?(url: URL, as kind: ChatMedia.Kind? = nil, seconds: Double? = nil) {
        guard url.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let name = url.lastPathComponent
        let mime = Self.mimeType(forExtension: (name as NSString).pathExtension)
        self.init(path: url.path, kind: kind ?? ChatMedia.kind(mimeType: mime, name: name), name: name, mimeType: mime,
                  bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0, seconds: seconds)
    }

    init(path: String, kind: ChatMedia.Kind, name: String, mimeType: String, bytes: Int, seconds: Double? = nil,
         caption: String = "") {
        self.path = path
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.bytes = bytes
        self.seconds = seconds
        self.caption = caption
    }

    var tooLarge: Bool { bytes > Self.maxBytes }

    /// What else this file can go as: a picture as a photo, a sticker or a document; a GIF as a GIF, a sticker or a
    /// document; a video as a video, a GIF or a document; audio as audio, a voice message or a document.
    var alternatives: [ChatMedia.Kind] {
        switch ChatMedia.kind(mimeType: mimeType, name: name) {
        case .photo, .sticker: return [.photo, .sticker, .file]
        case .gif: return [.gif, .sticker, .file]
        case .video: return [.video, .gif, .file]
        case .audio, .voice: return [.audio, .voice, .file]
        case .file: return [.file]
        }
    }

    /// The same file, sent as `kind` instead.
    func sent(as kind: ChatMedia.Kind) -> ChatAttachment {
        var copy = self
        copy.kind = kind
        return copy
    }

    /// A file's MIME type by its extension, for the gateways that ask for one; a file Nook does not know goes as bytes.
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "webm": return "video/webm"
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "ogg", "opus", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "amr": return "audio/amr"
        case "caf": return "audio/x-caf"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "txt", "md": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "pages": return "application/vnd.apple.pages"
        case "numbers": return "application/vnd.apple.numbers"
        case "key": return "application/vnd.apple.keynote"
        case "vcf": return "text/vcard"
        default: return "application/octet-stream"
        }
    }

    /// "2.4 MB": a file's size as a chat shows it.
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A poll you are about to send: its question, its options, and whether more than one may be chosen.
struct ChatPollDraft: Equatable, Sendable {
    var question = ""
    var options = ["", ""]
    var multiple = false

    /// What WhatsApp allows, and Telegram within it: 2 to 12 options of at most 100 characters, a question of 255.
    static let minOptions = 2
    static let maxOptions = 12
    static let maxQuestion = 255
    static let maxOption = 100

    /// The options as they go out: trimmed, empty ones left out, each once.
    var cleanOptions: [String] {
        var seen = Set<String>()
        return options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var cleanQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why it cannot go yet, as the key of a sentence to show under it; nil when it can.
    var problem: String? {
        if cleanQuestion.isEmpty { return "chat.compose.poll.noQuestion" }
        if cleanQuestion.count > Self.maxQuestion { return "chat.compose.poll.questionTooLong" }
        let filled = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if filled.count != cleanOptions.count { return "chat.compose.poll.duplicate" }
        if cleanOptions.count < Self.minOptions { return "chat.compose.poll.tooFew" }
        if cleanOptions.count > Self.maxOptions { return "chat.compose.poll.tooMany" }
        if cleanOptions.contains(where: { $0.count > Self.maxOption }) { return "chat.compose.poll.optionTooLong" }
        return nil
    }

    /// The fields of the form: one empty option is always there to type the next in, up to the most allowed.
    func withSpareOption() -> ChatPollDraft {
        var draft = self
        if draft.options.count < Self.maxOptions,
           !(draft.options.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) {
            draft.options.append("")
        }
        return draft
    }

    /// The poll as the chat shows it once sent: no votes yet.
    var chatPoll: ChatPoll {
        ChatPoll(question: cleanQuestion, options: cleanOptions.map { ChatPoll.Option(text: $0) }, multiple: multiple)
    }
}

/// A place to send: where it is, and what it is called.
struct ChatPlace: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name = ""
    var address = ""

    var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0) }

    /// Its name, else its address, else its coordinates.
    var title: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? coordinates : address
    }

    /// "52.37403, 4.88969".
    var coordinates: String { String(format: "%.5f, %.5f", latitude, longitude) }

    /// The place on Apple Maps, for an app that takes it as text.
    var mapsLink: String {
        var link = "https://maps.apple.com/?ll=" + String(format: "%.6f,%.6f", latitude, longitude)
        let label = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? ""
        if !label.isEmpty { link += "&q=" + label }
        return link
    }

    /// Coordinates typed or pasted ("52.374, 4.889"), or a map link that holds them (Apple Maps' `ll=`/`q=`, Google
    /// Maps' `@52.37,4.88` or `q=`). Nil when there are none, so the text is looked up as an address instead.
    static func coordinates(in text: String) -> (latitude: Double, longitude: Double)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let number = #"(-?\d{1,3}(?:\.\d+)?)"#
        let patterns = [
            #"^"# + number + #"\s*[,;\s]\s*"# + number + #"$"#,
            #"[?&](?:ll|q|query|sll|daddr|center)="# + number + #"(?:,|%2C)"# + number,
            #"@"# + number + #","# + number,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let latRange = Range(match.range(at: 1), in: trimmed), let lonRange = Range(match.range(at: 2), in: trimmed),
                  let latitude = Double(trimmed[latRange]), let longitude = Double(trimmed[lonRange]) else { continue }
            let place = ChatPlace(latitude: latitude, longitude: longitude)
            if place.isValid { return (latitude, longitude) }
        }
        return nil
    }
}

/// A contact card to send: a name and a phone number.
struct ChatContactCard: Equatable, Sendable {
    var name: String
    var phone: String

    /// The number as the gateways take it: its digits, with a leading "+" kept.
    var cleanPhone: String {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (6...20).contains(cleanPhone.filter(\.isNumber).count)
    }

    /// The card as a vCard, for an app that takes one.
    var vCard: String {
        let safe = name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: ",")
        return ["BEGIN:VCARD", "VERSION:3.0", "FN:" + safe, "TEL;TYPE=CELL:" + cleanPhone, "END:VCARD"].joined(separator: "\n")
    }
}
