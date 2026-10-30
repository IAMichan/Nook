import Foundation

/// Snapchat in the Chats tab, read from Snapchat for Web (`SnapchatWebSession`). Every read brings the chat list: each
/// chat shows, with whether something waits in it. A chat's messages are read when you ask for them in Nook (opening it
/// and loading its messages), because reading a chat opens it in Snapchat, which tells the other person you opened it,
/// as on your phone. From then on Nook reads that chat again whenever its line in the list changes, and keeps what it
/// read, also what Snapchat deletes after it was seen. Snapchat's website shows no times: a message is dated when Nook
/// first saw it. Nook answers by typing into the website's own field; Snapchat for Web offers nothing Nook can use for
/// files, emoji, edits or deletions, so those stay in the app.
@MainActor
final class SnapchatBridge: ChatHistoryBridge {
    let app = SnapchatWebData.app
    let interval: TimeInterval = 30
    private(set) var isWorking = false

    /// Chats whose messages are read again per round when their line in the list changed.
    private static let perRead = 3

    private var session: SnapchatWebSession { .shared }
    /// The list at the last read, by the chat's name in Nook.
    private var rows: [String: SnapchatWebData.Row] = [:]
    /// What Nook keeps of each chat whose messages it read, by the chat's id.
    private var kept: [String: [SnapchatWebData.Kept]] = [:]
    /// The line under each chat at the last read, by its id: a change there is a reason to read it again.
    private var lines: [String: String] = [:]

    var isReady: Bool { session.isSignedIn }

    func read() async throws -> [BridgedChat] {
        do {
            let list = try await session.list()
            var chats: [BridgedChat] = []
            var reads = 0
            var named: [String: SnapchatWebData.Row] = [:]
            for row in list {
                named[row.name] = row
                var again = false
                if kept[row.id] != nil, lines[row.id] != row.status {
                    if reads < Self.perRead {
                        reads += 1
                        do { try await take(row) } catch { again = true }
                    } else {
                        again = true
                    }
                }
                // A chat that did not open this round, or waits its turn, is read again at the next.
                if !again { lines[row.id] = row.status }
                chats.append(SnapchatWebData.chat(row, kept: kept[row.id] ?? [], snapLabel: tr("chats.snapchat.snap")))
            }
            rows = named
            isWorking = true
            return chats
        } catch {
            isWorking = false
            throw error
        }
    }

    // MARK: A chat's messages

    func canLoadOlder(name: String) -> Bool { isReady && rows[name] != nil }

    /// The chat as the website shows it now: Snapchat for Web keeps no history to scroll back to beyond that, so
    /// there is nothing more after it.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        guard let row = rows[name] else { return (nil, false) }
        try await take(row)
        return (SnapchatWebData.chat(row, kept: kept[row.id] ?? [], snapLabel: tr("chats.snapchat.snap")), false)
    }

    /// Reads the chat's messages and keeps them with what Nook already had.
    private func take(_ row: SnapchatWebData.Row) async throws {
        let read = try await session.read(row)
        kept[row.id] = SnapchatWebData.align(kept[row.id] ?? [], with: read, chat: row.id, now: Date())
    }

    // MARK: Answering

    func canSend(name: String) -> Bool { isReady && rows[name] != nil }

    /// Your text in the chat `name`, after your own click; the chat is read again right after.
    func send(text: String, to name: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard let row = rows[name] else { throw SnapchatWebSession.Problem.notFound(name) }
        try await session.send(body, to: row)
        if kept[row.id] == nil { kept[row.id] = [] }
        lines[row.id] = nil
    }

    /// Forgets what was read, after signing out.
    func reset() {
        rows = [:]
        kept = [:]
        lines = [:]
        isWorking = false
    }
}
