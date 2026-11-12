import Foundation

/// Recent mail read from Mail's own index (`MailIndex`) instead of asked of the Mail app. Mail answers a script on its
/// main thread, one at a time, and walks a mailbox from the top for every message a script names: reading the newest 60
/// of a Gmail inbox of ten thousand mail took it 14 seconds, during which Mail itself did not respond. The index answers
/// the same in milliseconds without Mail noticing. It needs Full Disk Access; without it every caller gets nil and asks
/// Mail as before.
///
/// Both readers of Mail use it: the Chats tab (`MailBridge`) and the Mail connector (`MailConnector`).
enum MailLibrary {
    /// Mail's index on this Mac, or nil when there is none.
    static var databasePath: String? {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return MailIndex.root(library: library).map(MailIndex.databasePath(root:))
    }

    private static func query(_ sql: String) async -> [[String: Any]]? {
        guard let path = databasePath else { return nil }
        return try? await AppDatabase.query(path, sql, app: "Mail")
    }

    /// `MailIndex.changeSQL`: changes whenever mail comes, goes or is read. Nil without access to the index.
    static func changeMark() async -> String? {
        guard let rows = await query(MailIndex.changeSQL), let mark = rows.first?["mark"] as? String else { return nil }
        return "index|" + mark
    }

    /// One mailbox of an account with its newest mail.
    struct Mailbox {
        var box: MailIndex.Box
        var messages: [MailIndex.Recent]
        /// The messages in it that are unread (only counted for an inbox).
        var unread: Int
    }

    /// The inbox, Sent and Trash mailboxes of these accounts (by Mail's account id), each with Mail's names for them.
    /// Nil when the index cannot be read.
    static func boxes(accounts: Set<String>) async -> [MailIndex.Box]? {
        guard let raw = await query(MailIndex.mailboxesSQL) else { return nil }
        return MailIndex.boxes(raw, sentNames: MailChatData.sentNames, trashNames: MailChatData.trashNames)
            .filter { accounts.contains($0.account) }
    }

    /// The inbox, Sent and Trash mailboxes of these accounts (by Mail's account id) with their newest `inbox`, `sent`
    /// and `trash` messages; a kind with a limit of 0 is left out. Nil when the index cannot be read; an account the
    /// index has no mailboxes for is left out.
    static func recent(accounts: Set<String>, inbox: Int, sent: Int, trash: Int = 0) async -> [String: [Mailbox]]? {
        guard let boxes = await boxes(accounts: accounts) else { return nil }
        var result: [String: [Mailbox]] = [:]
        for box in boxes {
            let limit = switch box.kind {
            case .inbox: inbox
            case .sent: sent
            case .trash: trash
            }
            guard limit > 0 else { continue }
            guard let rows = await query(MailIndex.recentSQL(box: box.id, limit: limit)) else { return nil }
            var unread = 0
            if box.kind == .inbox, let count = await query(MailIndex.unreadSQL(box: box.id))?.first?["unread"] as? NSNumber {
                unread = count.intValue
            }
            result[box.account, default: []].append(Mailbox(box: box, messages: MailIndex.recent(rows), unread: unread))
        }
        return result
    }

    /// The start of a message's text: Mail's own summary, else read from its file, cut at `length`. Empty when neither
    /// has it.
    static func text(of message: MailIndex.Recent, length: Int) async -> String {
        var text = message.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let path = databasePath {
            let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            let row = MailIndex.Row(id: message.id, subject: message.subject, sender: message.sender, recipients: "",
                                    date: message.date, summary: "", mailbox: message.mailbox)
            if let file = MailIndex.messageFile(root: root, row: row) {
                text = (await MailConnector.readFile(file))?.text ?? ""
            }
        }
        return text.count > length ? String(text.prefix(length)) : text
    }

    /// The Chats tab's rows of these accounts from the index (`MailChatData.Row`), with the start of each text by
    /// Mail's id, except for the ids in `known` (read before: a message's text does not change). A row's place is where
    /// Mail lists it, newest first, so a script finds it there fast (`locate`).
    static func chatRows(accounts: [MailChatData.Account], inbox: Int, sent: Int, bodyLength: Int, known: Set<Int> = [])
        async -> (rows: [MailChatData.Row], texts: [Int: String])? {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let found = await recent(accounts: Set(byID.keys), inbox: inbox, sent: sent) else { return nil }
        var rows: [MailChatData.Row] = []
        var texts: [Int: String] = [:]
        var seen = Set<Int64>()
        for (id, boxes) in found {
            guard let account = byID[id] else { continue }
            let own = Set(account.addresses)
            // The inbox first: mail you sent yourself, also in Sent, counts once.
            for mailbox in boxes.sorted(by: { $0.box.kind == .inbox && $1.box.kind != .inbox }) {
                for (place, message) in mailbox.messages.enumerated() where seen.insert(message.id).inserted {
                    guard let row = row(message, in: mailbox.box, account: account, own: own, place: place + 1) else { continue }
                    rows.append(row)
                    if !known.contains(Int(message.id)) { texts[Int(message.id)] = await text(of: message, length: bodyLength) }
                }
            }
        }
        return (rows, texts)
    }

