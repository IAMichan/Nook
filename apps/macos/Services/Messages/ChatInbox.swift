import Foundation

// Every chat in one place: what Telegram, Instagram, Messenger, Signal, Messages and the other chat apps show as a
// notification on this Mac lands in one inbox, next to the chats of a linked WhatsApp. macOS keeps the notifications it
// showed in a database of its own (`NotificationRecord`); `ChatCaptureService` reads the new ones from there, read-only,
// and this file decides which of them are chat messages and which chat they belong to. Foundation only, so it can be
// tested anywhere.

/// A chat app whose notifications Nook collects.
struct MessagingApp: Equatable, Sendable, Identifiable {
    /// The source id, as `SourceBrand` and `EmbeddedAppCatalog` use it ("telegram").
    let id: String
    let name: String
    /// Its Mac apps: their notifications are its messages.
    var bundleIDs: [String] = []
    /// Its web versions: a browser's notification from one of these sites is its message.
    var domains: [String] = []
    /// The website whose icon stands for it while its Mac app is not on this Mac.
    var site: String? = nil
}

enum MessagingApps {
    static let all: [MessagingApp] = [
        MessagingApp(id: "whatsapp", name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "net.whatsapp.WhatsAppSMB"],
                     domains: ["web.whatsapp.com"], site: "whatsapp.com"),
        MessagingApp(id: "telegram", name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram"],
                     domains: ["web.telegram.org"], site: "telegram.org"),
        MessagingApp(id: "instagram", name: "Instagram", bundleIDs: ["com.burbn.instagram"], domains: ["instagram.com"], site: "instagram.com"),
        MessagingApp(id: "messenger", name: "Messenger", bundleIDs: ["com.facebook.archon", "com.facebook.archon.developerID"],
                     domains: ["messenger.com"], site: "messenger.com"),
        MessagingApp(id: "signal", name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"], site: "signal.org"),
        MessagingApp(id: "messages", name: "Messages", bundleIDs: ["com.apple.MobileSMS", "com.apple.iChat"]),
        MessagingApp(id: "slack", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], domains: ["app.slack.com"], site: "slack.com"),
        MessagingApp(id: "discord", name: "Discord", bundleIDs: ["com.hnc.Discord"], domains: ["discord.com"], site: "discord.com"),
        MessagingApp(id: "teams", name: "Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], domains: ["teams.microsoft.com"], site: "teams.microsoft.com"),
        MessagingApp(id: "googlechat", name: "Google Chat", domains: ["chat.google.com"], site: "chat.google.com"),
        MessagingApp(id: "snapchat", name: "Snapchat", domains: ["snapchat.com"], site: "snapchat.com"),
        MessagingApp(id: "viber", name: "Viber", bundleIDs: ["com.viber.osx"], site: "viber.com"),
        MessagingApp(id: "wechat", name: "WeChat", bundleIDs: ["com.tencent.xinWeChat"], site: "wechat.com"),
        MessagingApp(id: "line", name: "LINE", bundleIDs: ["jp.naver.line.mac"], site: "line.me"),
        MessagingApp(id: "skype", name: "Skype", bundleIDs: ["com.skype.skype"], site: "skype.com"),
        MessagingApp(id: "element", name: "Element", bundleIDs: ["im.riot.app"], domains: ["app.element.io"], site: "element.io"),
        MessagingApp(id: "threema", name: "Threema", bundleIDs: ["ch.threema.threema-desktop", "ch.threema.iapp"], site: "threema.ch"),
        MessagingApp(id: "wire", name: "Wire", bundleIDs: ["com.wearezeta.zclient.mac"], site: "wire.com"),
        MessagingApp(id: "beeper", name: "Beeper", bundleIDs: ["com.automattic.beeper.desktop"], site: "beeper.com")
    ]

    static func app(id: String) -> MessagingApp? {
        all.first { $0.id == id }
    }

    static func app(bundleID: String) -> MessagingApp? {
        let wanted = bundleID.lowercased()
        return all.first { $0.bundleIDs.contains { $0.lowercased() == wanted } }
    }

    /// Browsers (and Safari's web apps in the Dock), whose notifications come from a website: the site says which app.
    static func isBrowser(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return ["com.apple.safari", "com.google.chrome", "company.thebrowser", "com.brave.browser", "com.microsoft.edgemac",
                "org.mozilla.firefox", "com.operasoftware.opera", "com.vivaldi.vivaldi", "app.zen-browser"].contains { id.hasPrefix($0) }
    }

