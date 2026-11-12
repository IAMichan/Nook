import AppKit

/// Mail in the Chats tab, read from the Mail app on this Mac: every account in it (iCloud, Gmail, Outlook and Exchange,
/// Yahoo, any IMAP or POP account), so every kind of mail you have lands in one place, each account's chats side by
/// side and named by account. A chat is one person in one account: their mail from its inbox, yours from its Sent
/// mailbox (`MailChatData`). Nook reads while Mail is open, as the Mail connector does, and never starts Mail itself
/// in the background. An answer goes out through Mail as a reply to the newest mail of the chat (`MailSender`), after
/// your own Return; "Mark as read" marks the chat's mail read in Mail, which tells the server. Mail has no emoji,
/// edits, polls or pinning another app can reach, so those stay in Mail.
@MainActor
final class MailBridge: ChatBridge, ObservableObject {
    let app = MailChatData.app
    /// Mail keeps itself up to date; reading it more often only keeps it busy. Each round first asks for `MailChangeMark`
    /// and reads every account only when it changed (`MailStats.needsFullRead`).
    let interval: TimeInterval = 60
    /// The mark at the last full read, and when that was. Cleared after Nook itself changed something in Mail (an
    /// answer sent, mail marked read), so the next round reads it whatever the mark says.
    private var lastMark: String?
    private var lastFullRead: Date?
    /// A round that reads nothing returns no chats: the inbox keeps what the last full read brought.
    private static let fullReadMaxAge: TimeInterval = 10 * 60
    /// While you work in Mail itself, its unread count changes with every mail you open: a full read then waits this long.
    private static let frontGap: TimeInterval = 2 * 60
    private(set) var isWorking = false
    /// The enabled accounts at the last read.
    @Published private(set) var accounts: [MailChatData.Account] = []

    /// You linked Mail in Settings › Chats: until then Nook does not ask Mail for anything (that asks for permission
    /// under Automation the first time). Kept across launches.
    @Published private(set) var isLinked = UserDefaults.standard.bool(forKey: MailBridge.linkedKey)
    private static let linkedKey = "chats.mail.linked"

    /// Bodies already read, by Mail's id: a message's text does not change, so it is read once.
    private var bodies: [Int: String] = [:]
    private static let bodiesKept = 2_000
    /// New bodies read per round: the rest follow at the next, so one read never keeps Mail busy for long (Mail answers
    /// one script at a time, and a mail you open waits behind it).
    private static let bodiesPerRead = 10
    /// What each chat (by its `chatID`) needs to answer and to mark read or unread: whom, from which address, the newest
    /// subject, its unread messages, and its newest mail from someone else.
    private struct Target {
        var address: String
        var from: String
        var subject: String
        var unread: [MailChatData.Row]
        var newestIncoming: MailChatData.Row?
    }
    private var targets: [String: Target] = [:]
    /// Where each message read last lives in Mail, by Mail's id: to read it whole, fast, when you open it. A mail not
    /// in it is looked for by its id (`MailChatData.findScript`).
    private var places: [Int: MailChatData.Row] = [:]
    /// Whole messages already read, by Mail's id: a message does not change.
    private var opened: [Int: MailChatData.Message] = [:]
    private static let openedKept = 200

    var isReady: Bool { isLinked && ScriptText.isRunning(MailSender.mailBundleID) }

    /// Links Mail from the Chats tab or Settings and reads it at once: Mail is started out of sight when it is closed,
    /// so the first chats show right away instead of the next time you open Mail.
    func linkAndRead() async throws {
        setLinked(true)
        try await MailConnector.ensureRunning()
    }

    func setLinked(_ linked: Bool) {
        UserDefaults.standard.set(linked, forKey: Self.linkedKey)
        if isLinked != linked { isLinked = linked }
        if !linked { reset() }
    }