    /// A message as the Chats tab keeps it: from the inbox with who wrote it; from Sent with whom you wrote; from the
    /// Trash as either, by whose it is (as `MailChatData.trashRows`). Nil without a person to put it with.
    private static func row(_ message: MailIndex.Recent, in box: MailIndex.Box, account: MailChatData.Account, own: Set<String>,
                            place: Int?) -> MailChatData.Row? {
        let senderIsMe = own.contains(MailChatData.address(message.sender))
        let fromMe = switch box.kind {
        case .inbox: senderIsMe
        case .sent: true
        case .trash: senderIsMe
        }
        let person = box.kind == .inbox || !fromMe ? message.sender : message.recipient
        guard !MailChatData.address(person).isEmpty else { return nil }
        return MailChatData.Row(account: account.name, mailbox: box.path, id: Int(message.id), subject: message.subject,
                                person: person, date: message.date, read: box.kind != .inbox || message.read, fromMe: fromMe,
                                index: box.kind == .trash ? nil : place)
    }

    /// The newest `count` mail in the Trash of each of these accounts, as the rows it was in a chat as (`trashScript`
    /// asked Mail for the same, one message at a time). Nil when the index cannot be read.
    static func trashRows(accounts: [MailChatData.Account], count: Int = 100) async -> [MailChatData.Row]? {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let found = await recent(accounts: Set(byID.keys), inbox: 0, sent: 0, trash: count) else { return nil }
        return found.flatMap { id, boxes -> [MailChatData.Row] in
            guard let account = byID[id] else { return [] }
            let own = Set(account.addresses)
            return boxes.flatMap { mailbox in
                mailbox.messages.compactMap { row($0, in: mailbox.box, account: account, own: own, place: nil) }
            }
        }
    }

    /// One person's mail in an account received in [`from`, `to`), for Nook's archive (`olderScript` asked Mail for the
    /// same): theirs from the inbox, yours to them from Sent, and what of either is in the Trash, with the start of each
    /// text by Mail's id. Nil when the index cannot be read.
    static func history(account: MailChatData.Account, address: String, from: Date, to: Date, limit: Int = 500,
                        bodyLength: Int) async -> (rows: [MailChatData.Row], trash: [MailChatData.Row], texts: [Int: String])? {
        guard let boxes = await boxes(accounts: [account.id]) else { return nil }
        let own = Set(account.addresses)
        let who = address.lowercased()
        var rows: [MailChatData.Row] = []
        var trash: [MailChatData.Row] = []
        var texts: [Int: String] = [:]
        var seen = Set<Int64>()
        for box in boxes.sorted(by: { $0.kind == .inbox && $1.kind != .inbox }) {
            let sql = MailIndex.historySQL(boxes: [box.id], address: who, from: from, to: to, limit: limit)
            guard let raw = await query(sql) else { return nil }
            for message in MailIndex.recent(raw) where seen.insert(message.id).inserted {
                guard var row = row(message, in: box, account: account, own: own, place: nil) else { continue }
                // Their mail is theirs: an inbox mail they were only copied on belongs to its sender's chat.
                if !row.fromMe, MailChatData.address(row.person) != who { continue }
                // Yours went to them, also when they were not its first recipient.
                if row.fromMe, MailChatData.address(row.person) != who { row.person = who }
                if box.kind == .trash { trash.append(row) } else { rows.append(row) }
                texts[Int(message.id)] = await text(of: message, length: bodyLength)
            }
        }
        return (rows, trash, texts)
    }

    /// The Mail connector's inbox of these accounts from the index: the unread count and the newest rows per account
    /// name, each with the start of its text.
    static func inboxRows(accounts: [MailChatData.Account], perMailbox: Int, bodyLength: Int)
        async -> [String: (unread: Int, rows: [MailStats.InboxRow])]? {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let found = await recent(accounts: Set(byID.keys), inbox: perMailbox, sent: 0) else { return nil }
        var result: [String: (unread: Int, rows: [MailStats.InboxRow])] = [:]
        for account in accounts {
            var unread = 0
            var rows: [MailStats.InboxRow] = []
            for mailbox in found[account.id] ?? [] where mailbox.box.kind == .inbox {
                unread += mailbox.unread
                for (place, message) in mailbox.messages.enumerated() {
                    rows.append(MailStats.InboxRow(account: account.name, mailbox: mailbox.box.path, index: place + 1,
                                                   subject: message.subject, sender: message.sender, date: message.date,
                                                   read: message.read, replied: message.replied,
                                                   body: await text(of: message, length: bodyLength)))
                }
            }
            result[account.name] = (unread, rows.sorted { $0.date > $1.date })
        }
        return result
    }
}