    /// The chat app a browser's notification is from: a site of it in the subtitle (where Chrome puts the site), the
    /// title or the text, or the app's own name as the title ("Instagram").
    static func app(mentionedIn fields: [String]) -> MessagingApp? {
        for field in fields {
            let text = field.lowercased()
            guard !text.isEmpty else { continue }
            if let app = all.first(where: { $0.domains.contains { domain in mentions(text, domain) } }) { return app }
        }
        let title = fields.first { !$0.isEmpty }?.lowercased() ?? ""
        return all.first { !$0.domains.isEmpty && $0.name.lowercased() == title }
    }

    /// "instagram.com" in "www.instagram.com" or "https://instagram.com/direct", not in "notinstagram.com".
    private static func mentions(_ text: String, _ domain: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: domain, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let boundaryBefore = before == nil || before == "." || before == "/" || before == " " || before == "("
            let boundaryAfter = after == nil || !(after!.isLetter || after!.isNumber || after == "-" || after == ".")
                || (after == "." && text[text.index(after: range.upperBound)...].first.map { !$0.isLetter } ?? true)
            if boundaryBefore && boundaryAfter { return true }
            start = range.upperBound
        }
        return false
    }
}

/// One notification as macOS kept it.
struct CapturedNotification: Equatable, Sendable {
    /// The row in Notification Center's database; they only grow.
    var record: Int64
    var bundleID: String
    var title: String
    var subtitle: String
    var body: String
    var date: Date
}

/// The notification database of macOS: a row per notification with its app and a property list holding what it said.
enum NotificationRecord {
    /// Where macOS 15 and later keep it (Full Disk Access is needed to read it).
    static func databasePath(home: String) -> String {
        home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    }

    /// The query for the rows after `record`, oldest first; with no record yet, the rows of the last `since` seconds.
    /// The property list comes as hex, since `sqlite3 -json` cannot carry a blob.
    static func query(after record: Int64?, since: Date, limit: Int = 200) -> String {
        let filter = record.map { "r.rec_id > \($0)" } ?? "r.delivered_date > \(Int(since.timeIntervalSinceReferenceDate))"
        return """
        SELECT r.rec_id AS id, a.identifier AS app, r.delivered_date AS date, hex(r.data) AS data
        FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE \(filter) ORDER BY r.rec_id LIMIT \(limit)
        """
    }

    /// The newest row, so a fresh start knows where the next new notification begins.
    static let newestQuery = "SELECT max(rec_id) AS id FROM record"

