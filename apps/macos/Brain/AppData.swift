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
    static func formatThread(_ newestFirst: [Message], terms: Research.Terms, app: String, around: Int = 4, matches: Int = 6, recent: Int = 20) -> String {
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
