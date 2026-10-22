import Foundation

/// Counts unread mail for the mail_unread tool: per account, per day and per sender, so the model can chart it right away.
/// Foundation only, so it can be tested on its own; the AppleScript runs in MailConnector.
enum MailStats {
    /// Unread inbox mail: first per account "ACC|||name|||count", then per message "MSG|||sender|||date" (at most 400).
    static let unreadScript = """
    tell application "Mail"
        set out to ""
        set total to 0
        repeat with acc in accounts
            try
                if enabled of acc then
                    set n to 0
                    repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                        set c to unread count of box
                        set n to n + c
                        if c > 0 then
                            set snds to sender of (messages of box whose read status is false)
                            set dts to date received of (messages of box whose read status is false)
                            set m to count of snds
                            if m > 400 then set m to 400
                            repeat with i from 1 to m
                                set out to out & "MSG|||" & (item i of snds) & "|||" & ((item i of dts) as «class isot» as string) & linefeed
                            end repeat
                        end if
                    end repeat
                    set total to total + n
                    set out to out & "ACC|||" & (name of acc) & "|||" & n & linefeed
                end if
            end try
        end repeat
        return "TOTAL|||" & total & linefeed & out
    end tell
    """

    /// Turns the output of `unreadScript` into counts the model can put straight into a chart.
    static func unread(_ raw: String, now: Date, calendar: Calendar = .current) -> String {
        var total = 0
        var accounts: [(String, Int)] = []
        var days: [Date: Int] = [:]
        var older = 0
        var senders: [String: Int] = [:]
        var seen = 0
        let today = calendar.startOfDay(for: now)
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|||")
            switch parts[0] {
            case "TOTAL" where parts.count >= 2:
                total = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            case "ACC" where parts.count >= 3:
                accounts.append((parts[1], Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0))
            case "MSG" where parts.count >= 3:
                seen += 1
                senders[senderName(parts[1]), default: 0] += 1
                guard let date = parser.date(from: String(parts[2].prefix(19))) else { continue }
                let day = calendar.startOfDay(for: date)
                if let age = calendar.dateComponents([.day], from: day, to: today).day, age < 14 {
                    days[day, default: 0] += 1
                } else {
                    older += 1
                }
            default:
                continue
            }
        }
        total = max(total, seen)
        guard total > 0 else { return "Geen ongelezen mail in de inbox." }