    /// A row of `query` as a notification; nil when it holds no property list Nook can read.
    static func notification(_ row: [String: Any]) -> CapturedNotification? {
        guard let record = integer(row["id"]), let hex = row["data"] as? String, let data = Self.data(hex: hex),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let request = plist["req"] as? [String: Any] ?? [:]
        let bundleID = (row["app"] as? String) ?? (plist["app"] as? String) ?? ""
        let seconds = (plist["date"] as? Double) ?? double(row["date"]) ?? Date().timeIntervalSinceReferenceDate
        return CapturedNotification(record: record, bundleID: bundleID,
                                    title: clean(request["titl"]), subtitle: clean(request["subt"]), body: clean(request["body"]),
                                    date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func integer(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? Double { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func clean(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One message in a collected chat.
struct InboxMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// In a group: who wrote it. Empty in a private chat, where the chat's name already says who.
    var sender: String = ""
    var text: String
    var date: Date
}

/// One chat in one app, with its newest messages.
struct InboxThread: Codable, Equatable, Identifiable, Sendable {
    /// The app and the chat's name, folded: "telegram|familie".
    var id: String
    /// The app's id (`MessagingApp.id`).
    var app: String
    var name: String
    /// Oldest first, the newest `ChatInbox.keep` only.
    var messages: [InboxMessage] = []
    var unread: Int = 0

    var last: Date { messages.last?.date ?? .distantPast }
    /// Someone else than the chat itself wrote in it: a group.
    var isGroup: Bool { messages.contains { !$0.sender.isEmpty } }
}

/// What a chat app's notification says: the chat, who wrote in it and what.
struct ChatNotice: Equatable, Sendable {
    var app: String
    var chat: String
    var sender: String
    var text: String
    var date: Date
}

enum ChatCapture {
    /// The chat message in a notification, or nil when it is from no chat app or holds no message.
    static func notice(_ notification: CapturedNotification) -> ChatNotice? {
        let fromBrowser = MessagingApps.isBrowser(notification.bundleID)
        let app: MessagingApp?
        if let own = MessagingApps.app(bundleID: notification.bundleID) {
            app = own
        } else if fromBrowser {
            app = MessagingApps.app(mentionedIn: [notification.subtitle, notification.title, notification.body])
        } else {
            app = nil
        }
        guard let app else { return nil }

        var title = notification.title
        // A browser puts the site in the subtitle; it says which app, not who.
        var subtitle = fromBrowser && looksLikeSite(notification.subtitle) ? "" : notification.subtitle
        var text = notification.body
        if fromBrowser, title.lowercased().hasSuffix(" - " + app.name.lowercased()) {
            title = String(title.dropLast(app.name.count + 3))
        }
        guard !text.isEmpty else { return nil }

        // "Instagram" as the title: the text starts with who wrote ("anna: see you").
        if title.isEmpty || title.lowercased() == app.name.lowercased() {
            guard let (name, rest) = speaker(text) else { return nil }
            title = name
            text = rest
        }
        // WhatsApp writes a group's message as "Anna @ Family".
        if subtitle.isEmpty, app.id == "whatsapp", let range = title.range(of: " @ ") {
            subtitle = String(title[..<range.lowerBound])
            title = String(title[range.upperBound...])
        }
        if subtitle.lowercased() == title.lowercased() { subtitle = "" }
        return ChatNotice(app: app.id, chat: title, sender: subtitle, text: text, date: notification.date)
    }

    /// "anna: see you" as ("anna", "see you"): a short name without a line break before the colon.
    static func speaker(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains("\n"), !name.contains("http"), !rest.isEmpty else { return nil }
        return (name, rest)
    }

    private static func looksLikeSite(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(" ") && text.contains(".")
    }
}

/// Every collected chat, kept across launches.
struct ChatInbox: Codable, Equatable, Sendable {
    /// Messages kept per chat.
    static let keep = 50
    /// Chats kept; the quietest go first.
    static let maxThreads = 200
    /// A chat that had nothing new for this long is dropped.
    static let maxAge: TimeInterval = 30 * 86_400

    var threads: [String: InboxThread] = [:]
    /// The newest notification read, so none is read twice.
    var lastRecord: Int64?

    static func key(app: String, chat: String) -> String {
        app + "|" + chat.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Adds a message to its chat. False when that chat already shows it: the same text from the same person within a
    /// minute (an app that shows a notification again, or updates it).
    @discardableResult
    mutating func add(_ notice: ChatNotice, id: String) -> Bool {
        let key = Self.key(app: notice.app, chat: notice.chat)
        var thread = threads[key] ?? InboxThread(id: key, app: notice.app, name: notice.chat)
        if thread.messages.contains(where: {
            $0.id == id || ($0.text == notice.text && $0.sender == notice.sender && abs($0.date.timeIntervalSince(notice.date)) < 60)
        }) { return false }
        let message = InboxMessage(id: id, sender: notice.sender, text: notice.text, date: notice.date)
        // Usually the newest, but a late notification goes in its place.
        let index = thread.messages.lastIndex { $0.date <= notice.date }.map { $0 + 1 } ?? 0
        thread.messages.insert(message, at: index)
        if thread.messages.count > Self.keep { thread.messages.removeFirst(thread.messages.count - Self.keep) }
        thread.name = notice.chat
        thread.unread += 1
        threads[key] = thread
        dropQuietest()
        return true
    }

    mutating func markRead(_ id: String) {
        threads[id]?.unread = 0
    }

    mutating func markAllRead() {
        for key in threads.keys { threads[key]?.unread = 0 }
    }

    mutating func remove(_ id: String) {
        threads[id] = nil
    }

    /// Drops chats with nothing new for `maxAge`, then the quietest beyond `maxThreads`.
    mutating func trim(now: Date = Date()) {
        threads = threads.filter { now.timeIntervalSince($0.value.last) < Self.maxAge }
        dropQuietest()
    }

    private mutating func dropQuietest() {
        guard threads.count > Self.maxThreads else { return }
        for thread in sorted.dropFirst(Self.maxThreads) { threads[thread.id] = nil }
    }

    /// Newest first.
    var sorted: [InboxThread] {
        threads.values.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
    }

    var totalUnread: Int { threads.values.reduce(0) { $0 + $1.unread } }

    /// The apps that have chats here, the busiest first.
    var apps: [String] {
        let counts = Dictionary(grouping: threads.values, by: \.app).mapValues(\.count)
        return counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
    }
}

/// How a chat reads as bubbles: a line for each new day, and messages from the same person close together, with their
/// name only above the first of them.
enum ChatTimeline {
    struct Item: Equatable {
        var id: String
        /// Who wrote it ("" for the other side of a private chat, "\u{1}me" for you).
        var author: String
        var date: Date?
    }

    enum Entry: Equatable {
        /// A new day starts: "Today", "Yesterday", "Monday", "12 Oct".
        case day(id: String, label: String)
        /// `first`: the first of a run by one author (with their name); `last`: the last of it (more room after).
        case message(id: String, first: Bool, last: Bool)
    }

    static func id(of entry: Entry) -> String {
        switch entry {
        case .day(let id, _), .message(let id, _, _): return id
        }
    }

    /// Messages by one author further apart than this start a new run.
    static let runGap: TimeInterval = 5 * 60

    static func entries(_ items: [Item], now: Date = Date(), calendar: Calendar = .current,
                        locale: Locale = .current) -> [Entry] {
        var entries: [Entry] = []
        var previousDay: Date?
        for (index, item) in items.enumerated() {
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            var newDay = false
            if let date = item.date {
                let day = calendar.startOfDay(for: date)
                if day != previousDay {
                    // No line above the first message when the whole chat is from today: the card says when.
                    if previousDay != nil || !calendar.isDate(day, inSameDayAs: now) || items.contains(where: {
                        $0.date.map { !calendar.isDate($0, inSameDayAs: now) } ?? false
                    }) {
                        entries.append(.day(id: "day-" + item.id, label: dayLabel(date, now: now, calendar: calendar, locale: locale)))
                    }
                    newDay = previousDay != nil
                    previousDay = day
                }
            }
            let first = previous == nil || newDay || !together(previous!, item)
            let nextNewDay = next.flatMap { next in
                next.date.flatMap { nextDate in item.date.map { !calendar.isDate(nextDate, inSameDayAs: $0) } }
            } ?? false
            let last = next == nil || nextNewDay || !together(item, next!)
            entries.append(.message(id: item.id, first: first, last: last))
        }
        return entries
    }

    private static func together(_ a: Item, _ b: Item) -> Bool {
        guard a.author == b.author else { return false }
        guard let first = a.date, let second = b.date else { return true }
        return abs(second.timeIntervalSince(first)) <= runGap
    }

    /// "Today", "Yesterday", the weekday within the last week, else the date (with the year when it is another year).
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return tr("chat.day.today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return tr("chat.day.yesterday")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        }
        return formatter.string(from: date)
    }

    /// A message of one to three emoji and nothing else, which a chat shows large.
    static func isEmojiOnly(_ text: String) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard (1...3).contains(characters.count) else { return false }
        return characters.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.count > 1 && character.unicodeScalars.first?.properties.isEmoji == true)
        }
    }

    /// The same number for the same name every time, to give each person in a group their own color.
    static func colorIndex(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}

// MARK: For Nook's answers

extension ChatInbox {
    /// The chat best matching a name (exactly, else the one starting with it, else containing it), in one app or any.
    func thread(named name: String, app: String? = nil) -> InboxThread? {
        let wanted = Self.key(app: "", chat: name).dropFirst()
        guard !wanted.isEmpty else { return nil }
        let candidates = sorted.filter { app == nil || $0.app == app }
        let folded = { (thread: InboxThread) in Self.key(app: "", chat: thread.name).dropFirst() }
        return candidates.first { folded($0) == wanted }
            ?? candidates.first { folded($0).hasPrefix(wanted) }
            ?? candidates.first { folded($0).contains(wanted) }
    }

    /// One line per chat, newest first: "Telegram · Anna (2 unread) · 2026-10-20 12:04 · Anna: See you at eight".
    static func overview(_ threads: [InboxThread], limit: Int = 12) -> String {
        threads.prefix(limit).map { thread in
            let app = MessagingApps.app(id: thread.app)?.name ?? thread.app
            let unread = thread.unread > 0 ? " (\(thread.unread) unread)" : ""
            let last = thread.messages.last.map { " · " + stamp($0.date) + " · " + line($0, in: thread) } ?? ""
            return "- \(app) · \(thread.name)\(unread)\(last)"
        }.joined(separator: "\n")
    }

    /// A chat's messages, oldest first: "[2026-10-20 12:04] Anna: See you at eight".
    static func transcript(_ thread: InboxThread, limit: Int = 30) -> String {
        thread.messages.suffix(limit).map { "[\(stamp($0.date))] " + line($0, in: thread) }.joined(separator: "\n")
    }

    private static func line(_ message: InboxMessage, in thread: InboxThread) -> String {
        let text = message.text.count > 300 ? String(message.text.prefix(300)) + "…" : message.text
        return "\(message.sender.isEmpty ? thread.name : message.sender): \(text)"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
