import Foundation

/// Ongelezen mail tellen voor de tool mail_unread: per account, per dag en per afzender, zodat het brein er meteen een
/// grafiek van kan maken. Alleen Foundation, zodat het los te testen is; het AppleScript draait in MailConnector.
enum MailStats {
    /// Ongelezen inbox-mail: eerst per account "ACC|||naam|||aantal", dan per bericht "MSG|||afzender|||datum" (hooguit 400).
    static let unreadScript = """
    tell application "Mail"
        set out to "TOTAL|||" & (unread count of inbox) & linefeed
        repeat with acc in accounts
            try
                if enabled of acc then
                    set n to 0
                    repeat with box in (mailboxes of acc whose name is "INBOX")
                        set n to n + (unread count of box)
                    end repeat
                    set out to out & "ACC|||" & (name of acc) & "|||" & n & linefeed
                end if
            end try
        end repeat
        set msgs to (messages of inbox whose read status is false)
        set n to count of msgs
        if n > 400 then set n to 400
        repeat with i from 1 to n
            set m to item i of msgs
            set out to out & "MSG|||" & (sender of m) & "|||" & ((date received of m) as «class isot» as string) & linefeed
        end repeat
        return out
    end tell
    """

    /// Maakt van de uitvoer van `unreadScript` tellingen die het brein meteen in een grafiek kan zetten.
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

    /// "Lisa de Vries <lisa@…>" → "Lisa de Vries"
    static func senderName(_ sender: String) -> String {
        if let range = sender.range(of: " <") { return String(sender[..<range.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return sender
    }
}
