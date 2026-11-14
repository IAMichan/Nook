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
    /// The website keeps no history beyond what it shows, so walking back finds nothing older; edits and deletions are
    /// found by laying each read beside what Nook keeps (`SnapchatWebData.changes`).
    var historyChanges: Bool { false }
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
        // No one can see the screen (it sleeps or is locked): the website is let go (`SnapchatWebSession`) and not
        // loaded again for a list no one reads now; the next read once the screen is back brings what changed.
        guard !EnergyMonitor.shared.plan.unseen else { return [] }
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
                chats.append(SnapchatWebData.chat(row, kept: kept[row.id] ?? [], snapLabel: tr("chats.snapchat.snap"), pictures: pictures))
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
        return (SnapchatWebData.chat(row, kept: kept[row.id] ?? [], snapLabel: tr("chats.snapchat.snap"), pictures: pictures), false)
    }

    /// The pictures saved of the chats' messages, by message id: the website shows them only while a chat is open.
    private var pictures: [String: String] = [:]

    /// Reads the chat's messages and keeps them with what Nook already had; the pictures among them not saved yet are
    /// saved now, while the chat is open.
    private func take(_ row: SnapchatWebData.Row) async throws {
        let before = kept[row.id] ?? []
        var aligned = before
        var wanted: [String: String] = [:]
        let read = try await session.read(row) { [weak self] lines in
            aligned = SnapchatWebData.align(before, with: lines, chat: row.id, now: Date())
            // The read's lines are the newest of what is kept, in their order.
            let shown = aligned.suffix(lines.count)
            guard shown.count == lines.count else { return [] }
            for (item, line) in zip(shown, lines) where item.line == line {
                guard let source = line.source, self?.pictures[item.id] == nil else { continue }
                wanted[source] = item.id
            }
            return Array(wanted.keys)
        }
        kept[row.id] = aligned
        for (source, data) in read.pictures {
            guard let id = wanted[source] else { continue }
            let target = ChatMedia.destination(key: id, name: "photo.jpg")
            let saved = await Task.detached(priority: .userInitiated) { ChatMedia.save(data, to: target) }.value
            if saved { pictures[id] = target.path }
        }
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

    /// What Snapchat for Web takes from Nook besides text: a picture, handed to the website as you would choose one.
    var sends: Set<ChatOutgoing.Kind> { [.photo, .sticker] }

    /// A picture (with its caption) in the chat `name`, after your own click; the chat is read again right after.
    func send(_ outgoing: ChatOutgoing, to name: String) async throws {
        guard case .file(let file) = outgoing, sends.contains(ChatOutgoing.Kind(file.kind)) else {
            throw NookError(tr("chat.compose.unsupported"))
        }
        guard let row = rows[name] else { throw SnapchatWebSession.Problem.notFound(name) }
        let url = file.url
        guard let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url) }).value,
              data.count <= SnapchatWebData.maxPictureBytes else { throw NookError(tr("chat.compose.unsupported")) }
        try await session.sendPicture(data, name: file.name, type: file.mimeType, caption: file.caption, to: row)
        if kept[row.id] == nil { kept[row.id] = [] }
        lines[row.id] = nil
    }

    /// Forgets what was read, after signing out.
    func reset() {
        rows = [:]
        pictures = [:]
        kept = [:]
        lines = [:]
        isWorking = false
    }
}
