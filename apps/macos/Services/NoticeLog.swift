import Foundation

/// One notice Nook gave (an agent is done, a request waits, a message came in), kept so it can still be read after the
/// card, strip or banner that showed it is gone.
struct NoticeEntry: Equatable, Identifiable {
    /// The notice's state, colored like everywhere else: done mint, failed coral, waiting amber, info iris.
    enum Kind: String {
        case done, failed, waiting, info
    }

    /// Where a click on the entry takes you: a value, not a closure, so an entry never holds on to what made it.
    enum Target: Equatable {
        /// An agent session in the Agents tab, by its id.
        case agent(String)
        /// A session Nook runs itself, by its run id.
        case run(UUID)
        /// The Agents tab, without a session chosen.
        case agents
        /// A conversation with Nook.
        case conversation(UUID)
        /// A WhatsApp chat, by its id.
        case whatsApp(String)
        /// A chat from another app in the Chats tab, by its id there ("telegram|anna").
        case chat(String)
        /// Nothing to open: the entry is only read.
        case nowhere
    }

    var id = UUID()
    /// Notices about the same thing (one WhatsApp chat, one request) share a key: a newer one replaces the older.
    var key: String
    var kind: Kind
    var title: String
    var detail: String = ""
    /// Who and where ("Claude Code · nook").
    var context: String = ""
    var date: Date
    var target: Target = .nowhere
    /// Opened the history since this came in.
    var seen = false
}

/// The notices Nook gave, newest first. A bounded list: at most `limit` entries and none older than `maxAge`.
struct NoticeLog: Equatable {
    static let limit = 100
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// The longest detail kept; a long command or message is cut, the history is for recognizing what it was.
    static let detailLimit = 400

    private(set) var entries: [NoticeEntry] = []

    /// The entries you have not seen in the history yet.
    var unseen: Int { entries.filter { !$0.seen }.count }

    /// Adds `entry` on top. An entry with the same key goes, and the oldest fall off past `limit` or `maxAge`.
    mutating func add(_ entry: NoticeEntry, now: Date = Date()) {
        var entry = entry
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.detail = Self.detail(entry.detail)
        guard !entry.title.isEmpty else { return }
        entries.removeAll { $0.key == entry.key }
        entries.insert(entry, at: 0)
        prune(now: now)
    }

    mutating func markAllSeen() {
        for index in entries.indices { entries[index].seen = true }
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// Drops what is older than `maxAge` and what does not fit in `limit`.
    mutating func prune(now: Date = Date()) {
        entries.removeAll { now.timeIntervalSince($0.date) > Self.maxAge }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// A detail as the log keeps it: trimmed, and cut at `detailLimit`.
    static func detail(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > detailLimit else { return text }
        return String(text.prefix(detailLimit)) + "…"
    }
}
