import SwiftUI
import AppKit
import Contacts

// MARK: Apps without an API of their own

/// Messages, WhatsApp, Bear and Things keep everything in a local SQLite database. Nook reads those read-only with
/// `sqlite3`, so a question can search the whole history of an app, not only what is on screen. Messages and WhatsApp
/// need Full Disk Access for Nook; the connector says so when it is missing and stays out of searches until then.

/// Runs one read-only query on an app's database.
enum AppDatabase {
    static func query(_ path: String, _ sql: String, app: String) async throws -> [[String: Any]] {
        let output: Result<String, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: .success(try SystemControl.runProcess("/usr/bin/sqlite3", ["-readonly", "-json", path, sql], timeout: 8.0)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        switch output {
        case .success(let json):
            return AppData.rows(json)
        case .failure(let error):
            let message = error.localizedDescription.lowercased()
            if message.contains("authorization denied") || message.contains("unable to open") || message.contains("not permitted") {
                throw AppDatabase.noAccess(app)
            }
            throw NookError("\(app) kon niet gelezen worden: \(error.localizedDescription)")
        }
    }

    static func noAccess(_ app: String) -> NookError {
        NookError("Geef Nook volledige schijftoegang om \(app) te lezen: Systeeminstellingen › Privacy en beveiliging › Volledige schijftoegang.", kind: .auth)
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
}

/// Names from Contacts for phone numbers and addresses, so "wat appte Jan?" finds Jan's chats and a chat shows a name
/// instead of a number. Only when Nook already has access to Contacts; it never asks for it here.
@MainActor
enum ContactDirectory {
    struct Entry: Sendable {
        var name: String
        var handles: [String]
    }

    private static var cache: (date: Date, entries: [Entry], names: [String: String])?
    private static var loadingTask: Task<([Entry], [String: String]), Never>?

    private static func loadIfNeeded() async -> (entries: [Entry], names: [String: String]) {
        if let cache, Date().timeIntervalSince(cache.date) < 600 {
            return (cache.entries, cache.names)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return ([], [:])
        }
        if let existing = loadingTask {
            return await existing.value
        }
        let task = Task.detached(priority: .userInitiated) { () -> ([Entry], [String: String]) in
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor
            ]
            var result: [Entry] = []
            var namesMap: [String: String] = [:]
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                var name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = contact.nickname.isEmpty ? contact.organizationName : contact.nickname }
                let handles = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
                if !name.isEmpty, !handles.isEmpty {
                    result.append(Entry(name: name, handles: handles))
                    for handle in handles {
                        let key = AppData.key(handle)
                        if !key.isEmpty, namesMap[key] == nil { namesMap[key] = name }
                    }
                }
            }
            return (result, namesMap)
        }
        loadingTask = task
        let loaded = await task.value
        loadingTask = nil
        cache = (Date(), loaded.0, loaded.1)
        return loaded
    }

    static func entries() async -> [Entry] {
        (await loadIfNeeded()).entries
    }

    /// Contact name per handle key (`AppData.key`). Cached for 10 minutes alongside `entries`.
    static func names() async -> [String: String] {
        (await loadIfNeeded()).names
    }

    /// Handle keys of contacts whose name contains one of the words (at most 20).
    static func handles(matching words: [String]) async -> [String] {
        let folded = words.filter { $0.count >= 3 }.map(Research.fold)
        guard !folded.isEmpty else { return [] }
        var keys: [String] = []
        for entry in await entries() {
            let name = Research.fold(entry.name)
            guard folded.contains(where: { name.contains($0) }) else { continue }
            keys += entry.handles.map(AppData.key).filter { $0.count >= 6 }
            if keys.count >= 20 { break }
        }
        return Array(Set(keys)).sorted()
    }
}

/// A connector on top of an app's local database: on when the app is installed and switched on, off (with the reason
/// in Settings) while Nook may not read it.
@MainActor
class AppDatabaseConnector: ContextSource {
    let id: String
    let title: String
    let symbol: String
    let accent: Color
    private let bundles: [String]
    private let countSQL: String
    private let countLabel: String
    private(set) var status = ConnectorStatus()
    private var denied = false