        var lines = ["Ongelezen in de inbox: \(total)"]
        let filled = accounts.filter { $0.1 > 0 }
        if filled.count > 1 || (filled.count == 1 && filled[0].1 != total) {
            lines.append("Per account: " + filled.map { "\($0.0): \($0.1)" }.joined(separator: ", "))
        }
        if seen > 0 {
            let label = DateFormatter()
            label.locale = Locale(identifier: "nl_NL")
            label.timeZone = calendar.timeZone
            label.dateFormat = "EEE d MMM"
            var perDay: [String] = []
            for offset in stride(from: 13, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                perDay.append("\(label.string(from: day)): \(days[day] ?? 0)")
            }
            lines.append("Per dag ontvangen (laatste 14 dagen, oudste eerst): " + perDay.joined(separator: ", "))
            if older > 0 { lines.append("Ouder dan 14 dagen: \(older)") }
            if seen < total { lines.append("(Per dag en afzender geteld over de nieuwste \(seen) van de \(total).)") }
            let top = senders.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8)
            lines.append("Meeste ongelezen van: " + top.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Recent inbox mail (inbox_mail)

    /// The newest messages of each account's inbox, fetched in bulk: one Apple Event per property per mailbox instead of one
    /// per message, and never a `whose` filter over the whole unified inbox (that took longer than the 25 s limit on a big
    /// mailbox). Lines: "ROW|||account|||mailbox|||index|||subject|||sender|||date|||read|||replied".
    static func recentScript(perMailbox: Int = 40) -> String {
        """
        tell application "Mail"
            set out to "TOTAL|||" & (unread count of inbox) & linefeed
            repeat with acc in accounts
                try
                    if enabled of acc then
                        set accName to name of acc
                        repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                            set total to count of messages of box
                            if total > 0 then
                                set lo to 1
                                set hi to total
                                if total > \(perMailbox) then
                                    set hi to \(perMailbox)
                                    -- Mail usually lists the newest first; if not, take the other end.
                                    if (date received of message 1 of box) < (date received of message total of box) then
                                        set lo to total - \(perMailbox - 1)
                                        set hi to total
                                    end if
                                end if
                                set boxName to name of box
                                set subs to subject of messages lo thru hi of box
                                set snds to sender of messages lo thru hi of box
                                set dts to date received of messages lo thru hi of box
                                set rds to read status of messages lo thru hi of box
                                set rps to was replied to of messages lo thru hi of box
                                repeat with i from 1 to (count of subs)
                                    set out to out & "ROW|||" & accName & "|||" & boxName & "|||" & (lo + i - 1) & "|||" & (item i of subs) & "|||" & (item i of snds) & "|||" & ((item i of dts) as «class isot» as string) & "|||" & (item i of rds) & "|||" & (item i of rps) & linefeed
                                end repeat
                            end if
                        end repeat
                    end if
                end try
            end repeat
            return out
        end tell
        """
    }

    struct InboxRow: Equatable {
        var account: String
        var mailbox: String
        var index: Int
        var subject: String
        var sender: String
        var date: Date
        var read: Bool
        var replied: Bool
        /// The start of the text, when it was read.
        var body: String = ""

        /// Stable enough to remember a body between refreshes (the index shifts when new mail arrives).
        var key: String { "\(account)|\(subject)|\(date.timeIntervalSince1970)" }
        var isAutomated: Bool {
            guard let pattern = MailStats.automatedPattern else { return false }
            return pattern.firstMatch(in: sender, range: NSRange(sender.startIndex..., in: sender)) != nil
        }
    }

    /// Senders that never need a reply (newsletters, notifications, no-reply addresses).
    static let automatedPattern = try? NSRegularExpression(pattern: automated, options: [.caseInsensitive])
    static let automated = #"no-?reply|do-?not-?reply|newsletter|notifications?@|notify@|mailer-daemon|bounce|marketing@|news@|info@.*\.(mailchimp|sendgrid)|updates?@"#

    /// Parses `recentScript` output: the unified unread count and every row, newest first.
    static func recent(_ raw: String, calendar: Calendar = .current) -> (unread: Int, rows: [InboxRow]) {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var unread = 0
        var rows: [InboxRow] = []
        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|||")
            if parts.count >= 2, parts[0] == "TOTAL" { unread = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0; continue }
            guard parts.count >= 9, parts[0] == "ROW", let index = Int(parts[3].trimmingCharacters(in: .whitespaces)),
                  let date = parser.date(from: String(parts[6].prefix(19))) else { continue }
            rows.append(InboxRow(account: parts[1], mailbox: parts[2], index: index, subject: parts[4], sender: parts[5], date: date,
                                 read: parts[7].trimmingCharacters(in: .whitespaces) == "true",
                                 replied: parts[8].trimmingCharacters(in: .whitespaces) == "true"))
        }
        return (unread, rows.sorted { $0.date > $1.date })
    }

    /// Within `days`, newest first; with `unansweredOnly` only mail from people that has no reply yet.
    static func select(_ rows: [InboxRow], now: Date, days: Int, unansweredOnly: Bool, limit: Int = 15) -> [InboxRow] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let kept = rows.filter { $0.date >= cutoff && (!unansweredOnly || (!$0.replied && !$0.isAutomated)) }
        return Array(kept.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func inbox(_ raw: String, now: Date, days: Int, unansweredOnly: Bool, limit: Int = 15, calendar: Calendar = .current) -> [InboxRow] {
        select(recent(raw, calendar: calendar).rows, now: now, days: days, unansweredOnly: unansweredOnly, limit: limit)
    }

    /// One block per message for the model: subject, sender, date, state, account and the start of the text.
    static func describe(_ rows: [InboxRow], date: (Date) -> String) -> String {
        rows.map { row in
            let state = (row.read ? "gelezen" : "ongelezen") + (row.replied ? ", beantwoord" : "")
            let body = row.body.isEmpty ? "" : "\n" + row.body
            return "### \(row.subject) | van \(row.sender) | \(date(row.date)) | \(state) | \(row.account)\(body)"
        }.joined(separator: "\n\n")
    }

    /// Fetches the start of the text of a few messages, by position, in one script. Output: "<<<BODY>>>n" + text per message.
    static func bodiesScript(_ rows: [InboxRow], length: Int = 300) -> String {
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["tell application \"Mail\"", "set out to \"\""]
        for (n, row) in rows.enumerated() {
            lines.append("""
            try
                set body to content of message \(row.index) of mailbox \(quote(row.mailbox)) of account \(quote(row.account))
                if (length of body) > \(length) then set body to text 1 thru \(length) of body
                set out to out & "<<<BODY>>>\(n)" & linefeed & body & linefeed
            end try
            """)
        }
        lines += ["return out", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Splits `bodiesScript` output into texts by row number.
    static func bodies(_ raw: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for chunk in raw.components(separatedBy: "<<<BODY>>>") where !chunk.isEmpty {
            let parts = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let n = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            result[n] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        return result
    }

    /// "Lisa de Vries <lisa@…>" → "Lisa de Vries"
    static func senderName(_ sender: String) -> String {
        if let range = sender.range(of: " <") { return String(sender[..<range.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return sender
    }
}
