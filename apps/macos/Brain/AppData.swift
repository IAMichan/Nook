import Foundation

/// Reading the data of apps that have no API of their own (Messages, WhatsApp, Bear, Things) straight from their local
/// database, read-only. This file holds the parts that are plain Foundation: building the SQL, decoding what the apps
/// store and turning rows into text for the brain. The connectors (`AppConnectors.swift`) run `sqlite3` and add names
/// from Contacts. Nothing here writes to an app's data.
enum AppData {
    // MARK: SQL

    /// A string as an SQL literal: 'it''s'.
    static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `column LIKE '%word%'` for every word on any of the columns, joined with OR. LIKE ignores case (for ASCII).
    /// `%`, `_` and `\` in a word are matched literally.
    static func anyLike(_ columns: [String], _ words: [String]) -> String {
        let parts = words.flatMap { word -> [String] in
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let pattern = literal("%" + escaped + "%")
            return columns.map { "\($0) LIKE \(pattern) ESCAPE '\\'" }
        }
        return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    /// Rows of `sqlite3 -json` output. Empty output (no rows) is an empty list.
    static func rows(_ json: String) -> [[String: Any]] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows
    }

    static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// Apple stores dates as seconds since 2001-01-01; Messages since 2017 in nanoseconds.
    static func appleDate(_ raw: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: raw > 100_000_000_000 ? raw / 1_000_000_000 : raw)
    }

    static func stamp(_ date: Date, time: Bool = true) -> String {
        // Runs once per message of a thread or search result: a cached formatter, not a new one each time.
        NookDates.formatter(time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd", locale: "en_US_POSIX").string(from: date)
    }

    /// How old a conversation's newest message is, said plainly: a chat read from a source that stopped syncing ends
    /// weeks ago, and a reply must never answer that message as if it just came in.
    /// `other` names the tool that reads the same chat from elsewhere, when there is one.
    static func freshness(newest: Date, other: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: newest), to: calendar.startOfDay(for: now)).day ?? 0
        let age = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        var line = "Newest message in this chat: \(stamp(newest)) (\(age))."
        if days >= staleDays {
            line += " Nothing newer is in this source."
            if let other { line += " Before writing a reply, read the chat with \(other) too, which may have newer messages." }
            line += " Tell the user how old the last message is instead of answering it as if it were new."
        }
        return line
    }

    /// From this many days a chat's newest message counts as old.
    static let staleDays = 3

    // MARK: Messages' attributed text

    /// Since macOS Ventura, Messages often keeps the text of a message only in `attributedBody`, an archived
    /// NSAttributedString (typedstream). The plain text follows the class name "NSString": a few type bytes, a '+',
    /// then a length (one byte, or 0x81 + two bytes, or 0x82 + four bytes, little-endian) and the UTF-8 text.
    static func attributedText(hex: String) -> String? {
        guard !hex.isEmpty, let data = bytes(hex: hex) else { return nil }
        let marker = Array("NSString".utf8)
        guard let start = find(marker, in: data) else { return nil }
        var index = start + marker.count
        // Skip to the '+' that opens the string (within a few bytes).
        let limit = min(data.count, index + 8)
        while index < limit, data[index] != 0x2B { index += 1 }
        guard index < data.count - 1 else { return nil }
        index += 1
        var length = Int(data[index])
        index += 1
        if length == 0x81 {
            guard index + 2 <= data.count else { return nil }
            length = Int(data[index]) | Int(data[index + 1]) << 8
            index += 2
        } else if length == 0x82 {
            guard index + 4 <= data.count else { return nil }
            length = Int(data[index]) | Int(data[index + 1]) << 8 | Int(data[index + 2]) << 16 | Int(data[index + 3]) << 24
            index += 4
        }
        guard length > 0, index + length <= data.count else { return nil }
        return String(bytes: data[index..<(index + length)], encoding: .utf8)
    }

    private static func bytes(hex: String) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let value: UInt8
            switch character {
            case 48...57: value = character - 48
            case 65...70: value = character - 55
            case 97...102: value = character - 87
            default: return nil
            }
            if let h = high { result.append(h << 4 | value); high = nil } else { high = value }
        }
        return result
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    // MARK: Chats (Messages and WhatsApp)

    /// One message as both apps' queries return it: `chat`, `chatname`, `handle`, `me`, `date`, `text`, `body` (hex).
    struct Message {
        var chat: String
        var chatName: String
        var sender: String
        var fromMe: Bool
        var date: Date
        var text: String
    }

    /// Rows to messages. `names` turns a phone number or address (by `key`) into a contact name.
    static func messages(_ rows: [[String: Any]], names: [String: String] = [:]) -> [Message] {
        rows.compactMap { row in
            var text = string(row["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = attributedText(hex: string(row["body"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            // Attachments without text are U+FFFC; nothing to read.
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let handle = cleanHandle(string(row["handle"]))
            let fromMe = (number(row["me"]) ?? 0) != 0
            var chatName = string(row["chatname"])
            // Without a name of its own, a conversation is called after the contact (or the number) it is with.
            if chatName.isEmpty || chatName.hasPrefix("chat") || chatName.contains("@") || chatName.hasPrefix("+") {
                let raw = cleanHandle(chatName)
                if !chatName.hasPrefix("chat"), let name = names[key(raw)] {
                    chatName = name
                } else if chatName.hasPrefix("chat") || chatName.hasSuffix("@g.us") {
                    chatName = "group chat"
                } else {
                    chatName = raw.isEmpty ? (names[key(handle)] ?? handle) : raw
                }
            }
            let sender = fromMe ? "Ik" : (names[key(handle)] ?? (handle.isEmpty ? chatName : handle))
            return Message(chat: string(row["chat"]), chatName: chatName, sender: sender, fromMe: fromMe,
                           date: appleDate(number(row["date"]) ?? 0), text: text)
        }
    }

    /// The same person however the number is written: an address in lowercase, a phone number by its last nine digits
    /// ("+31 6 1234 5678", "0612345678" and "31612345678@s.whatsapp.net" are one key).
    static func key(_ handle: String) -> String {
        let clean = cleanHandle(handle)
        if clean.contains("@") { return clean.lowercased() }
        let digits = clean.filter(\.isNumber)
        return digits.count > 9 ? String(digits.suffix(9)) : digits
    }

    static func cleanHandle(_ raw: String) -> String {
        var handle = raw.trimmingCharacters(in: .whitespaces)
        for suffix in ["@s.whatsapp.net", "@c.us"] where handle.hasSuffix(suffix) {
            handle = "+" + handle.dropLast(suffix.count)
        }
        return handle
    }

    /// Search results grouped per conversation, best matching conversations first, with the newest matching messages.
    static func formatSearch(_ messages: [Message], terms: Research.Terms, app: String, keep: Int = 6, perChat: Int = 4) -> String {
        var order: [String] = []
        var byChat: [String: [Message]] = [:]
        for message in messages {
            if byChat[message.chat] == nil { order.append(message.chat) }
            byChat[message.chat, default: []].append(message)
        }
        let chats = order.compactMap { byChat[$0] }
        let ranked = Research.best(chats, terms: terms, keep: keep, title: { $0.first?.chatName ?? "" },
                                   text: { $0.prefix(20).map(\.text).joined(separator: "\n") })
        guard !ranked.isEmpty else { return "" }
        var blocks: [String] = []
        var refs: [String] = []
        for chat in ranked {
            guard let first = chat.first else { continue }
            var lines = ["### \(first.chatName) | \(stamp(first.date, time: false)) [chat: \(first.chat)]"]
            for message in chat.prefix(perChat) {
                lines.append("- \(stamp(message.date)) · \(message.sender): \(String(message.text.prefix(300)))")
            }
            if chat.count > perChat { lines.append("(\(chat.count - perChat) more matching messages in this conversation)") }
            blocks.append(lines.joined(separator: "\n"))
            refs.append(ReferenceParser.line(title: "\(app): \(first.chatName)", url: nil, detail: stamp(first.date, time: false)))
        }
        return (blocks + refs).joined(separator: "\n\n")
    }

    /// One conversation to read: the passages around messages that match (a few before and after each), plus the most
    /// recent messages, in time order. `messages` is newest first, as the query returns it.
    static func formatThread(_ newestFirst: [Message], terms: Research.Terms, app: String, around: Int = 4, matches: Int = 6, recent: Int = 20,
                             other: String? = nil, now: Date = Date()) -> String {
        let messages = Array(newestFirst.reversed())
        guard let last = messages.last else { return "" }
        var keep = Set(max(0, messages.count - recent)..<messages.count)
        if !terms.isEmpty {
            let hits = messages.indices.filter { Research.score(title: "", text: messages[$0].text, terms: terms) > 0 }.suffix(matches)
            for hit in hits { keep.formUnion(max(0, hit - around)...min(messages.count - 1, hit + around)) }
        }
        var lines = ["## \(app): conversation with \(last.chatName) (\(messages.count) messages read)"]
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index > previous + 1 { lines.append("…") }
            let message = messages[index]
            lines.append("\(stamp(message.date)) · \(message.sender): \(String(message.text.prefix(600)))")
            previous = index
        }
        lines.append(freshness(newest: last.date, other: other, now: now))
        lines.append(ReferenceParser.line(title: "\(app): \(last.chatName)", url: nil, detail: stamp(last.date, time: false)))
        return lines.joined(separator: "\n")
    }

    // MARK: Open chats (Messages and WhatsApp)

    /// One conversation with its newest message, as the "open chats" queries return it: `chat`, `chatname`, `handle`,
    /// `me` (the newest message is mine), `date`, `text`, `body` (hex, Messages only), `unread`, `group`.
    struct OpenChat {
        var chat: String
        var name: String
        var group: Bool
        /// Unread messages; -1 when the chat is marked as unread by hand (WhatsApp).
        var unread: Int
        var lastFromMe: Bool
        var lastSender: String
        var date: Date
        var text: String

        /// Someone else wrote last in a one-on-one chat: they are probably waiting for an answer.
        var awaitsReply: Bool { !lastFromMe && !group }
    }

    static func openChats(_ rows: [[String: Any]], names: [String: String] = [:]) -> [OpenChat] {
        rows.compactMap { raw -> OpenChat? in
            var row = raw
            // A chat whose newest message has no text (a photo, a sticker) still counts.
            let text = string(raw["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            row["text"] = text.isEmpty ? (attributedText(hex: string(raw["body"])) ?? "(attachment)") : text
            row["body"] = ""
            if string(row["text"]).replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { row["text"] = "(attachment)" }
            guard let message = messages([row], names: names).first else { return nil }
            let group = (number(raw["group"]) ?? 0) != 0 || string(raw["chatname"]).hasSuffix("@g.us")
            return OpenChat(chat: message.chat, name: message.chatName, group: group, unread: Int(number(raw["unread"]) ?? 0),
                            lastFromMe: message.fromMe, lastSender: message.sender, date: message.date, text: message.text)
        }
    }

    /// The conversations that are still open: unread ones first, then one-on-one chats where the other person wrote
    /// last. Says so plainly when there are none, so the model never has to guess.
    static func formatOpenChats(_ chats: [OpenChat], app: String, days: Int, keep: Int = 12) -> String {
        let unread = chats.filter { $0.unread != 0 }
        let waiting = chats.filter { $0.unread == 0 && $0.awaitsReply }
        var lines = ["## \(app): open chats (last \(days) days, \(chats.count) chats checked)"]
        guard !unread.isEmpty || !waiting.isEmpty else {
            lines.append("No unread chats and no one-on-one chat waiting for the user's reply.")
            return lines.joined(separator: "\n")
        }
        lines.append("Unread: \(unread.count) chats. Waiting for the user's reply (the other person wrote last): \(waiting.count) chats.")
        var refs: [String] = []
        for chat in (unread + waiting).prefix(keep) {
            let state: String
            if chat.unread > 0 { state = "\(chat.unread) unread" } else if chat.unread < 0 { state = "marked unread" } else { state = "waiting for your reply" }
            lines.append("### \(chat.name)\(chat.group ? " (group)" : "") | \(stamp(chat.date, time: false)) [chat: \(chat.chat)]")
            lines.append("- \(state) · newest message \(stamp(chat.date)) from \(chat.lastSender): \(String(chat.text.prefix(200)))")
            refs.append(ReferenceParser.line(title: "\(app): \(chat.name)", url: nil, detail: "\(state) · \(stamp(chat.date, time: false))"))
        }
        let more = unread.count + waiting.count - keep
        if more > 0 { lines.append("(\(more) more open chats not shown)") }
        return (lines + [""] + refs).joined(separator: "\n")
    }

    // MARK: Notes (Bear) and tasks (Things)

    /// Bear notes: `id`, `title`, `date`, `text`. The same layout as Apple Notes, so the same research opens them.
    static func formatNotes(_ rows: [[String: Any]], terms: Research.Terms, app: String, keep: Int = 10) -> String {
        let ranked = Research.best(rows, terms: terms, keep: keep, title: { string($0["title"]) }, text: { string($0["text"]) })
        var blocks: [String] = []
        var refs: [String] = []
        for row in ranked {
            let title = string(row["title"]).isEmpty ? "(untitled)" : string(row["title"])
            let date = number(row["date"]).map { stamp(appleDate($0), time: false) } ?? ""
            blocks.append("### \(title) | \(date) [id: \(string(row["id"]))]\n\(String(string(row["text"]).prefix(800)))")
            refs.append(ReferenceParser.line(title: title, url: nil, detail: "\(app) · \(date)"))
        }
        return (blocks + refs).joined(separator: "\n\n")
    }

    /// Things to-dos and projects: `title`, `notes`, `status` (0 open, 2 cancelled, 3 done), `type` (1 project),
    /// `project`, `area`.
    static func formatTasks(_ rows: [[String: Any]], terms: Research.Terms, keep: Int = 15) -> String {
        let ranked = Research.best(rows, terms: terms, keep: keep, title: { string($0["title"]) }, text: { string($0["notes"]) })
        var lines: [String] = []
        var refs: [String] = []
        for row in ranked {
            let status: String
            switch Int(number(row["status"]) ?? 0) {
            case 3: status = "done"
            case 2: status = "cancelled"
            default: status = "open"
            }
            let kind = Int(number(row["type"]) ?? 0) == 1 ? "project" : "to-do"
            let place = [string(row["project"]), string(row["area"])].filter { !$0.isEmpty }.joined(separator: " / ")
            var line = "- \(string(row["title"])) [\(kind), \(status)]" + (place.isEmpty ? "" : " (\(place))")
            let notes = string(row["notes"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { line += "\n  " + String(notes.prefix(400)).replacingOccurrences(of: "\n", with: "\n  ") }
            lines.append(line)
            refs.append(ReferenceParser.line(title: string(row["title"]), url: nil, detail: "Things · \(status)"))
        }
        return (lines + refs).joined(separator: "\n")
    }
}

// MARK: Messages: tapbacks and sending

extension AppData {
    /// One tapback in Messages' database: a row whose `associated_message_type` says someone put an emoji on a message
    /// (2000…2005 for ❤️ 👍 👎 😂 ‼️ ❓, 2006 for any emoji in `associated_message_emoji`) or took it back (3000…3006).
    /// Its `associated_message_guid` points at the message it is on, as "p:0/<guid>" (a part of it) or "bp:<guid>".
    struct Tapback: Equatable {
        /// The guid of the message it is on.
        var target: String
        var emoji: String
        /// It puts the emoji there; false when it takes it back.
        var adds: Bool
        /// Who did it: "me" for you, else their handle in the database.
        var sender: String
        var mine: Bool

        /// The tapback of a row; nil for a row that is none Nook shows (a sticker put on a message, a poll vote…).
        init?(associated: String, type: Int, emoji custom: String? = nil, sender: String, mine: Bool) {
            guard let target = Self.target(associated), (2000...2006).contains(type) || (3000...3006).contains(type) else { return nil }
            let adds = type < 3000
            let emoji = Self.emoji(type: type, custom: custom)
            // Taking back an emoji of your own choice may not say which: it takes back whatever that person put there.
            if adds && emoji == nil { return nil }
            self.init(target: target, emoji: emoji ?? "", adds: adds, sender: sender, mine: mine)
        }

        init(target: String, emoji: String, adds: Bool, sender: String, mine: Bool) {
            self.target = target
            self.emoji = emoji
            self.adds = adds
            self.sender = sender
            self.mine = mine
        }

        /// The classic tapbacks by the last digit of their type.
        private static let classic = [0: "❤️", 1: "👍", 2: "👎", 3: "😂", 4: "‼️", 5: "❓"]

        /// The emoji of a tapback type; for 2006/3006 the one the row names itself. Nil when there is none.
        static func emoji(type: Int, custom: String? = nil) -> String? {
            guard (2000...2006).contains(type) || (3000...3006).contains(type) else { return nil }
            if type % 1000 == 6 {
                let own = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return own.isEmpty ? nil : own
            }
            return classic[type % 1000]
        }

        /// The guid of the message an `associated_message_guid` points at: "p:0/ABC" and "bp:ABC" are both "ABC".
        static func target(_ associated: String) -> String? {
            var guid = Substring(associated.trimmingCharacters(in: .whitespacesAndNewlines))
            if guid.hasPrefix("p:"), let slash = guid.firstIndex(of: "/") {
                guid = guid[guid.index(after: slash)...]
            } else if guid.hasPrefix("bp:") {
                guid = guid.dropFirst(3)
            }
            return guid.isEmpty ? nil : String(guid)
        }

        /// The ways a tapback can point at the message `guid`, to look them up by: each of its first `parts` parts (a
        /// message with several photos has one per photo), and the message as a whole.
        static func pointers(to guid: String, parts: Int = 10) -> [String] {
            (0..<parts).map { "p:\($0)/\(guid)" } + ["bp:\(guid)"]
        }

        /// The emoji on each message (by its guid) once these tapbacks, oldest first, are applied: everyone has one
        /// tapback on a message at most, a newer one replaces theirs and taking it back clears it. The most used emoji
        /// come first. Every message a tapback points at is in the answer, with no emoji when all were taken back, so a
        /// chat that showed one drops it.
        static func reactions(_ tapbacks: [Tapback], name: (String) -> String? = { _ in nil }) -> [String: [InboxReaction]] {
            var current: [String: [String: Tapback]] = [:]
            var order: [String: [String]] = [:]
            for tapback in tapbacks {
                if tapback.adds {
                    current[tapback.target, default: [:]][tapback.sender] = tapback
                    if !(order[tapback.target]?.contains(tapback.emoji) ?? false) { order[tapback.target, default: []].append(tapback.emoji) }
                } else {
                    if let kept = current[tapback.target]?[tapback.sender], tapback.emoji.isEmpty || kept.emoji == tapback.emoji {
                        current[tapback.target]?[tapback.sender] = nil
                    }
                    if current[tapback.target] == nil { current[tapback.target] = [:] }
                }
            }
            var reactions: [String: [InboxReaction]] = [:]
            for (target, people) in current {
                var chips: [InboxReaction] = []
                for emoji in order[target] ?? [] {
                    let on = people.values.filter { $0.emoji == emoji }
                    guard !on.isEmpty else { continue }
                    let names = on.filter { !$0.mine }.compactMap { name($0.sender) }.sorted()
                    chips.append(InboxReaction(emoji: emoji, count: on.count, mine: on.contains { $0.mine },
                                               people: names.isEmpty ? nil : names))
                }
                // A stable sort: emoji used as often keep the order they were first put there in.
                reactions[target] = chips.enumerated()
                    .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
                    .map(\.element)
            }
            return reactions
        }
    }

    /// Sending in Messages, which another app can only do through AppleScript: the script that sends text and files
    /// to one chat, found by the id Messages' database keeps for it (`chat.guid`).
    enum MessagesSend {
        enum Item: Equatable {
            case text(String)
            /// A file, by its path.
            case file(String)
        }

        /// What the script answers once Messages took everything; a script that did not run answers nothing.
        static let done = "sent"

        /// The script that sends `items` in order to the first of `chats` (ids from the database, the one to prefer
        /// first) that Messages knows. Every text and path goes in as an AppleScript string, so no quote or backslash in
        /// it can end that string early. Fails with -1728 when Messages knows none of them.
        static func script(_ items: [Item], chats: [String]) -> String {
            var lines: [String] = []
            var sends: [String] = []
            var files = 0
            for item in items {
                switch item {
                case .text(let text):
                    sends.append("send \(MusicScriptOutput.quoted(text)) to theChat")
                case .file(let path):
                    files += 1
                    lines.append("set theFile\(files) to POSIX file \(MusicScriptOutput.quoted(path))")
                    sends.append("send theFile\(files) to theChat")
                }
            }
            lines.append("tell application \"Messages\"")
            lines.append("\tset theChat to missing value")
            for target in targets(chats) {
                lines += ["\tif theChat is missing value then", "\t\ttry", "\t\t\tset theChat to \(target)", "\t\t\tget id of theChat",
                          "\t\ton error", "\t\t\tset theChat to missing value", "\t\tend try", "\tend if"]
            }
            lines.append("\tif theChat is missing value then error number -1728")
            lines += sends.map { "\t" + $0 }
            lines.append("end tell")
            lines.append("return \(MusicScriptOutput.quoted(done))")
            return lines.joined(separator: "\n")
        }

        /// How the script looks for the chats, in order: by each id as the database has it, then as a newer Messages may
        /// name it ("iMessage;-;+31…" can be "any;-;+31…" there), and last the person of a one-to-one chat on the
        /// chat's own service.
        static func targets(_ chats: [String]) -> [String] {
            var ids: [String] = []
            for chat in chats {
                for id in variants(chat) where !ids.contains(id) { ids.append(id) }
            }
            var people: [String] = []
            for chat in chats {
                guard let person = person(chat) else { continue }
                let target = "participant \(MusicScriptOutput.quoted(person.handle)) of (1st account whose service type = \(person.service))"
                if !people.contains(target) { people.append(target) }
            }
            return ids.map { "chat id " + MusicScriptOutput.quoted($0) } + people
        }

        /// A chat's id and the other ways Messages may name it. iMessage and sms never stand in for each other, so a
        /// message never goes out as an sms you did not choose; "any" is either.
        static func variants(_ chat: String) -> [String] {
            guard let split = chat.firstIndex(of: ";") else { return chat.isEmpty ? [] : [chat] }
            let service = String(chat[..<split])
            let rest = String(chat[split...])
            if service == "any" { return [chat, "iMessage" + rest, "SMS" + rest] }
            return [chat, "any" + rest]
        }

        /// The person of a one-to-one chat ("iMessage;-;+31612345678") and the service to reach them on; nil for a group.
        static func person(_ chat: String) -> (handle: String, service: String)? {
            let parts = chat.components(separatedBy: ";")
            guard parts.count >= 3, parts[1] == "-" else { return nil }
            let handle = parts[2...].joined(separator: ";")
            guard !handle.isEmpty else { return nil }
            return (handle, parts[0] == "SMS" ? "SMS" : "iMessage")
        }
    }
}