    init(id: String, title: String, symbol: String, accent: Color, bundles: [String], countSQL: String, countLabel: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.accent = accent
        self.bundles = bundles
        self.countSQL = countSQL
        self.countLabel = countLabel
    }

    /// Where the app keeps its database (nil: not found).
    var databasePath: String? { nil }

    /// Asked on every redraw of the notch (through `isActive`): a Launch Services lookup each time adds up, so the answer
    /// is kept for a minute.
    var isInstalled: Bool {
        if let installedCheck, Date().timeIntervalSince(installedCheck.at) < 60 { return installedCheck.installed }
        let installed = bundles.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        installedCheck = (installed, Date())
        return installed
    }
    private var installedCheck: (installed: Bool, at: Date)?

    var isActive: Bool { ConnectorToggle.isOn(id) && isInstalled && !denied }
    var refreshInterval: TimeInterval { 600 }

    func refresh() async {
        guard ConnectorToggle.isOn(id) else { status = ConnectorStatus(state: .off); return }
        guard isInstalled else {
            status = ConnectorStatus(state: .off, detail: "\(title) staat niet op deze Mac.")
            return
        }
        guard let path = databasePath else {
            status = ConnectorStatus(state: .error("De gegevens van \(title) zijn niet gevonden. Open \(title) één keer en probeer het opnieuw."))
            return
        }
        do {
            let rows = try await AppDatabase.query(path, countSQL, app: title)
            denied = false
            let count = Int(AppData.number(rows.first?["n"]) ?? 0)
            status = ConnectorStatus(state: .ok, headline: "\(count) \(countLabel)", detail: "Doorzoekbaar, alleen lezen", updated: Date())
        } catch {
            denied = (error as? NookError)?.kind == .auth
            status = ConnectorStatus(state: .error(error.localizedDescription))
            status.errorKind = ConnectorErrorKind.classify(error)
        }
    }

    func contextLines() -> [String] { [] }

    var tools: [ToolSpec] { [] }

    func run(_ sql: String) async throws -> [[String: Any]] {
        guard let path = databasePath else { throw NookError("De gegevens van \(title) zijn niet gevonden.") }
        return try await AppDatabase.query(path, sql, app: title)
    }
}

// MARK: Messages (iMessage and sms)

@MainActor
final class MessagesConnector: AppDatabaseConnector {
    init() {
        super.init(id: "messages", title: "Berichten", symbol: "message.fill", accent: Color(hex: 0x34C759),
                   bundles: ["com.apple.MobileSMS"], countSQL: "SELECT count(*) AS n FROM message", countLabel: "berichten")
    }

    override var databasePath: String? { AppDatabase.home + "/Library/Messages/chat.db" }

    private static let select = """
    SELECT cmj.chat_id AS chat, COALESCE(NULLIF(c.display_name, ''), c.chat_identifier, '') AS chatname, COALESCE(h.id, '') AS handle,
           m.is_from_me AS me, m.date AS date, m.text AS text, hex(m.attributedBody) AS body
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    """

