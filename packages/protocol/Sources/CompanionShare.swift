import Foundation

// What reaches the Mac from outside the app's own composers: files from the share sheet, what other apps share into a
// session or Nook's chat (docs/COMPANION.md, "Sharing to Nook"), and a snooze to a moment you pick. Foundation only, so
// it is tested on its own.

/// A file that goes with a message (`CompanionRequest.attachments`, `CompanionFeature.attachments`): its name and its
/// bytes, base64. The Mac saves it where its composer keeps attachments and gives the agent its path below the words.
struct CompanionFile: Codable, Equatable, Sendable {
    var name: String
    var data: String

    /// What one file may weigh before base64, and how many go with one message.
    static let maxBytes = 150 * 1024
    static let maxCount = 1
    /// Pictures and files of one message together, before base64: with base64 and the rest of the request this stays
    /// under `CompanionConstants.maxFrame`.
    static let maxTogether = 180 * 1024

    init(name: String, bytes: Data) {
        self.name = name
        data = bytes.base64EncodedString()
    }

    /// The file's bytes when they decode and are within the limit; nil otherwise.
    var bytes: Data? {
        guard let bytes = Data(base64Encoded: data), !bytes.isEmpty, bytes.count <= Self.maxBytes else { return nil }
        return bytes
    }

    /// A name that is safe to save under: the last path component, without control characters or a leading dot, at most
    /// 80 characters with its extension kept; nil when nothing is left.
    static func safeName(_ name: String) -> String? {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let kept = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var clean = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        guard !clean.isEmpty else { return nil }
        guard clean.count > 80 else { return clean }
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        return ext.isEmpty || ext.count > 10 ? String(clean.prefix(80)) : String(stem.prefix(79 - ext.count)) + "." + ext
    }

    /// Whether these pictures and files may go together in one message.
    static func fits(images: [CompanionImage], files: [CompanionFile]) -> Bool {
        guard images.count <= CompanionImage.maxCount, files.count <= maxCount else { return false }
        var total = 0
        for image in images {
            guard let data = image.data else { return false }
            total += data.count
        }
        for file in files {
            guard let bytes = file.bytes, safeName(file.name) != nil else { return false }
            total += bytes.count
        }
        return total <= maxTogether
    }
}

/// A snooze to a moment you pick (`SessionAction.snoozeUntil`), as the Mac's custom snooze takes it: ahead of now, at most
/// a month out.
enum CompanionSnooze {
    static let maxAhead: TimeInterval = 31 * 24 * 3600
    /// A moment closer than this is no snooze.
    static let minAhead: TimeInterval = 30

    /// The end a request asks for (`text`: seconds since 1970), pulled in to `maxAhead`; nil when it is not a time ahead.
    static func end(_ text: String?, now: Date = Date()) -> Date? {
        guard let text, let seconds = Double(text.trimmingCharacters(in: .whitespaces)), seconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        guard date > now.addingTimeInterval(minAhead) else { return nil }
        return min(date, now.addingTimeInterval(maxAhead))
    }

    static func text(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }
}

// MARK: Sharing from other apps

/// Something shared to Nook from another app (the share sheet): kept in the app group until the app hands it to its
/// Mac's outbox, where it waits for the Mac like anything you write in the app.
struct SharedItem: Codable, Equatable, Identifiable, Sendable {
    enum Target: Codable, Equatable, Sendable {
        /// A new session with this agent in this folder (one the Mac offered, `ShareTargets`).
        case newSession(agent: String, project: String, worktree: Bool)
        /// A message to a session.
        case session(String)
        /// A question to Nook, in a new chat.
        case nookChat
    }

    /// Becomes the request's id, so the Mac carries it out once however often it is sent.
    var id: String
    /// The pairing it is for (`PairedMac.id`): the Mac that was active when it was shared.
    var mac: String
    /// When it was shared (seconds since 1970); its time in the outbox counts from here.
    var created: Double
    var target: Target
    var text: String
    var images: [CompanionImage]
    var files: [CompanionFile]

    init(id: String = UUID().uuidString, mac: String, created: Date = Date(), target: Target, text: String,
         images: [CompanionImage] = [], files: [CompanionFile] = []) {
        self.id = id; self.mac = mac; self.created = created.timeIntervalSince1970; self.target = target; self.text = text
        self.images = images; self.files = files
    }