    func read() async throws -> [BridgedChat] {
        let mark = await MailChangeMark.current()
        guard MailStats.needsFullRead(mark: mark, lastMark: lastMark, lastRead: lastFullRead, now: Date(),
                                      maxAge: Self.fullReadMaxAge, minGap: MailChangeMark.mailIsFront ? Self.frontGap : 0)
        else { return [] }
        do {
            let list = await ScriptText.run(MailChatData.accountsScript, timeout: 10)
            guard let text = list.text else { throw problem(list.errorNumber, list.errorMessage, timeout: 10) }
            let found = MailChatData.accounts(text)
            if found != accounts { accounts = found }
            var rows: [MailChatData.Row] = []
            var failure: NookError?
            // Each account on its own: one that syncs a big mailbox never keeps the others from showing.
            for account in found {
                let result = await ScriptText.run(MailChatData.readScript(account: account.name), timeout: 20)
                guard let raw = result.text else {
                    failure = failure ?? problem(result.errorNumber, result.errorMessage, timeout: 20)
                    continue
                }
                rows += MailChatData.rows(raw, account: account)
            }
            // Not one account could be read: say why, instead of an empty list that looks like there is no mail.
            if rows.isEmpty, let failure { throw failure }
            await readBodies(of: rows)
            let chats = MailChatData.chats(rows, accounts: found, bodies: bodies, named: found.count > 1)
            remember(chats, rows: rows, accounts: found)
            // An account that could not be read is tried again next round, not only once the mark changes.
            if failure == nil {
                lastMark = mark
                lastFullRead = Date()
            }
            isWorking = true
            return chats
        } catch {
            isWorking = false
            throw error
        }
    }

    /// Reads the start of the text of the newest messages not read before, a batch per round.
    private func readBodies(of rows: [MailChatData.Row]) async {
        let missing = rows.filter { bodies[$0.id] == nil }.sorted { $0.date > $1.date }.prefix(Self.bodiesPerRead)
        guard !missing.isEmpty else { return }
        let result = await ScriptText.run(MailChatData.bodiesScript(Array(missing)), timeout: 15)
        guard let raw = result.text else { return }
        for (id, body) in MailStats.bodies(raw) { bodies[id] = body }
        // A message Mail gave no text for still gets an entry, so it is not asked for again each round.
        for row in missing where bodies[row.id] == nil { bodies[row.id] = "" }
        if bodies.count > Self.bodiesKept {
            let keep = Set(rows.map(\.id))
            bodies = bodies.filter { keep.contains($0.key) }
        }
    }

    private func remember(_ chats: [BridgedChat], rows: [MailChatData.Row], accounts: [MailChatData.Account]) {
        places = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byChat: [String: [MailChatData.Row]] = [:]
        for row in rows {
            byChat[MailChatData.chatID(account: row.account, address: MailChatData.address(row.person)), default: []].append(row)
        }
        var made: [String: Target] = [:]
        for chat in chats {
            guard let id = chat.chatID, let rows = byChat[id] else { continue }
            let newest = rows.max { $0.date < $1.date }
            let account = accounts.first { $0.name == newest?.account }
            made[id] = Target(address: MailChatData.address(newest?.person ?? ""), from: account?.addresses.first ?? "",
                              subject: rows.filter { !$0.fromMe }.max { $0.date < $1.date }?.subject ?? newest?.subject ?? "",
                              unread: rows.filter { !$0.fromMe && !$0.read },
                              newestIncoming: rows.filter { !$0.fromMe }.max { $0.date < $1.date })
        }
        targets = made
    }

    /// Why Mail gave no answer: no permission under Automation says how to give it; anything else as the Mail connector
    /// says it.
    fileprivate func problem(_ number: Int?, _ message: String?, timeout: TimeInterval) -> NookError {
        if number == -1743 { return NookError(tr("chats.mail.noPermission")) }
        return NookError(MailStats.failure(errorNumber: number, message: message, timeout: timeout))
    }

    // MARK: Reading one message

    /// Whether the mail view can read this message (its id in Nook) whole from Mail.
    func canOpen(_ nookID: String) -> Bool {
        MailChatData.mailID(nookID) != nil
    }

    /// How long one mail may take to come from Mail: its text may still have to come from the server.
    private static let openTimeout: TimeInterval = 30
    /// How long looking for a mail in every mailbox may take: a search through a large mailbox is slow.
    private static let findTimeout: TimeInterval = 60
    /// Mail's "can't get message": the mail is no longer where it was read.
    private static let notThere = -1728