    override var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_messages",
                description: "Searches ALL iMessage and sms conversations in the Messages app (the whole history, not only what is on screen) by keywords in the text and by contact name. Returns the best matching conversations with their newest matching messages and a chat id; read a whole conversation with read_messages.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "One or more keywords or a name, separated by spaces."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Berichten zoeken: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Berichten is niet beschikbaar.") }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let words = Research.words(of: query).isEmpty ? [query] : Research.words(of: query)
                    let handles = await ContactDirectory.handles(matching: words)
                    let filter = "(" + AppData.anyLike(["m.text", "CAST(m.attributedBody AS TEXT)", "c.display_name", "h.id"], words)
                        + (handles.isEmpty ? "" : " OR " + AppData.anyLike(["h.id", "c.chat_identifier"], handles)) + ")"
                    // Fast path: scan the newest 35,000 messages first using the ROWID primary key index (~15ms).
                    // Only scan older archive history if fewer than 8 matches are found in recent messages.
                    var rows = try await self.run(Self.select + " WHERE m.ROWID > (SELECT COALESCE(MAX(ROWID), 0) - 35000 FROM message) AND \(filter) ORDER BY m.date DESC LIMIT 300")
                    if rows.count < 8 {
                        let older = try await self.run(Self.select + " WHERE m.ROWID <= (SELECT COALESCE(MAX(ROWID), 0) - 35000 FROM message) AND \(filter) ORDER BY m.date DESC LIMIT 200")
                        rows.append(contentsOf: older)
                    }
                    let messages = AppData.messages(rows, names: await ContactDirectory.names())
                    let text = AppData.formatSearch(messages, terms: Research.Terms(words: words), app: "Berichten")
                    return text.isEmpty ? "Geen berichten gevonden voor \"\(query)\"." : text
                }
            ),
            ToolSpec(
                name: "messages_open_chats",
                description: "Lists the iMessage and sms conversations that are still open: unread ones, and one-on-one conversations where the other person wrote last (waiting for the user's reply), with the newest message and a chat id. Use for \"do I have unread messages\", \"who is waiting for my reply\", \"heb ik nog berichten openstaan\".",
                schema: ["type": "object", "properties": [
                    "days": ["type": "integer", "description": "How many days back to look (default 14)."]
                ]],
                kind: .read,
                summarize: { _ in "Open gesprekken in Berichten" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Berichten is niet beschikbaar.") }
                    let days = min(max(Int(AppData.number(input["days"]) ?? 14), 1), 90)
                    // Messages counts dates in nanoseconds since 2001.
                    let since = Int64((Date().timeIntervalSinceReferenceDate - Double(days) * 86_400) * 1_000_000_000)
                    let rows = try await self.run("""
                    SELECT g.chat AS chat, g.unread AS unread, CASE WHEN c.style = 43 THEN 1 ELSE 0 END AS \"group\",
                           COALESCE(NULLIF(c.display_name, ''), c.chat_identifier, '') AS chatname, COALESCE(h.id, '') AS handle,
                           m.is_from_me AS me, m.date AS date, m.text AS text, hex(m.attributedBody) AS body
                    FROM (SELECT cmj.chat_id AS chat, MAX(m.ROWID) AS last,
                                 SUM(CASE WHEN m.is_from_me = 0 AND m.is_read = 0 THEN 1 ELSE 0 END) AS unread
                          FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                          WHERE m.ROWID > (SELECT COALESCE(MAX(ROWID), 0) - 20000 FROM message) AND m.date > \(since)
                                AND COALESCE(m.associated_message_type, 0) = 0
                          GROUP BY cmj.chat_id) g
                    JOIN message m ON m.ROWID = g.last
                    JOIN chat c ON c.ROWID = g.chat
                    LEFT JOIN handle h ON h.ROWID = m.handle_id
                    ORDER BY m.date DESC LIMIT 60
                    """)
                    let chats = AppData.openChats(rows, names: await ContactDirectory.names())
                    return AppData.formatOpenChats(chats, app: "Berichten", days: days)
                }
            ),
            ToolSpec(
                name: "read_messages",
                description: "Reads one conversation from the Messages app: the messages around those that match the keywords, plus the most recent ones, in time order. Give the chat id from search_messages.",
                schema: ["type": "object", "properties": [
                    "chat": ["type": "string", "description": "The chat id from search_messages."],
                    "query": ["type": "string", "description": "Keywords to show the passages about. Optional."]
                ], "required": ["chat"]],
                kind: .read,
                summarize: { _ in "Gesprek lezen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Berichten is niet beschikbaar.") }
                    guard let chat = Int(AppData.string(input["chat"]).trimmingCharacters(in: .whitespaces)) else { throw NookError("Het chat-id ontbreekt.") }
                    let rows = try await self.run(Self.select + " WHERE cmj.chat_id = \(chat) ORDER BY m.date DESC LIMIT 500")
                    let messages = AppData.messages(rows, names: await ContactDirectory.names())
                    guard !messages.isEmpty else { throw NookError("Dit gesprek is niet gevonden of heeft geen tekst.") }
                    return AppData.formatThread(messages, terms: Research.Terms(words: Research.words(of: AppData.string(input["query"]))), app: "Berichten")
                }
            )
        ]
    }
}

