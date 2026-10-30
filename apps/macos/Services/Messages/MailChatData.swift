import Foundation

/// Mail in the Chats tab: every account the Mail app on this Mac holds (iCloud, Gmail, Outlook and Exchange, Yahoo, any
/// IMAP or POP account) read into the shared inbox, one chat per person you write with, per account. Their mail to you
/// comes from each account's inbox, yours to them from its Sent mailbox, and every message shows as its subject over the
/// start of its text. The AppleScript and its parsing live here, Foundation only, so they can be tested anywhere;
/// `MailBridge` runs them.
enum MailChatData {
    /// The app's source id (`MessagingApp.id`).
    static let app = "mail"

    /// The mail apps Nook collects the notifications of, as one family: the Mail app (which `MailBridge` reads itself,
    /// every account), and the others whose notifications are all Nook gets of them. Their notifications put the
    /// subject where a chat app puts who wrote in a group (`ChatCapture.notice`).
    static let apps: Set<String> = [app, "outlook", "gmail", "spark", "protonmail"]

    /// The newest messages read per inbox and per Sent mailbox.
    static let perInbox = 60
    static let perSent = 40
    /// How much of a message's text a bubble shows: the start, as Mail's own list does. The whole message is in Mail.
    static let bodyLength = 600

    struct Account: Equatable, Sendable {
        var name: String
        /// Its own addresses, lower case: mail from one of them is yours.
        var addresses: [String]
    }

    /// One message as the script lists it.
    struct Row: Equatable, Sendable {
        var account: String
        var mailbox: String
        /// Mail's own id of the message, unique on this Mac.
        var id: Int
        var subject: String
        /// The other person ("Lisa de Vries <lisa@…>"): who wrote it, or for your own mail whom you wrote.
        var person: String
        var date: Date
        var read: Bool
        var fromMe: Bool

        /// Its id in Nook.
        var nookID: String { "mail-\(id)" }
    }

    // MARK: Scripts

    /// The enabled accounts, one per line: "ACC|||name|||address,address".
    static let accountsScript = """
    tell application "Mail"
        set out to ""
        repeat with acc in accounts
            try
                if enabled of acc then
                    set addrs to email addresses of acc
                    set AppleScript's text item delimiters to ","
                    set joined to addrs as text
                    set AppleScript's text item delimiters to ""
                    set out to out & "ACC|||" & (name of acc) & "|||" & joined & linefeed
                end if
            end try
        end repeat
        return out
    end tell
    """

    /// The names Mail's Sent mailboxes go by, across providers and languages (Gmail's "Sent Mail", Outlook's "Sent
    /// Items", "Verzonden items"…).
    static let sentNames = ["Sent", "Sent Messages", "Sent Mail", "Sent Items", "Verzonden", "Verzonden berichten",
                            "Verzonden items", "Gesendet", "Gesendete Objekte", "Gesendete Elemente", "Envoyés",
                            "Messages envoyés", "Éléments envoyés", "Enviados", "Elementos enviados", "Mensajes enviados"]

    /// One account's newest inbox mail and its newest sent mail, in bulk (one Apple Event per property per mailbox, as
    /// `MailStats.recentScript` does). Lines: "IN|||mailbox|||id|||subject|||sender|||date|||read", and
    /// "OUT|||mailbox|||id|||subject|||recipient|||date" with the first recipient as "Name <address>".
    /// No handlers: `SystemControl` runs every script inside a `with timeout` block, where a handler cannot be defined.
    static func readScript(account: String, inbox: Int = perInbox, sent: Int = perSent) -> String {
        let names = sentNames.map(MailStats.quote).joined(separator: ", ")
        return """
        tell application "Mail"
            set acc to account \(MailStats.quote(account))
            set out to ""
            set sentNames to {\(names)}
            set boxes to {}
            set kinds to {}
            repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                set end of boxes to contents of box
                set end of kinds to "IN"
            end repeat
            repeat with box in mailboxes of acc
                try
                    if sentNames contains (name of box) then
                        set end of boxes to contents of box
                        set end of kinds to "OUT"
                    end if
                end try
            end repeat
            repeat with n from 1 to (count of boxes)
                set box to item n of boxes
                set boxKind to item n of kinds
                if boxKind is "IN" then
                    set wanted to \(inbox)
                else
                    set wanted to \(sent)
                end if
                try
                    set total to count of messages of box
                    if total > 0 then
                        set lo to 1
                        set hi to total
                        if total > wanted then
                            set hi to wanted
                            -- Mail usually lists the newest first; if not, take the other end.
                            if (date received of message 1 of box) < (date received of message total of box) then
                                set lo to total - (wanted - 1)
                                set hi to total
                            end if
                        end if
                        set boxName to name of box
                        set ids to id of messages lo thru hi of box
                        set subs to subject of messages lo thru hi of box
                        set dts to date received of messages lo thru hi of box
                        if boxKind is "IN" then
                            set snds to sender of messages lo thru hi of box
                            set rds to read status of messages lo thru hi of box
                        end if
                        repeat with i from 1 to (count of ids)
                            try
                                set stamp to ((item i of dts) as «class isot» as string)
                                if boxKind is "IN" then
                                    set out to out & "IN|||" & boxName & "|||" & (item i of ids) & "|||" & (item i of subs) & "|||" & (item i of snds) & "|||" & stamp & "|||" & (item i of rds) & linefeed
                                else
                                    set who to ""
                                    try
                                        set r to first to recipient of message (lo + i - 1) of box
                                        set who to (address of r)
                                        try
                                            set who to (name of r) & " <" & (address of r) & ">"
                                        end try
                                    end try
                                    if who is not "" then set out to out & "OUT|||" & boxName & "|||" & (item i of ids) & "|||" & (item i of subs) & "|||" & who & "|||" & stamp & linefeed
                                end if
                            end try
                        end repeat
                    end if
                end try
            end repeat
            return out
        end tell
        """
    }