    /// The whole message (headers, attachments, all of its text), read from Mail the first time it opens in the mail
    /// view and kept after that, found at its place in its mailbox (`MailChatData.locate`), or by its id in every mailbox
    /// when Nook has no place for it (`MailChatData.findScript`). Throws a sentence that says why when it cannot: Mail is
    /// closed, Mail no longer has the mail, or Mail did not answer in time.
    func message(_ nookID: String) async throws -> MailChatData.Message {
        guard let id = MailChatData.mailID(nookID) else { throw NookError(tr("chats.mail.notFound")) }
        if let kept = opened[id] { return kept }
        guard ScriptText.isRunning(MailSender.mailBundleID) else { throw NookError(tr("chats.mail.openMail")) }
        var result: (text: String?, errorNumber: Int?, errorMessage: String?)?
        var timeout = Self.openTimeout
        // Its attachments are saved with it, so the mail view shows them as themselves (`MailChatData.messageScript`).
        let folder = ChatMedia.destination(key: "mail-\(id)", name: "file").deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let row = places[id] {
            result = await ScriptText.run(MailChatData.messageScript(row, saveTo: folder.path), timeout: timeout)
        }
        // No place for it (a mail from an earlier read or launch), or no longer at its place (it moved): looked for by
        // its id in every mailbox, instead of a mail view that can only say to wait for the next read.
        if result == nil || result?.errorNumber == Self.notThere {
            timeout = Self.findTimeout
            result = await ScriptText.run(MailChatData.findScript(id, saveTo: folder.path), timeout: timeout)
        }
        guard let raw = result?.text else {
            throw problem(result?.errorNumber, result?.errorMessage, timeout: timeout)
        }
        guard var message = MailChatData.message(raw) else { throw NookError(tr("chats.mail.gone")) }
        message.files = await Self.collect(message.files, into: folder)
        if opened.count >= Self.openedKept { opened = [:] }
        opened[id] = message
        // Its text is kept for the conversation too, so the line under a folded mail shows it.
        if bodies[id]?.isEmpty ?? true { bodies[id] = String(message.body.prefix(MailChatData.bodyLength)) }
        return message
    }

    /// The attachments Mail saved, all in `folder`: one Mail had to put in its own temporary folder (its sandbox) is
    /// moved here, so it stays readable and goes with the chat's other files. Empty for one that could not be.
    private static func collect(_ files: [String], into folder: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            files.map { path -> String in
                guard !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else { return "" }
                let url = URL(fileURLWithPath: path)
                guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return path }
                let target = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil
                    || (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                    return target.path
                }
                return path
            }
        }.value
    }

    /// Every address of yours across the accounts, lower case: an answer to everyone leaves them out.
    var ownAddresses: Set<String> { Set(accounts.flatMap(\.addresses)) }

    /// The address a new mail in this chat goes from: the address of the account the chat is in; empty for Mail's
    /// default account.
    func sender(for chatID: String?) -> String {
        chatID.flatMap { targets[$0]?.from } ?? ""
    }

    // MARK: Answering

    func canSend(chatID: String) -> Bool { isReady && targets[chatID] != nil }

    /// Your text as an answer to the chat's newest mail, from the account the chat is in, after your own Return; the
    /// chat is read again right after, and your mail shows from Sent.
    func send(text: String, to chatID: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard let target = targets[chatID] else { throw NookError(tr("chats.mail.notFound")) }
        let draft = MailDraft(to: target.address, cc: "", subject: MailChatData.replySubject(target.subject), body: body,
                              from: target.from)
        try await MailSender.deliver(draft, send: true)
        changedInMail()
    }

    /// What Mail sends besides text: any file, attached to the answer (a photo, a video, a voice message, a document),
    /// and a place or a contact as text. Mail has no polls.
    var sends: Set<ChatOutgoing.Kind> { ChatOutgoing.Kind.noPolls }

    /// A file as an answer to the chat's newest mail, attached, with its caption as the text; a place or a contact as
    /// text. From the account the chat is in, after your own click.
    func send(_ outgoing: ChatOutgoing, to chatID: String) async throws {
        guard let target = targets[chatID] else { throw NookError(tr("chats.mail.notFound")) }
        var attachments: [String] = []
        if case .file(let file) = outgoing { attachments = [file.path] }
        let body = outgoing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachments.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        let draft = MailDraft(to: target.address, cc: "", subject: MailChatData.replySubject(target.subject), body: body,
                              from: target.from, attachments: attachments)
        try await MailSender.deliver(draft, send: true)
        changedInMail()
    }

    /// Nook changed something in Mail: the next round reads it in full, so it shows at once.
    private func changedInMail() {
        lastFullRead = nil
        MailChangeMark.invalidate()
    }

    /// Marks the chat's unread mail read in Mail, which tells the server, so it is read on your other devices too.
    func markRead(chatID: String) async throws {
        guard let target = targets[chatID] else { throw NookError(tr("chats.mail.notFound")) }
        guard !target.unread.isEmpty else { return }
        let result = await ScriptText.run(MailChatData.markReadScript(target.unread), timeout: 15)
        if result.errorNumber != nil { throw problem(result.errorNumber, result.errorMessage, timeout: 15) }
        targets[chatID]?.unread = []
        changedInMail()
    }

    /// Marks the chat's newest mail from someone else unread in Mail, as Mail's own "Mark as Unread" does: the server
    /// hears it, so it waits on your other devices too.
    func markUnread(chatID: String) async throws {
        guard let newest = targets[chatID]?.newestIncoming else { throw NookError(tr("chats.mail.notFound")) }
        let result = await ScriptText.run(MailChatData.markReadScript([newest], read: false), timeout: 15)
        if result.errorNumber != nil { throw problem(result.errorNumber, result.errorMessage, timeout: 15) }
        targets[chatID]?.unread = [newest]
        changedInMail()
    }

    /// Forgets what was read, after you unlinked Mail.
    private func reset() {
        bodies = [:]
        targets = [:]
        places = [:]
        opened = [:]
        accounts = []
        isWorking = false
        lastMark = nil
        lastFullRead = nil
    }
}

