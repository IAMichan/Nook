import Foundation

/// Mail's own index and message files, read directly. Asking the Mail app through a script takes tens of seconds on a big
/// mailbox and sees one mailbox at a time; the index (`Envelope Index`, SQLite) answers in milliseconds for every mailbox,
/// also Gmail's "All Mail" and archives, and does not need Mail to be open. It needs Full Disk Access: without it the caller
/// uses the script as before.
///
/// This file holds the plain parts (the query, where a message lives, reading a message file), so they are tested in
/// isolation; `MailConnector` runs them.
enum MailIndex {
    struct Row: Equatable {
        var id: Int64
        var subject: String
        var sender: String
        var recipients: String
        var date: Date
        var summary: String
        var mailbox: String
    }

    /// Mail's folder: ~/Library/Mail/V10 today, the newest version there is.
    static func root(library: URL) -> URL? {
        let mail = library.appendingPathComponent("Mail", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: mail.path)) ?? []
        let newest = versions.filter { $0.range(of: #"^V\d+$"#, options: .regularExpression) != nil }
            .max { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
        return newest.map { mail.appendingPathComponent($0, isDirectory: true) }
    }

    static func databasePath(root: URL) -> String {
        root.appendingPathComponent("MailData/Envelope Index").path
    }

    /// One word as a LIKE pattern inside SQL quotes.
    static func pattern(_ word: String) -> String {
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "'", with: "''")
        return "'%\(escaped)%' ESCAPE '\\'"
    }

    /// Mailboxes a search leaves out (trash, junk, drafts), in the languages Mail and its servers name them.
    private static let skipped = ["Trash", "Prullenbak", "Verwijderd", "Deleted", "Papierkorb", "Corbeille", "Papelera",
                                  "Junk", "Spam", "Ongewenst", "Draft", "Concept", "Entw%C3%BCrfe", "Brouillons", "Borradores"]
    private static let sentBoxes = ["Sent", "Verzonden", "Gesendet", "Envoy", "Enviado"]

    /// The newest messages that hold any of the words in their subject, sender, summary or, in sent mail, a recipient.
    static func searchSQL(words: [String], sent: Bool, limit: Int) -> String {
        let fields = sent ? ["s.subject", "su.summary", "ra.address", "ra.comment"] : ["s.subject", "su.summary", "a.address", "a.comment"]
        let matches = words.flatMap { word in fields.map { "\($0) LIKE \(pattern(word))" } }.joined(separator: " OR ")
        let boxes = sent
            ? "(" + sentBoxes.map { "b.url LIKE '%\($0)%'" }.joined(separator: " OR ") + ")"
            : skipped.map { "b.url NOT LIKE '%\($0)%'" }.joined(separator: " AND ")
        let names = "(SELECT group_concat(CASE WHEN x.comment = '' THEN x.address ELSE x.comment END, ', ') FROM recipients r2 JOIN addresses x ON x.ROWID = r2.address WHERE r2.message = m.ROWID)"
        let join = sent ? "LEFT JOIN recipients r ON r.message = m.ROWID LEFT JOIN addresses ra ON ra.ROWID = r.address" : ""
        return """
        SELECT DISTINCT m.ROWID AS id, s.subject AS subject, a.address AS address, a.comment AS name, m.date_received AS date,
               su.summary AS summary, b.url AS mailbox, \(names) AS recipients
        FROM messages m JOIN subjects s ON s.ROWID = m.subject JOIN mailboxes b ON b.ROWID = m.mailbox
        LEFT JOIN addresses a ON a.ROWID = m.sender LEFT JOIN summaries su ON su.ROWID = m.summary \(join)
        WHERE m.deleted = 0 AND \(boxes) AND (\(matches))
        ORDER BY m.date_received DESC LIMIT \(limit)
        """
    }

    /// Rows as the database returned them, without a message that sits in several mailboxes twice (Gmail's labels).
    static func rows(_ raw: [[String: Any]]) -> [Row] {
        var seen = Set<String>()
        return raw.compactMap { row -> Row? in
            guard let id = (row["id"] as? NSNumber)?.int64Value, let stamp = (row["date"] as? NSNumber)?.doubleValue else { return nil }
            let address = (row["address"] as? String) ?? ""
            let name = (row["name"] as? String) ?? ""
            let found = Row(id: id, subject: (row["subject"] as? String) ?? "", sender: name.isEmpty ? address : "\(name) <\(address)>",
                            recipients: (row["recipients"] as? String) ?? "", date: Date(timeIntervalSince1970: stamp),
                            summary: (row["summary"] as? String) ?? "", mailbox: (row["mailbox"] as? String) ?? "")
            return seen.insert("\(found.subject)|\(address)|\(Int(stamp))").inserted ? found : nil
        }
    }

    /// Where a message file lives inside its mailbox: 56789 → Data/6/5/Messages (the thousands, last digit first).
    static func folder(of id: Int64) -> String {
        let digits = String(id / 1000).reversed().map(String.init)
        return (id < 1000 ? ["Data"] : ["Data"] + digits).joined(separator: "/") + "/Messages"
    }

    /// The mailbox's folder inside Mail's folder: imap://UUID/%5BGmail%5D/All%20Mail → UUID/[Gmail].mbox/All Mail.mbox.
    static func mailboxPath(_ url: String) -> String? {
        guard let scheme = url.range(of: "://") else { return nil }
        let parts = url[scheme.upperBound...].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        guard let account = parts.first, parts.count > 1 else { return nil }
        return ([account] + parts.dropFirst().map { $0 + ".mbox" }).joined(separator: "/")
    }

    /// The message's file on disk: inside the mailbox, or inside the folder with an id that Mail keeps there.
    static func messageFile(root: URL, row: Row) -> URL? {
        guard let path = mailboxPath(row.mailbox) else { return nil }
        let box = root.appendingPathComponent(path, isDirectory: true)
        let manager = FileManager.default
        let holders = [box] + ((try? manager.contentsOfDirectory(at: box, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.isEmpty }
        for holder in holders {
            let folder = holder.appendingPathComponent(folder(of: row.id), isDirectory: true)
            for name in ["\(row.id).emlx", "\(row.id).partial.emlx"] {
                let file = folder.appendingPathComponent(name)
                if manager.fileExists(atPath: file.path) { return file }
            }
        }
        return nil
    }

    // MARK: Recent mail per account

    /// An inbox, Sent or Trash mailbox in the index. `account` is Mail's id of its account (the host of its url), `path` the
    /// name a script reaches it by ("INBOX", "[Gmail]/Sent Mail", "Postvak IN").
    struct Box: Equatable {
        enum Kind: Equatable { case inbox, sent, trash }
        var id: Int64
        var account: String
        var path: String
        var kind: Kind
    }

    /// What Mail's inbox is called, in the languages Mail and its servers use (Exchange names it in yours).
    static let inboxNames: Set<String> = ["inbox", "postvak in", "posteingang", "boîte de réception", "bandeja de entrada"]

    static let mailboxesSQL = "SELECT ROWID AS id, url FROM mailboxes"

    /// The inbox, Sent and Trash mailboxes among Mail's mailboxes, by the last part of their url; `sentNames` and
    /// `trashNames` are their names across providers and languages (`MailChatData.sentNames`, `trashNames`).
    static func boxes(_ raw: [[String: Any]], sentNames: [String], trashNames: [String] = []) -> [Box] {
        let sent = Set(sentNames.map { $0.lowercased() })
        let trash = Set(trashNames.map { $0.lowercased() })
        return raw.compactMap { row -> Box? in
            guard let id = (row["id"] as? NSNumber)?.int64Value, let url = row["url"] as? String,
                  let scheme = url.range(of: "://") else { return nil }
            let parts = url[scheme.upperBound...].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
            guard parts.count > 1, let last = parts.last?.lowercased() else { return nil }
            let kind: Box.Kind
            if parts.count == 2, inboxNames.contains(last) {
                kind = .inbox
            } else if sent.contains(last) {
                kind = .sent
            } else if trash.contains(last) {
                kind = .trash
            } else {
                return nil
            }
            return Box(id: id, account: parts[0], path: parts.dropFirst().joined(separator: "/"), kind: kind)
        }
    }

    /// The messages in a mailbox: the ones stored in it, and the ones it holds as a label (Gmail keeps every message in
    /// All Mail and its inbox as a label on it).
    private static func members(_ box: Int64) -> String {
        "m.ROWID IN (SELECT ROWID FROM messages WHERE mailbox = \(box) UNION SELECT message_id FROM labels WHERE mailbox_id = \(box))"
    }

    /// The newest `limit` messages of one mailbox, with what the Chats tab and the Mail connector show of each: subject
    /// (with its "Re: "), sender, first To recipient, date, read, replied (flag bit 2, Mail's "was replied to"), Mail's
    /// own summary of the text, and the mailbox its file is in.
    static func recentSQL(box: Int64, limit: Int) -> String {
        select(where: members(box), limit: limit)
    }

    /// One person's mail in these mailboxes received in [`from`, `to`), newest first: what they sent, and what went to
    /// them (To or Cc), for Nook's archive of a mail chat (`MailBridge.backfillPage`).
    static func historySQL(boxes: [Int64], address: String, from: Date, to: Date, limit: Int) -> String {
        let who = "'" + address.lowercased().replacingOccurrences(of: "'", with: "''") + "'"
        let inBoxes = boxes.map { "(\(members($0)))" }.joined(separator: " OR ")
        let person = "(a.address = \(who) COLLATE NOCASE OR EXISTS (SELECT 1 FROM recipients r JOIN addresses x ON x.ROWID = r.address "
            + "WHERE r.message = m.ROWID AND x.address = \(who) COLLATE NOCASE))"
        let when = "m.date_received >= \(Int(from.timeIntervalSince1970)) AND m.date_received < \(Int(to.timeIntervalSince1970.rounded(.up)))"
        return select(where: "(\(inBoxes.isEmpty ? "0" : inBoxes)) AND \(person) AND \(when)", limit: limit)
    }

    private static func select(where condition: String, limit: Int) -> String {
        """
        SELECT m.ROWID AS id, COALESCE(m.subject_prefix, '') || s.subject AS subject, a.address AS address, a.comment AS name,
               m.date_received AS date, m.read AS read, (m.flags >> 2) & 1 AS replied, su.summary AS summary, b.url AS mailbox,
               (SELECT x.address FROM recipients r JOIN addresses x ON x.ROWID = r.address WHERE r.message = m.ROWID AND r.type = 0
                ORDER BY r.position LIMIT 1) AS to_address,
               (SELECT x.comment FROM recipients r JOIN addresses x ON x.ROWID = r.address WHERE r.message = m.ROWID AND r.type = 0
                ORDER BY r.position LIMIT 1) AS to_name
        FROM messages m JOIN subjects s ON s.ROWID = m.subject JOIN mailboxes b ON b.ROWID = m.mailbox
        LEFT JOIN addresses a ON a.ROWID = m.sender LEFT JOIN summaries su ON su.ROWID = m.summary
        WHERE m.deleted = 0 AND \(condition)
        ORDER BY m.date_received DESC LIMIT \(limit)
        """
    }

    /// How many messages in the mailbox are unread.
    static func unreadSQL(box: Int64) -> String {
        "SELECT count(*) AS unread FROM messages m WHERE m.deleted = 0 AND m.read = 0 AND \(members(box))"
    }

    /// A mark that changes whenever mail comes, goes, or is read or unread anywhere in Mail: the newest message and the
    /// counts Mail keeps per mailbox. Cheap, so it can be asked every round without Mail noticing.
    static let changeSQL = """
    SELECT (SELECT max(ROWID) FROM messages) || '|' || (SELECT total(unread_count) FROM mailboxes) || '|' ||
           (SELECT total(total_count) FROM mailboxes) AS mark
    """

    /// One message as `recentSQL` lists it.
    struct Recent: Equatable {
        var id: Int64
        var subject: String
        /// "Name <address>", or the address alone.
        var sender: String
        var recipient: String
        var date: Date
        var read: Bool
        var replied: Bool
        var summary: String
        /// The url of the mailbox its file is in (All Mail for a Gmail inbox message), for `messageFile`.
        var mailbox: String
    }

    static func recent(_ raw: [[String: Any]]) -> [Recent] {
        func person(_ address: Any?, _ name: Any?) -> String {
            let address = (address as? String) ?? ""
            let name = ((name as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { return name }
            return name.isEmpty ? address : "\(name) <\(address)>"
        }
        return raw.compactMap { row -> Recent? in
            guard let id = (row["id"] as? NSNumber)?.int64Value, let stamp = (row["date"] as? NSNumber)?.doubleValue else { return nil }
            return Recent(id: id, subject: (row["subject"] as? String) ?? "", sender: person(row["address"], row["name"]),
                          recipient: person(row["to_address"], row["to_name"]), date: Date(timeIntervalSince1970: stamp),
                          read: ((row["read"] as? NSNumber)?.intValue ?? 0) != 0,
                          replied: ((row["replied"] as? NSNumber)?.intValue ?? 0) != 0,
                          summary: (row["summary"] as? String) ?? "", mailbox: (row["mailbox"] as? String) ?? "")
        }
    }

    // MARK: Reading a message file

    struct Message: Equatable {
        var id: String
        var text: String
    }

    /// An .emlx file: a line with the length, the message itself, and Mail's own notes after it.
    static func message(emlx data: Data) -> Message? {
        guard let newline = data.firstIndex(of: 10),
              let length = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)) else { return nil }
        let start = data.index(after: newline)
        let end = min(start + length, data.endIndex)
        guard start < end else { return nil }
        // Bytes stay bytes as Latin-1 characters until a part says which encoding it has.
        let raw = String(data: data[start..<end], encoding: .isoLatin1) ?? ""
        let part = Part(raw)
        let id = (part.headers["message-id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        return Message(id: id, text: part.text().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct Part {
        var headers: [String: String] = [:]
        var body = ""

        init(_ raw: String) {
            let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            let split = text.range(of: "\n\n")
            let head = split.map { String(text[..<$0.lowerBound]) } ?? text
            body = split.map { String(text[$0.upperBound...]) } ?? ""
            var name = ""
            for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.first == " " || line.first == "\t" {
                    headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                } else if let colon = line.firstIndex(of: ":") {
                    name = line[..<colon].lowercased()
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        private func parameter(_ name: String) -> String? {
            guard let type = headers["content-type"],
                  let range = type.range(of: #"(?i)\b"# + name + #"="?([^";]+)"?"#, options: .regularExpression) else { return nil }
            let found = type[range]
            guard let equals = found.firstIndex(of: "=") else { return nil }
            return found[found.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }

        /// The readable text: plain text when there is any, otherwise the HTML without its tags.
        func text() -> String {
            let type = (headers["content-type"] ?? "text/plain").lowercased()
            if type.hasPrefix("multipart/"), let boundary = parameter("boundary") {
                let parts = body.components(separatedBy: "--" + boundary).dropFirst().filter { !$0.hasPrefix("--") }.map { Part(String($0.drop { $0 == "\n" })) }
                let plain = parts.first { ($0.headers["content-type"] ?? "text/plain").lowercased().hasPrefix("text/plain") && !$0.isAttachment }
                if let plain { return plain.text() }
                return parts.lazy.filter { !$0.isAttachment }.map { $0.text() }.first { !$0.isEmpty } ?? ""
            }
            guard type.hasPrefix("text/"), !isAttachment else { return "" }
            let decoded = Self.decoded(body, encoding: (headers["content-transfer-encoding"] ?? "").lowercased(), charset: parameter("charset"))
            return type.hasPrefix("text/html") ? Self.withoutTags(decoded) : decoded
        }

        private var isAttachment: Bool { (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") }

        private static func decoded(_ body: String, encoding: String, charset: String?) -> String {
            let bytes: Data
            switch encoding {
            case "base64":
                bytes = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
            case "quoted-printable":
                bytes = quotedPrintable(body)
            default:
                bytes = Data(body.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            }
            switch (charset ?? "utf-8").lowercased() {
            case "iso-8859-1", "latin1": return String(data: bytes, encoding: .isoLatin1) ?? ""
            case "windows-1252", "cp1252": return String(data: bytes, encoding: .windowsCP1252) ?? ""
            default: return String(decoding: bytes, as: UTF8.self)
            }
        }

        private static func quotedPrintable(_ text: String) -> Data {
            var output = Data()
            let bytes = Array(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            var index = 0
            func digit(_ byte: UInt8) -> UInt8? { Character(UnicodeScalar(byte)).hexDigitValue.map(UInt8.init) }
            while index < bytes.count {
                if bytes[index] == 61 {
                    if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                    if index + 2 < bytes.count, let high = digit(bytes[index + 1]), let low = digit(bytes[index + 2]) {
                        output.append(high << 4 | low)
                        index += 3
                        continue
                    }
                }
                output.append(bytes[index])
                index += 1
            }
            return output
        }

        private static func withoutTags(_ html: String) -> String {
            html.replacingOccurrences(of: #"(?is)<(style|script)\b.*?</\1>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)<(br|/p|/div|/tr)\b[^>]*>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\n\s*\n\s*"#, with: "\n\n", options: .regularExpression)
        }
    }
}