    /// The start of the text of a few messages by their place, in one script. Output: "<<<BODY>>>id" + text per message
    /// (`MailStats.bodies` reads it).
    static func bodiesScript(_ rows: [Row], length: Int = bodyLength) -> String {
        var lines = ["tell application \"Mail\"", "set out to \"\""]
        for row in rows {
            lines.append("""
            try
                set body to content of \(reference(row))
                if (length of body) > \(length) then set body to text 1 thru \(length) of body
                set out to out & "<<<BODY>>>\(row.id)" & linefeed & body & linefeed
            end try
            """)
        }
        lines += ["return out", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Marks these messages read in Mail, which tells their server (and so every other device of yours).
    static func markReadScript(_ rows: [Row]) -> String {
        var lines = ["tell application \"Mail\""]
        for row in rows {
            lines.append("try\n    set read status of \(reference(row)) to true\nend try")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// One whole message, as the mail view shows it when you open it: its headers, its attachments by name, and its
    /// whole text (the list only keeps the start). Lines "SUBJECT|||…", "FROM|||…", "DATE|||…", "MSGID|||…", one
    /// "TO|||…", "CC|||…" and "ATT|||…" each, then "<<<BODY>>>" and the text.
    static func messageScript(_ row: Row) -> String {
        """
        tell application "Mail"
            set m to \(reference(row))
            set out to "SUBJECT|||" & (subject of m) & linefeed
            set out to out & "FROM|||" & (sender of m) & linefeed
            set out to out & "DATE|||" & ((date received of m) as «class isot» as string) & linefeed
            try
                set out to out & "MSGID|||" & (message id of m) & linefeed
            end try
            repeat with r in to recipients of m
                set who to (address of r)
                try
                    set who to (name of r) & " <" & (address of r) & ">"
                end try
                set out to out & "TO|||" & who & linefeed
            end repeat
            repeat with r in cc recipients of m
                set who to (address of r)
                try
                    set who to (name of r) & " <" & (address of r) & ">"
                end try
                set out to out & "CC|||" & who & linefeed
            end repeat
            try
                repeat with a in mail attachments of m
                    set out to out & "ATT|||" & (name of a) & linefeed
                end repeat
            end try
            return out & "<<<BODY>>>" & linefeed & (content of m)
        end tell
        """
    }

    /// A whole message, read from Mail when you open it in the mail view.
    struct Message: Equatable, Sendable {
        var subject: String
        var from: String
        var to: [String] = []
        var cc: [String] = []
        var date: Date?
        /// The message's own id ("<abc@host>" without the brackets), to open it in Mail itself.
        var messageID: String = ""
        var attachments: [String] = []
        var body: String

        /// Mail's own link to the message: opens it in Mail.
        var mailURL: URL? {
            guard !messageID.isEmpty,
                  let id = ("<" + messageID + ">").addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "message://" + id)
        }
    }

    /// Parses `messageScript` output; nil when it holds no message.
    static func message(_ raw: String, calendar: Calendar = .current) -> Message? {
        guard let marker = raw.range(of: "<<<BODY>>>") else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var message = Message(subject: "", from: "", body: "")
        for line in raw[..<marker.lowerBound].components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }
            let value = parts.dropFirst().joined(separator: "|||").trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "SUBJECT": message.subject = value
            case "FROM": message.from = value
            case "DATE": message.date = parser.date(from: String(value.prefix(19)))
            case "MSGID": message.messageID = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            case "TO" where !value.isEmpty: message.to.append(value)
            case "CC" where !value.isEmpty: message.cc.append(value)
            case "ATT" where !value.isEmpty: message.attachments.append(value)
            default: continue
            }
        }
        var body = String(raw[marker.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        message.body = body
        return message
    }

    /// A message's text in two parts: what this mail says itself, and the earlier mail it quotes (from the first quoted
    /// line or quote header on), each with its blank lines folded. Line ends of any kind become one.
    static func split(_ body: String) -> (own: String, quoted: String) {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let start = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(">") || isQuoteHeader(trimmed)
        }
        let own = start.map { Array(lines[..<$0]) } ?? lines
        let quoted = start.map { Array(lines[$0...]) } ?? []
        return (tidy(own), tidy(quoted))
    }

    /// Lines without trailing spaces, at most one blank line in a row, none at the start or end.
    static func tidy(_ lines: [String]) -> String {
        var kept: [String] = []
        for line in lines {
            let clean = line.replacingOccurrences(of: "\u{00A0}", with: " ")
            let trimmed = String(clean.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            if trimmed.isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(trimmed)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    /// The subject and the start of the text of a message as the chat keeps it (`text(subject:body:)`): the subject is
    /// the first line in bold.
    static func parts(_ text: String) -> (subject: String, body: String) {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.count > 2, first.hasPrefix("*"), first.hasSuffix("*") else { return ("", text) }
        return (String(first.dropFirst().dropLast()), lines.count > 1 ? lines[1] : "")
    }

    // MARK: Writing

    /// A new mail as the mail view opens it to write: whom, the subject and the text, ready to change before it goes.
    struct Compose: Equatable, Sendable {
        var to: String = ""
        var cc: String = ""
        var subject: String = ""
        var body: String = ""
    }

    /// The subject of a forwarded mail: "Fwd: " in front, once.
    static func forwardSubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if ["fwd:", "fw:", "wg:", "doorst:", "tr:", "rv:"].contains(where: lower.hasPrefix) { return trimmed }
        return "Fwd: " + trimmed
    }

    /// An answer to everyone on a mail: the one who wrote it and everyone it went to, without your own addresses and
    /// without anyone twice.
    static func replyAll(to message: Message, own: Set<String>) -> Compose {
        var seen = own
        func keep(_ people: [String]) -> [String] {
            people.filter { person in
                let who = address(person)
                return !who.isEmpty && seen.insert(who).inserted
            }
        }
        let to = keep([message.from] + message.to)
        let cc = keep(message.cc)
        return Compose(to: to.joined(separator: ", "), cc: cc.joined(separator: ", "),
                       subject: replySubject(message.subject))
    }

    /// A mail forwarded: its subject with "Fwd: ", and under a line for your own words its headers and its whole text.
    /// `labels` names the headers in the app's language (from, date, subject, to).
    static func forward(_ message: Message, date: String, labels: (header: String, from: String, date: String, subject: String,
                                                                  to: String)) -> Compose {
        var lines = ["", "", labels.header, "\(labels.from): \(message.from)"]
        if !date.isEmpty { lines.append("\(labels.date): \(date)") }
        lines.append("\(labels.subject): \(message.subject)")
        if !message.to.isEmpty { lines.append("\(labels.to): \(message.to.joined(separator: ", "))") }
        lines += ["", message.body.replacingOccurrences(of: "\r\n", with: "\n")]
        return Compose(subject: forwardSubject(message.subject), body: lines.joined(separator: "\n"))
    }

    /// The id Mail knows a message by, from its id in Nook ("mail-123" → 123); nil for any other message.
    static func mailID(_ nookID: String) -> Int? {
        nookID.hasPrefix("mail-") ? Int(nookID.dropFirst(5)) : nil
    }

    /// Mail's reference to one message: by its id in its mailbox, which stays the same as new mail comes in.
    static func reference(_ row: Row) -> String {
        "message id \(row.id) of mailbox \(MailStats.quote(row.mailbox)) of account \(MailStats.quote(row.account))"
    }

    // MARK: Parsing

    static func accounts(_ raw: String) -> [Account] {
        raw.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 2, parts[0] == "ACC" else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let addresses = parts.count > 2
                ? parts[2].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                : []
            return Account(name: name, addresses: addresses)
        }
    }

    /// The rows of `readScript` for `account`. A message in the inbox from one of your own addresses (mail to yourself,
    /// or a copy Mail filed there) counts as yours; `chats` leaves it out.
    static func rows(_ raw: String, account: Account, calendar: Calendar = .current) -> [Row] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let own = Set(account.addresses)
        return raw.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 6, parts[0] == "IN" || parts[0] == "OUT",
                  let id = Int(parts[2].trimmingCharacters(in: .whitespaces)),
                  let date = parser.date(from: String(parts[5].trimmingCharacters(in: .whitespaces).prefix(19))) else { return nil }
            let incoming = parts[0] == "IN"
            let person = parts[4].trimmingCharacters(in: .whitespaces)
            guard !address(person).isEmpty else { return nil }
            let read = !incoming || (parts.count > 6 && parts[6].trimmingCharacters(in: .whitespaces) == "true")
            return Row(account: account.name, mailbox: parts[1], id: id, subject: parts[3], person: person, date: date,
                       read: read, fromMe: !incoming || own.contains(address(person)))
        }
    }