// MARK: WhatsApp

@MainActor
final class WhatsAppConnector: AppDatabaseConnector {
    init() {
        super.init(id: "whatsapp", title: "WhatsApp", symbol: "bubble.left.and.bubble.right.fill", accent: Color(hex: 0x25D366),
                   bundles: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], countSQL: "SELECT count(*) AS n FROM ZWAMESSAGE", countLabel: "berichten")
    }

    override var databasePath: String? {
        let path = AppDatabase.home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static let select = """
    SELECT m.ZCHATSESSION AS chat, COALESCE(s.ZPARTNERNAME, '') AS chatname, COALESCE(m.ZFROMJID, '') AS handle,
           m.ZISFROMME AS me, m.ZMESSAGEDATE AS date, m.ZTEXT AS text, '' AS body
    FROM ZWAMESSAGE m
    LEFT JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
    """

    /// WhatsApp counts as on when its data on this Mac can be read, or when the phone is linked through the gateway.
    override var isActive: Bool { super.isActive || WhatsAppLink.shared.isConnected }

    override func contextLines() -> [String] {
        let link = WhatsAppLink.shared
        guard link.isConnected else { return [] }
        var lines = ["WhatsApp is linked live (the user's phone through a local gateway): read chats with whatsapp_live, send with whatsapp_send (the user approves first)."]
        let unread = link.inbox.visible(filters: link.filters).filter { $0.unread > 0 }
        if !unread.isEmpty {
            lines.append("Unread WhatsApp chats:\n" + WhatsAppRecipients.overview(unread, limit: 6))
        }
        return lines
    }

    override var tools: [ToolSpec] {
        let live = WhatsAppLink.shared.isConnected ? liveTools : []
        // Without access to WhatsApp's data on this Mac only the linked phone is there.
        return super.isActive || !WhatsAppLink.shared.isConnected ? databaseTools + live : live
    }

    private var liveTools: [ToolSpec] {
        [
            ToolSpec(
                name: "whatsapp_live",
                description: "WhatsApp through the user's linked phone (live, includes what arrived a minute ago). Without chat: the recent conversations with unread counts and the newest message. With chat (a name, number or chat id): the newest messages of that chat.",
                schema: ["type": "object", "properties": [
                    "chat": ["type": "string", "description": "Name, phone number or chat id. Leave empty for the overview."],
                    "limit": ["type": "integer", "description": "How many messages of the chat (default 20, at most 50)."]
                ]],
                kind: .read,
                summarize: { input in
                    let chat = AppData.string(input["chat"]).trimmingCharacters(in: .whitespaces)
                    return chat.isEmpty ? "WhatsApp: recente chats" : "WhatsApp: chat met \(chat)"
                },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let link = WhatsAppLink.shared
                    let chat = AppData.string(input["chat"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !chat.isEmpty else {
                        let conversations = link.inbox.visible(filters: link.filters)
                        if conversations.isEmpty {
                            let names = link.knownChats.prefix(15).map(\.name).filter { !$0.isEmpty }
                            return names.isEmpty ? "No recent WhatsApp messages in the last 12 hours."
                                : "No new WhatsApp messages in the last 12 hours. Recent chats: " + names.joined(separator: ", ") + "."
                        }
                        return "Recent WhatsApp conversations (newest first):\n" + WhatsAppRecipients.overview(conversations)
                    }
                    guard let target = link.resolve(chat) else {
                        throw NookError(tr("whatsapp.reply.unknown", chat, link.knownChats.prefix(12).map(\.name).joined(separator: ", ")))
                    }
                    let limit = min(max(Int(AppData.number(input["limit"]) ?? 20), 1), 50)
                    let messages = try await link.messages(of: target.jid, limit: limit)
                    guard !messages.isEmpty else { return "No messages found in the WhatsApp chat with \(target.name)." }
                    return "WhatsApp chat with \(target.name) (chat id \(target.jid)):\n" + WhatsAppRecipients.lines(messages, chatName: target.name)
                }
            ),
            ToolSpec(
                name: "whatsapp_send",
                description: "Sends a WhatsApp message from the user's own account to an existing chat (a contact or group on their phone), through the linked phone. Use when the user asks to app, WhatsApp or message someone on WhatsApp. Write the message as the user would, in their language and tone, without a signature. The user sees the exact text and recipient and approves before anything is sent.",
                schema: ["type": "object", "properties": [
                    "to": ["type": "string", "description": "The chat: a contact or group name as on the phone, a phone number, or a chat id from whatsapp_live."],
                    "message": ["type": "string", "description": "The full text to send."]
                ], "required": ["to", "message"]],
                kind: .action,
                summarize: { input in
                    let to = AppData.string(input["to"]).trimmingCharacters(in: .whitespaces)
                    return "WhatsApp → \(to): \(AppData.string(input["message"]))"
                },
                tag: { _ in ("sends", .caution) },
                run: { input in
                    let to = AppData.string(input["to"])
                    let name = try await WhatsAppLink.shared.send(AppData.string(input["message"]), to: to)
                    return "WhatsApp message sent to \(name)."
                }
            )
        ]
    }

    private var databaseTools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_whatsapp",
                description: "Searches ALL WhatsApp chats on this Mac (the whole history, not only what is on screen) by keywords in the text and by chat or contact name. Returns the best matching chats with their newest matching messages and a chat id; read a whole chat with read_whatsapp.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "One or more keywords or a name, separated by spaces."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "WhatsApp zoeken: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("WhatsApp is niet beschikbaar.") }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let words = Research.words(of: query).isEmpty ? [query] : Research.words(of: query)
                    let handles = await ContactDirectory.handles(matching: words)
                    let filter = AppData.anyLike(["m.ZTEXT", "s.ZPARTNERNAME"], words)
                        + (handles.isEmpty ? "" : " OR " + AppData.anyLike(["m.ZFROMJID", "s.ZCONTACTJID"], handles))
                    let rows = try await self.run(Self.select + " WHERE m.ZTEXT IS NOT NULL AND (\(filter)) ORDER BY m.ZMESSAGEDATE DESC LIMIT 300")
                    let messages = AppData.messages(rows, names: await ContactDirectory.names())
                    let text = AppData.formatSearch(messages, terms: Research.Terms(words: words), app: "WhatsApp")
                    return text.isEmpty ? "Geen WhatsApp-berichten gevonden voor \"\(query)\"." : text
                }
            ),
            ToolSpec(
                name: "whatsapp_open_chats",
                description: "Lists the WhatsApp chats that are still open: unread ones (also chats marked as unread), and one-on-one chats where the other person wrote last (waiting for the user's reply), with the newest message and a chat id. Use for \"do I have open/unread WhatsApp chats\", \"who is waiting for my reply\", \"heb ik chats openstaan in WhatsApp\".",
                schema: ["type": "object", "properties": [
                    "days": ["type": "integer", "description": "How many days back to look (default 14)."]
                ]],
                kind: .read,
                summarize: { _ in "Open chats in WhatsApp" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("WhatsApp is niet beschikbaar.") }
                    let days = min(max(Int(AppData.number(input["days"]) ?? 14), 1), 90)
                    // WhatsApp counts dates in seconds since 2001.
                    let since = Int(Date().timeIntervalSinceReferenceDate) - days * 86_400
                    let rows = try await self.run("""
                    SELECT s.Z_PK AS chat, COALESCE(s.ZPARTNERNAME, '') AS chatname, COALESCE(s.ZUNREADCOUNT, 0) AS unread,
                           CASE WHEN s.ZSESSIONTYPE = 1 OR s.ZCONTACTJID LIKE '%@g.us' THEN 1 ELSE 0 END AS \"group\",
                           COALESCE(m.ZFROMJID, '') AS handle, COALESCE(m.ZISFROMME, 0) AS me,
                           COALESCE(m.ZMESSAGEDATE, s.ZLASTMESSAGEDATE) AS date, COALESCE(m.ZTEXT, '') AS text, '' AS body
                    FROM ZWACHATSESSION s
                    LEFT JOIN ZWAMESSAGE m ON m.Z_PK = (SELECT x.Z_PK FROM ZWAMESSAGE x WHERE x.ZCHATSESSION = s.Z_PK ORDER BY x.ZMESSAGEDATE DESC LIMIT 1)
                    WHERE s.ZLASTMESSAGEDATE > \(since) AND COALESCE(s.ZARCHIVED, 0) = 0
                          AND COALESCE(s.ZCONTACTJID, '') NOT LIKE '%broadcast%'
                    ORDER BY s.ZLASTMESSAGEDATE DESC LIMIT 60
                    """)
                    let chats = AppData.openChats(rows, names: await ContactDirectory.names())
                    return AppData.formatOpenChats(chats, app: "WhatsApp", days: days)
                }
            ),
            ToolSpec(
                name: "read_whatsapp",
                description: "Reads one WhatsApp chat: the messages around those that match the keywords, plus the most recent ones, in time order. Give the chat id from search_whatsapp.",
                schema: ["type": "object", "properties": [
                    "chat": ["type": "string", "description": "The chat id from search_whatsapp."],
                    "query": ["type": "string", "description": "Keywords to show the passages about. Optional."]
                ], "required": ["chat"]],
                kind: .read,
                summarize: { _ in "WhatsApp-chat lezen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("WhatsApp is niet beschikbaar.") }
                    guard let chat = Int(AppData.string(input["chat"]).trimmingCharacters(in: .whitespaces)) else { throw NookError("Het chat-id ontbreekt.") }
                    let rows = try await self.run(Self.select + " WHERE m.ZCHATSESSION = \(chat) AND m.ZTEXT IS NOT NULL ORDER BY m.ZMESSAGEDATE DESC LIMIT 500")
                    let messages = AppData.messages(rows, names: await ContactDirectory.names())
                    guard !messages.isEmpty else { throw NookError("Deze chat is niet gevonden of heeft geen tekst.") }
                    return AppData.formatThread(messages, terms: Research.Terms(words: Research.words(of: AppData.string(input["query"]))), app: "WhatsApp")
                }
            )
        ]
    }
}