// MARK: Nook's archive

/// Mail fills Nook's archive too (`ChatBackfill`): each person's older mail, a stretch of time at a time, back to their
/// first mail. Mail has no edits, and deleting a mail in Mail moves it (to the Trash, an archive): nothing there says
/// it was deleted for the other person, so Mail's messages are never marked "Deleted".
extension MailBridge: ChatBackfillBridge {
    var historyChanges: Bool { false }
    var backfillEmptyIsStart: Bool { true }

    /// Not while you work in Mail itself: Mail answers one script at a time, and the mail you open would wait.
    func canBackfill(chatID: String) -> Bool {
        isReady && !MailChangeMark.mailIsFront && MailChatData.parts(of: chatID, accounts: accounts) != nil
    }

    /// The person's mail before `before`: the first stretch back that holds any (`MailChatData.olderStretches`), all of
    /// it, so the page covers its stretch whole. Empty once there is none left.
    func backfill(chatID: String, before: Date, limit: Int) async throws -> [InboxMessage] {
        guard let (account, address) = MailChatData.parts(of: chatID, accounts: accounts) else { return [] }
        for stretch in MailChatData.olderStretches(before: before) {
            let result = await ScriptText.run(MailChatData.olderScript(account: account.name, address: address,
                                                                       from: stretch.from, to: stretch.to), timeout: 60)
            guard let raw = result.text else { throw problem(result.errorNumber, result.errorMessage, timeout: 60) }
            let rows = MailChatData.rows(raw, account: account).filter { $0.date < before }
            guard !rows.isEmpty else { continue }
            let texts = MailStats.bodies(raw)
            let chats = MailChatData.chats(rows, accounts: accounts, bodies: texts, named: accounts.count > 1)
            return chats.first { $0.chatID == chatID }?.messages ?? []
        }
        return []
    }
}

/// `MailStats.changeScript`, asked once for both readers of Mail (the Chats tab and the Mail connector) when they come
/// close together, so the quick question is not asked twice either.
@MainActor
enum MailChangeMark {
    private static var last: (mark: String, at: Date)?
    private static let reuse: TimeInterval = 10

    /// The mark, or nil when Mail did not answer in time.
    static func current() async -> String? {
        if let last, Date().timeIntervalSince(last.at) < reuse { return last.mark }
        let mark = await ScriptText.run(MailStats.changeScript, timeout: 5).text
        last = mark.map { ($0, Date()) }
        return mark
    }

    /// Nook changed something in Mail itself: the next question goes to Mail.
    static func invalidate() { last = nil }

    /// You are working in Mail now.
    static var mailIsFront: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == MailSender.mailBundleID }
}