    /// "Lisa de Vries <Lisa@Example.com>" → "lisa@example.com"; a bare address as itself, lower case. Empty when there is
    /// no address in it.
    static func address(_ person: String) -> String {
        if let open = person.lastIndex(of: "<"), let close = person.lastIndex(of: ">"), open < close {
            return String(person[person.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let bare = person.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        return bare.contains("@") && !bare.contains(" ") ? bare.lowercased() : ""
    }

    /// The name to show for a person: the name in front of the address, else the address itself.
    static func name(_ person: String) -> String {
        let name = MailStats.senderName(person).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        return name.isEmpty || name.contains("<") ? address(person) : name
    }

    /// A message as a chat shows it: its subject in bold over the start of its text, with the blank lines and the quoted
    /// earlier mail ("> …", "On … wrote:") left out, since the chat shows those messages itself.
    static func text(subject: String, body: String) -> String {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || isQuoteHeader(trimmed) { break }
            if trimmed.isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(trimmed)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        let start = kept.joined(separator: "\n")
        guard !subject.isEmpty else { return start }
        return start.isEmpty ? "*\(subject)*" : "*\(subject)*\n\(start)"
    }

    /// The line a mail app writes above the mail it quotes: "On Tue, Lisa wrote:", "Op di 27 okt schreef Lisa <…>:",
    /// "Am … schrieb …:", "Le … a écrit :", "El … escribió:", or the header block Outlook puts there ("From: …").
    static func isQuoteHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        let headers = ["from: ", "van: ", "von: ", "de : ", "de: ", "-----original message", "-----oorspronkelijk bericht"]
        if headers.contains(where: lower.hasPrefix) { return true }
        guard lower.hasSuffix(":") else { return false }
        return [" wrote", " schreef", " schrieb", " a écrit", " escribió"].contains { lower.contains($0) }
    }

    /// The subject of an answer: "Re: " in front, once.
    static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if ["re:", "re :", "aw:", "antw:", "sv:"].contains(where: lower.hasPrefix) { return trimmed }
        return trimmed.isEmpty ? "" : "Re: " + trimmed
    }

    /// The chat of a person in an account: its id in Nook's inbox (`BridgedChat.chatID`).
    static func chatID(account: String, address: String) -> String { account + "~" + address }

    /// Every conversation in these rows, one per person per account, newest message last in each: their mail to you,
    /// yours to them, each as its subject over the start of its text (`bodies` by Mail's id, where read). `named`
    /// puts the account's name on each chat, while there is more than one account.
    static func chats(_ rows: [Row], accounts: [Account], bodies: [Int: String], named: Bool) -> [BridgedChat] {
        var groups: [String: [Row]] = [:]
        let own = Set(accounts.flatMap(\.addresses))
        for row in rows {
            let who = address(row.person)
            // Mail between your own addresses is no conversation with someone else.
            guard !who.isEmpty, !own.contains(who) else { continue }
            groups[chatID(account: row.account, address: who), default: []].append(row)
        }
        return groups.map { id, rows in
            let sorted = rows.sorted { $0.date < $1.date }
            // Their own name, as they write it; else the name you wrote to; else the address.
            let incoming = sorted.last { !$0.fromMe }
            let person = incoming?.person ?? sorted.last?.person ?? ""
            let messages = sorted.map { row in
                // Mail in your Sent mailbox went out: one tick, as mail keeps no read receipts.
                InboxMessage(id: row.nookID, text: text(subject: row.subject, body: bodies[row.id] ?? ""), date: row.date,
                             fromMe: row.fromMe, receipt: row.fromMe ? .sent : nil,
                             senderID: row.fromMe ? nil : address(row.person))
            }
            // Newsletters and notifications are a channel: quiet unless you choose otherwise (`ChatNoticeRules`).
            let automated = incoming.map { isAutomated($0.person) } ?? false
            return BridgedChat(app: app, name: name(person), messages: messages,
                               unread: sorted.filter { !$0.fromMe && !$0.read }.count, chatID: id,
                               account: named ? sorted.first?.account : nil, kind: automated ? .channel : .person,
                               readKnown: true, hasOlder: false, activity: sorted.last?.date)
        }.sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }
    }

    /// A sender that never needs an answer (a newsletter, a notification, a no-reply address), as `MailStats` knows them.
    static func isAutomated(_ person: String) -> Bool {
        guard let pattern = MailStats.automatedPattern else { return false }
        return pattern.firstMatch(in: person, range: NSRange(person.startIndex..., in: person)) != nil
    }
}