// MARK: Bear

@MainActor
final class BearConnector: AppDatabaseConnector {
    init() {
        super.init(id: "bear", title: "Bear", symbol: "pawprint.fill", accent: Color(hex: 0xDD4C4F),
                   bundles: ["net.shinyfrog.bear"], countSQL: "SELECT count(*) AS n FROM ZSFNOTE WHERE ZTRASHED = 0", countLabel: "notities")
    }

    override var databasePath: String? {
        let path = AppDatabase.home + "/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    override var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_bear",
                description: "Searches ALL notes in Bear by keywords in the title and the whole text, best matches first, with the start of each note and its id. Read a whole note with read_bear.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "One or more keywords, separated by spaces."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Bear doorzoeken: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Bear is niet beschikbaar.") }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let words = Research.words(of: query).isEmpty ? [query] : Research.words(of: query)
                    let rows = try await self.run("""
                    SELECT ZUNIQUEIDENTIFIER AS id, ZTITLE AS title, ZMODIFICATIONDATE AS date, substr(ZTEXT, 1, 800) AS text FROM ZSFNOTE
                    WHERE ZTRASHED = 0 AND \(AppData.anyLike(["ZTITLE", "ZTEXT"], words)) ORDER BY ZMODIFICATIONDATE DESC LIMIT 60
                    """)
                    let text = AppData.formatNotes(rows, terms: Research.Terms(words: words), app: "Bear")
                    return text.isEmpty ? "Geen Bear-notities gevonden voor \"\(query)\"." : text
                }
            ),
            ToolSpec(
                name: "read_bear",
                description: "Reads the full text of one Bear note. Give the id from search_bear.",
                schema: ["type": "object", "properties": [
                    "id": ["type": "string", "description": "The note id from search_bear."]
                ], "required": ["id"]],
                kind: .read,
                summarize: { _ in "Bear-notitie lezen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Bear is niet beschikbaar.") }
                    let id = AppData.string(input["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { throw NookError("Het id van de notitie ontbreekt.") }
                    let rows = try await self.run("SELECT ZTITLE AS title, ZMODIFICATIONDATE AS date, ZTEXT AS text FROM ZSFNOTE WHERE ZUNIQUEIDENTIFIER = \(AppData.literal(id)) LIMIT 1")
                    guard let row = rows.first else { throw NookError("Deze Bear-notitie is niet gevonden.") }
                    let title = AppData.string(row["title"])
                    let date = AppData.number(row["date"]).map { AppData.stamp(AppData.appleDate($0), time: false) } ?? ""
                    var body = AppData.string(row["text"])
                    if body.count > 15_000 { body = String(body.prefix(15_000)) + "\n… (ingekort: de eerste 15.000 tekens)" }
                    return "## Bear: \(title) (\(date))\n\n\(body)\n\n" + ReferenceParser.line(title: title, url: nil, detail: "Bear · \(date)")
                }
            )
        ]
    }
}

