import Foundation

/// `ChatStore` off the main thread: one connection that writes, on its own serial queue, and one that only reads, on
/// another. With WAL a read never waits for a write nor a write for a read, so scrolling back and searching stay quick
/// while a bridge's read is being saved.
final class ChatArchive: @unchecked Sendable {
    /// Nook's own: `chats.sqlite` next to the other stores. Nil when the file cannot be opened as a database; the inbox
    /// then lives in memory only for that session.
    static let shared: ChatArchive? = ChatArchive(url: NookPaths.supportDirectory.appendingPathComponent("chats.sqlite"))

    let url: URL
    private let writer: ChatStore
    private var reader: ChatStore?
    private var readerOpened = false
    private let writeQueue = DispatchQueue(label: "nook.chats.write", qos: .utility)
    private let readQueue = DispatchQueue(label: "nook.chats.read", qos: .userInitiated)

    init?(url: URL) {
        guard let writer = ChatStore(url: url) else { return nil }
        self.url = url
        self.writer = writer
    }

    /// Runs `body` with the writing connection, after every write asked for before it.
    func write(_ body: @escaping @Sendable (ChatStore) -> Void) {
        writeQueue.async { [writer] in body(writer) }
    }

    /// The same, waiting for it: at launch (the inbox has to be read before anything changes it) and at quit.
    func writeNow<T>(_ body: (ChatStore) -> T) -> T {
        writeQueue.sync { body(writer) }
    }

    /// Runs `body` with the writing connection after every write asked for before it, and gives what it returns.
    func written<T: Sendable>(_ body: @escaping @Sendable (ChatStore) -> T) async -> T {
        await withCheckedContinuation { continuation in
            writeQueue.async { [writer] in continuation.resume(returning: body(writer)) }
        }
    }

    /// Runs `body` with the reading connection, off the main thread.
    func read<T: Sendable>(_ body: @escaping @Sendable (ChatStore) -> T) async -> T {
        await withCheckedContinuation { continuation in
            readQueue.async { [self] in
                if !readerOpened {
                    readerOpened = true
                    reader = ChatStore(url: url, readOnly: true)
                }
                // Without a reading connection (the file could not be opened twice), reads wait their turn on the writer.
                guard let reader else {
                    continuation.resume(returning: writeQueue.sync { body(writer) })
                    return
                }
                continuation.resume(returning: body(reader))
            }
        }
    }
}

/// Each connection is used by one queue only (`ChatArchive`).
extension ChatStore: @unchecked Sendable {}

/// Nook's own archive as one of the chat histories Search everything (⌘K) asks (`ChatSearchBridge`), for every app at
/// once: what any bridge or notification ever brought is found without asking the apps, older than what the inbox holds
/// in memory included. The apps' own searches still run beside it for what Nook never saw.
@MainActor
final class ChatArchiveSearch: ChatSearchBridge {
    static let shared = ChatArchiveSearch()

    let app = "nook-archive"
    let interval: TimeInterval = .infinity
    var isReady: Bool { ChatArchive.shared != nil }
    var isWorking: Bool { isReady }
    var alwaysOn: Bool { true }
    var searchesHistory: Bool { isReady }

    func read() async throws -> [BridgedChat] { [] }

    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat] {
        guard let archive = ChatArchive.shared, !words.isEmpty else { return [] }
        let found = await archive.read { $0.search(words, limit: limit) }
        return found.map { Self.chat($0.thread, messages: $0.messages) }
    }

    /// A chat as the archive wrote it, in the shape a bridge brings it, so the Chats tab knows it by the same key.
    static func chat(_ thread: InboxThread, messages: [InboxMessage]) -> BridgedChat {
        var chat = BridgedChat(app: thread.app, name: thread.name, messages: messages, unread: nil)
        chat.chatID = thread.chatID
        chat.account = thread.account
        chat.avatar = thread.avatar
        chat.members = thread.members
        chat.faces = thread.faces
        chat.kind = thread.kind
        chat.handle = thread.handle
        return chat
    }
}

/// A bridge whose chats its app knows by an id, filling the archive by that id (`ChatBackfill`): WhatsApp through the
/// linked phone. It gives the messages before `before` without changing what its chats show.
@MainActor
protocol ChatBackfillBridge: ChatBridge {
    func canBackfill(chatID: String) -> Bool
    func backfill(chatID: String, before: Date, limit: Int) async throws -> [InboxMessage]
    /// The same page, with the messages of its stretch the app now has as deleted under another id (Mail, which may
    /// give a mail it moved to the Trash a new one): the archive finds them by time and first line (`ChatReconcile.gone`).
    func backfillPage(chatID: String, before: Date, limit: Int) async throws -> (messages: [InboxMessage], gone: [InboxMessage])
    /// An empty answer is the chat's start, never a busy moment (Mail, which looks all the way back in one answer).
    var backfillEmptyIsStart: Bool { get }
}

extension ChatBackfillBridge {
    var backfillEmptyIsStart: Bool { false }

    func backfillPage(chatID: String, before: Date, limit: Int) async throws -> (messages: [InboxMessage], gone: [InboxMessage]) {
        (try await backfill(chatID: chatID, before: before, limit: limit), [])
    }
}
