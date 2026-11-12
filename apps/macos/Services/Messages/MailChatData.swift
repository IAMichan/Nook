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
        /// Where it stood in its mailbox when it was read (`message n of mailbox`): finding it there is instant, while
        /// finding it by its id makes Mail search the whole mailbox (`locate`). Nil when the read did not say.
        var index: Int? = nil

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
    /// `MailStats.recentScript` does). Lines: "IN|||mailbox|||id|||subject|||sender|||date|||read|||place", and
    /// "OUT|||mailbox|||id|||subject|||recipient|||date|||place" with the first recipient as "Name <address>", the place
    /// being where the message stands in its mailbox.
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
                                    set out to out & "IN|||" & boxName & "|||" & (item i of ids) & "|||" & (item i of subs) & "|||" & (item i of snds) & "|||" & stamp & "|||" & (item i of rds) & "|||" & (lo + i - 1) & linefeed
                                else
                                    set who to ""
                                    try
                                        set r to first to recipient of message (lo + i - 1) of box
                                        set who to (address of r)
                                        try
                                            set who to (name of r) & " <" & (address of r) & ">"
                                        end try
                                    end try
                                    if who is not "" then set out to out & "OUT|||" & boxName & "|||" & (item i of ids) & "|||" & (item i of subs) & "|||" & who & "|||" & stamp & "|||" & (lo + i - 1) & linefeed
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

    /// One person's mail in one account between two times (`from` included, `to` left out), with the start of each
    /// text, for Nook's archive (`MailBridge.backfill`): theirs from the inbox (Mail finds those by sender itself), yours
    /// to them from the Sent mailboxes (each mail of the stretch looked at for them among its recipients). Rows as
    /// `readScript` writes them, then "<<<BODY>>>id" + text per message (`MailStats.bodies`). The times go as seconds
    /// before now, as AppleScript has no other way to write a date that reads the same in every language.
    static func olderScript(account: String, address: String, from: Date, to: Date, now: Date = Date(),
                            length: Int = bodyLength) -> String {
        let names = sentNames.map(MailStats.quote).joined(separator: ", ")
        let who = MailStats.quote(address)
        let body = """
                                set body to content of m
                                if (length of body) > \(length) then set body to text 1 thru \(length) of body
                                set texts to texts & "<<<BODY>>>" & (id of m) & linefeed & body & linefeed
        """
        return """
        tell application "Mail"
            set acc to account \(MailStats.quote(account))
            set out to ""
            set texts to ""
            set sentNames to {\(names)}
            set hiDate to (current date) - \(max(0, Int(now.timeIntervalSince(to).rounded(.down))))
            set loDate to (current date) - \(max(0, Int(now.timeIntervalSince(from).rounded(.up))))
            repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                try
                    set boxName to name of box
                    set found to (messages of box whose date received < hiDate and date received ≥ loDate and sender contains \(who))
                    repeat with m in found
                        try
                            set stamp to ((date received of m) as «class isot» as string)
                            set out to out & "IN|||" & boxName & "|||" & (id of m) & "|||" & (subject of m) & "|||" & (sender of m) & "|||" & stamp & "|||" & (read status of m) & linefeed
        \(body)
                        end try
                    end repeat
                end try
            end repeat
            repeat with box in mailboxes of acc
                try
                    if sentNames contains (name of box) then
                        set boxName to name of box
                        set found to (messages of box whose date received < hiDate and date received ≥ loDate)
                        repeat with m in found
                            try
                                set person to ""
                                repeat with r in to recipients of m
                                    if (address of r) is \(who) then
                                        set person to (address of r)
                                        try
                                            set person to (name of r) & " <" & (address of r) & ">"
                                        end try
                                    end if
                                end repeat
                                if person is not "" then
                                    set stamp to ((date received of m) as «class isot» as string)
                                    set out to out & "OUT|||" & boxName & "|||" & (id of m) & "|||" & (subject of m) & "|||" & person & "|||" & stamp & linefeed
        \(body)
                                end if
                            end try
                        end repeat
                    end if
                end try
            end repeat
            return out & texts
        end tell
        """
    }

    /// The stretches a backfill asks Mail for, going back from `before`: three months first, each next one twice as long (31 years in all), as
    /// far back as `MailChatData.oldest`. A person you rarely write with is reached in a few questions, a busy one is
    /// asked a month at a time.
    static func olderStretches(before: Date, first: TimeInterval = 90 * 86_400, tries: Int = 7) -> [(from: Date, to: Date)] {
        var stretches: [(from: Date, to: Date)] = []
        var to = before
        var length = first
        for _ in 0..<tries {
            let from = max(oldest, to.addingTimeInterval(-length))
            guard from < to else { break }
            stretches.append((from, to))
            to = from
            length *= 2
        }
        return stretches
    }

    /// No mail is older than this (1990): where asking stops.
    static let oldest = Date(timeIntervalSince1970: 631_152_000)

    /// The account and the address of a chat's id (`chatID`), when it is one of these accounts.
    static func parts(of chatID: String, accounts: [Account]) -> (account: Account, address: String)? {
        guard let split = chatID.range(of: "~", options: .backwards) else { return nil }
        let name = String(chatID[..<split.lowerBound])
        let address = String(chatID[split.upperBound...])
        guard !address.isEmpty, let account = accounts.first(where: { $0.name == name }) else { return nil }
        return (account, address)
    }

    /// The start of the text of a few messages by their place, in one script. Output: "<<<BODY>>>id" + text per message
    /// (`MailStats.bodies` reads it).
    static func bodiesScript(_ rows: [Row], length: Int = bodyLength) -> String {
        var lines = ["tell application \"Mail\"", "set out to \"\""]
        for row in rows {
            lines.append("""
            try
            \(locate(row))
                set body to content of m
                if (length of body) > \(length) then set body to text 1 thru \(length) of body
                set out to out & "<<<BODY>>>\(row.id)" & linefeed & body & linefeed
            end try
            """)
        }
        lines += ["return out", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Marks these messages read in Mail (or unread again, `read: false`), which tells their server (and so every other
    /// device of yours).
    static func markReadScript(_ rows: [Row], read: Bool = true) -> String {
        var lines = ["tell application \"Mail\""]
        for row in rows {
            lines.append("try\n\(locate(row))\n    set read status of m to \(read)\nend try")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// One whole message, as the mail view shows it when you open it: its headers, its attachments, and its whole text
    /// (the list only keeps the start). Lines "SUBJECT|||…", "FROM|||…", "DATE|||…", "MSGID|||…", one "TO|||…", "CC|||…"
    /// and "ATT|||name|||saved path" each, then "<<<BODY>>>" and the text. With `saveTo` (a folder on this Mac) each
    /// attachment up to `ChatMedia.maxBytes` is saved there, so the mail view shows a photo as itself and opens a file
    /// with a click; Mail keeps to its sandbox, so one it may not write there goes to its own temporary folder instead.
    static func messageScript(_ row: Row, saveTo: String? = nil) -> String {
        """
        tell application "Mail"
        \(locate(row))
            set out to ""
        \(messageOutput(saveTo: saveTo))
        end tell
        """
    }

    /// How many messages at each end of a mailbox `findScript` takes in one go, before it searches mailboxes one by one.
    static let findSpan = 500

    /// One message by its id alone, for a mail Nook has no place for: it came from an earlier read or an earlier launch,
    /// or it moved to another mailbox. Every mailbox of every account, first the newest and oldest `span` mail of each in
    /// one go (quick, and where a mail nearly always is), then a search through each mailbox. The same output as
    /// `messageScript`, or nothing when Mail no longer has the message.
    static func findScript(_ id: Int, span: Int = findSpan, saveTo: String? = nil) -> String {
        """
        tell application "Mail"
            set m to missing value
            set boxes to {}
            repeat with acc in accounts
                try
                    repeat with box in mailboxes of acc
                        set end of boxes to contents of box
                    end repeat
                end try
            end repeat
            repeat with listed in boxes
                if m is missing value then
                    try
                        set box to contents of listed
                        set total to count of messages of box
                        if total > 0 then
                            set hi to \(span)
                            if hi > total then set hi to total
                            set ids to id of messages 1 thru hi of box
                            repeat with k from 1 to (count of ids)
                                if (item k of ids) is \(id) then
                                    set m to message k of box
                                    exit repeat
                                end if
                            end repeat
                            if m is missing value and total > hi then
                                set lo to total - \(span) + 1
                                if lo <= hi then set lo to hi + 1
                                set ids to id of messages lo thru total of box
                                repeat with k from 1 to (count of ids)
                                    if (item k of ids) is \(id) then
                                        set m to message (lo + k - 1) of box
                                        exit repeat
                                    end if
                                end repeat
                            end if
                        end if
                    end try
                end if
            end repeat
            repeat with listed in boxes
                if m is missing value then
                    try
                        set box to contents of listed
                        set m to \(byID(id, in: "box"))
                    end try
                end if
            end repeat
            if m is missing value then return ""
            set out to ""
        \(messageOutput(saveTo: saveTo))
        end tell
        """
    }

    /// Script lines that add message `m`, whole, to `out` and return it: "SUBJECT|||…", "FROM|||…", "DATE|||…",
    /// "MSGID|||…", one "TO|||…", "CC|||…" and "ATT|||name|||saved path" each (the path empty when it was not saved),
    /// then "<<<BODY>>>" and the text.
    private static func messageOutput(saveTo folder: String?) -> String {
        let save = folder.map { folder in
            """

                            if (file size of a) < \(ChatMedia.maxBytes) then
                                try
                                    set target to \(MailStats.quote(folder + "/")) & k & "-" & (name of a)
                                    save a in (POSIX file target)
                                    set saved to target
                                on error
                                    try
                                        set target to (POSIX path of (path to temporary items)) & "nook-" & (id of m) & "-" & k & "-" & (name of a)
                                        save a in (POSIX file target)
                                        set saved to target
                                    end try
                                end try
                            end if
            """
        } ?? ""
        return """
            set out to out & "SUBJECT|||" & (subject of m) & linefeed
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
                set k to 0
                repeat with a in mail attachments of m
                    set k to k + 1
                    set saved to ""
                    try\(save)
                    end try
                    set out to out & "ATT|||" & (name of a) & "|||" & saved & linefeed
                end repeat
            end try
            return out & "<<<BODY>>>" & linefeed & (content of m)
    """
    }

    /// Script lines (inside `tell application "Mail"`, outgoing message `m`) that attach these files on this Mac at the
    /// end of its text, each handed over as an alias so Mail (sandboxed) may read it. A mail that goes at once waits a
    /// moment first: Mail loads an attachment before it can send it. Empty without files.
    static func attachLines(_ paths: [String], send: Bool) -> String {
        guard !paths.isEmpty else { return "" }
        let files = paths.map {
            "\n        make new attachment with properties {file name:((POSIX file \(MailStats.quote($0))) as alias)} at after the last paragraph"
        }.joined()
        return "\n    tell content of m" + files + "\n    end tell" + (send ? "\n    delay 1" : "")
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
        /// Where each of `attachments` is on this Mac, in the same order; empty for one Mail did not save.
        var files: [String] = []
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
            case "ATT":
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                message.attachments.append(name)
                message.files.append(parts.count > 2 ? parts[2...].joined(separator: "|||").trimmingCharacters(in: .whitespaces) : "")
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
        byID(row.id, in: "mailbox \(MailStats.quote(row.mailbox)) of account \(MailStats.quote(row.account))")
    }

    /// A message by its id. Never "message id 42": Mail has a `message id` property (the header), so that does not
    /// compile ("Expected end of line, etc. but found number", -2741).
    static func byID(_ id: Int, in box: String) -> String {
        "first message of \(box) whose id is \(id)"
    }

    /// How far below its place a message is looked for: mail that came in since it was read moves it down.
    static let drift = 40

    /// Script lines that put one message in `m`, fast: at the place it had when it was read, else among the next
    /// `drift` places (new mail moved it), and only then by its id, which makes Mail search the whole mailbox and can take
    /// minutes in a large one (a Gmail inbox).
    static func locate(_ row: Row) -> String {
        let box = "mailbox \(MailStats.quote(row.mailbox)) of account \(MailStats.quote(row.account))"
        guard let index = row.index, index > 0 else { return "    set m to " + byID(row.id, in: box) }
        return """
            set box to \(box)
            set m to missing value
            try
                set candidate to message \(index) of box
                if (id of candidate) is \(row.id) then set m to candidate
            end try
            if m is missing value then
                try
                    set total to count of messages of box
                    set hi to \(index + drift)
                    if hi > total then set hi to total
                    set nearby to id of messages \(index) thru hi of box
                    repeat with k from 1 to (count of nearby)
                        if (item k of nearby) is \(row.id) then
                            set m to message (\(index) + k - 1) of box
                            exit repeat
                        end if
                    end repeat
                end try
            end if
            if m is missing value then set m to \(byID(row.id, in: "box"))
        """
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
            let place = incoming ? 7 : 6
            let index = parts.count > place ? Int(parts[place].trimmingCharacters(in: .whitespaces)) : nil
            return Row(account: account.name, mailbox: parts[1], id: id, subject: parts[3], person: person, date: date,
                       read: read, fromMe: !incoming || own.contains(address(person)), index: index)
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
            var chat = BridgedChat(app: app, name: name(person), messages: messages,
                                   unread: sorted.filter { !$0.fromMe && !$0.read }.count, chatID: id,
                                   account: named ? sorted.first?.account : nil, kind: automated ? .channel : .person,
                                   readKnown: true, hasOlder: false, activity: sorted.last?.date)
            // The address the conversation goes to: all mail says of the person.
            let mailbox = address(person)
            if !mailbox.isEmpty { chat.profile = ChatProfile(email: mailbox) }
            return chat
        }.sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }
    }

    /// A sender that never needs an answer (a newsletter, a notification, a no-reply address), as `MailStats` knows them.
    static func isAutomated(_ person: String) -> Bool {
        guard let pattern = MailStats.automatedPattern else { return false }
        return pattern.firstMatch(in: person, range: NSRange(person.startIndex..., in: person)) != nil
    }
}