// MARK: Things

@MainActor
final class ThingsConnector: AppDatabaseConnector {
    init() {
        super.init(id: "things", title: "Things", symbol: "checkmark.square.fill", accent: Color(hex: 0x3C8CE7),
                   bundles: ["com.culturedcode.ThingsMac"], countSQL: "SELECT count(*) AS n FROM TMTask WHERE trashed = 0 AND status = 0", countLabel: "open taken")
    }

    override var databasePath: String? {
        let root = AppDatabase.home + "/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac"
        let file = "Things Database.thingsdatabase/main.sqlite"
        let manager = FileManager.default
        // Things 3.15 and later keep the database in a folder "ThingsData-…".
        let folders = ((try? manager.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("ThingsData") }.sorted()
        for folder in folders.reversed() where manager.fileExists(atPath: "\(root)/\(folder)/\(file)") { return "\(root)/\(folder)/\(file)" }
        return manager.fileExists(atPath: "\(root)/\(file)") ? "\(root)/\(file)" : nil
    }

    override var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_things",
                description: "Searches ALL to-dos and projects in Things (open and done) by keywords in the title and notes, with status, project and area.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "One or more keywords, separated by spaces."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Things doorzoeken: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Things is niet beschikbaar.") }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let words = Research.words(of: query).isEmpty ? [query] : Research.words(of: query)
                    let rows = try await self.run("""
                    SELECT t.title AS title, t.notes AS notes, t.status AS status, t.type AS type,
                           COALESCE(p.title, '') AS project, COALESCE(a.title, '') AS area
                    FROM TMTask t LEFT JOIN TMTask p ON p.uuid = t.project LEFT JOIN TMArea a ON a.uuid = t.area
                    WHERE t.trashed = 0 AND \(AppData.anyLike(["t.title", "t.notes"], words))
                    ORDER BY t.status ASC, t.userModificationDate DESC LIMIT 60
                    """)
                    let text = AppData.formatTasks(rows, terms: Research.Terms(words: words))
                    return text.isEmpty ? "Geen taken in Things gevonden voor \"\(query)\"." : text
                }
            )
        ]
    }
}