    /// The words of a share: your note, then what was shared (text, links), each once.
    static func words(note: String, shared: [String]) -> String {
        var parts: [String] = []
        for part in [note] + shared {
            let clean = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !parts.contains(clean) { parts.append(clean) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Why it cannot go as it is, or nil: a new session or a question needs words; Nook's chat takes no pictures or files.
    var problem: Problem? {
        let words = CompanionPolicy.cleanMessage(text)
        if !images.isEmpty || !files.isEmpty {
            if case .nookChat = target { return .nookTakesNoFiles }
            if !CompanionFile.fits(images: images, files: files) { return .tooBig }
        }
        switch target {
        case .newSession, .nookChat: return words == nil ? .needsWords : nil
        case .session: return words == nil && images.isEmpty && files.isEmpty ? .needsWords : nil
        }
    }

    enum Problem: Equatable, Sendable { case needsWords, tooBig, nookTakesNoFiles }

    /// The request that carries it to the Mac: `start`, `send` or `ask`, with this item's id and the time it was shared.
    /// Nil when it cannot go (`problem`).
    func request() -> CompanionRequest? {
        guard problem == nil else { return nil }
        let pictures = images.isEmpty ? nil : images
        let attached = files.isEmpty ? nil : files
        switch target {
        case .newSession(let agent, let project, let worktree):
            return CompanionRequest(id: id, sent: created, op: .start,
                                    launch: LaunchRequest(agent: agent, project: project, task: text, worktree: worktree),
                                    images: pictures, attachments: attached)
        case .session(let session):
            return CompanionRequest(id: id, sent: created, op: .send, session: session, text: text, images: pictures,
                                    attachments: attached)
        case .nookChat:
            return CompanionRequest(id: id, sent: created, op: .ask, text: text)
        }
    }
}

/// The shares that wait for the app (a file in the app group): the share sheet adds, the app takes them into its Mac's
/// outbox when it comes to the front.
struct ShareQueue: Codable, Equatable, Sendable {
    private(set) var items: [SharedItem] = []

    static let maxItems = 20

    /// False when it is full, or the item cannot go as it is.
    @discardableResult
    mutating func add(_ item: SharedItem) -> Bool {
        guard item.problem == nil, items.count < Self.maxItems else { return false }
        guard !items.contains(where: { $0.id == item.id }) else { return true }
        items.append(item)
        return true
    }

    /// Takes out what is for `mac`, oldest first, and drops what waited longer than the outbox would let it
    /// (`CompanionOutbox.maxAge(for:)`); returns what is to be sent and what was too old.
    mutating func take(for mac: String, now: Date) -> (ready: [SharedItem], expired: [SharedItem]) {
        let mine = items.filter { $0.mac == mac }
        items.removeAll { $0.mac == mac }
        var ready: [SharedItem] = [], expired: [SharedItem] = []
        for item in mine.sorted(by: { $0.created < $1.created }) {
            guard let request = item.request() else { continue }
            let age = now.timeIntervalSince1970 - item.created
            if age > CompanionOutbox.maxAge(for: request.op) { expired.append(item) } else { ready.append(item) }
        }
        return (ready, expired)
    }

    /// Items for a Mac that is no longer paired are dropped.
    mutating func keep(macs: Set<String>) { items.removeAll { !macs.contains($0.mac) } }
}

/// What the share sheet may offer, written by the app for the active Mac whenever it learns it: the sessions to send to,
/// the agents and folders a new session can start with, and whether Nook's chat and files are possible. Titles stay on
/// the phone, in its app group.
struct ShareTargets: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var agent: String
        var folder: String
    }

    var mac: String
    var macName: String
    var sessions: [Session]
    var launch: LaunchOptions?
    var canStart: Bool
    var canSend: Bool
    var canAsk: Bool
    var canAttach: Bool
    var canImages: Bool
    var updated: Double

    static let maxSessions = 25

    /// The sessions a message can go to: ones that take messages, the newest first.
    static func sessions(_ digests: [SessionDigest]) -> [Session] {
        digests.filter { $0.canSend != false }.sorted { $0.updated > $1.updated }.prefix(maxSessions)
            .map { Session(id: $0.id, title: $0.title, agent: $0.agent, folder: $0.folder) }
    }
}
