import Foundation

/// A real calendar invitation (iCalendar, RFC 5545, `METHOD:REQUEST`) that goes with a mail draft as `invite.ics`.
/// macOS gives apps no way to invite attendees to an event, but Mail, Gmail, Outlook and Apple Calendar all show an
/// attached `.ics` request as an invitation with Accept and Decline. So "plan lunch with Jan on Tuesday and invite him"
/// becomes one draft the user sends. Foundation-only; `compose_mail`'s `invite` builds it.
enum CalendarInvite {
    struct Event: Equatable {
        var title: String
        var start: Date
        var end: Date
        var location: String = ""
        var notes: String = ""
        /// The user's own address; left out when unknown (Mail then sends it from the default account).
        var organizer: String = ""
        var attendees: [String] = []
        var uid: String = UUID().uuidString.lowercased() + "@nook"
        var stamp: Date = Date()
    }

    /// The whole file, CRLF line endings and lines folded at 75 octets as the standard asks.
    static func ics(_ event: Event) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Nook//Nook//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:\(event.uid)",
            "DTSTAMP:\(utc(event.stamp))",
            "DTSTART:\(utc(event.start))",
            "DTEND:\(utc(max(event.end, event.start.addingTimeInterval(60))))",
            "SUMMARY:\(escape(event.title))"
        ]
        if !event.location.isEmpty { lines.append("LOCATION:\(escape(event.location))") }
        if !event.notes.isEmpty { lines.append("DESCRIPTION:\(escape(event.notes))") }
        let organizer = event.organizer.trimmingCharacters(in: .whitespaces).lowercased()
        if isAddress(organizer) { lines.append("ORGANIZER:mailto:\(organizer)") }
        var seen: Set<String> = [organizer]
        for raw in event.attendees {
            let address = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard isAddress(address), seen.insert(address).inserted else { continue }
            lines.append("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(address)")
        }
        lines += ["SEQUENCE:0", "STATUS:CONFIRMED", "TRANSP:OPAQUE", "END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Writes the invitation as `invite.ics` in a folder of its own under `folder` (one per draft, so two drafts never
    /// share a file) and returns its path.
    static func write(_ event: Event, in folder: URL) throws -> String {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("invite.ics")
        try Data(ics(event).utf8).write(to: file, options: .atomic)
        return file.path
    }

    /// The fields of `compose_mail`'s `invite`, nil when it has no title or no start time it can read.
    static func event(from input: [String: Any], attendees: [String], organizer: String, parse: (String) -> Date?) -> Event? {
        func text(_ key: String) -> String { ((input[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text("title").isEmpty, let start = parse(text("start")) else { return nil }
        let end = parse(text("end")).flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        return Event(title: text("title"), start: start, end: end, location: text("location"), notes: text("notes"),
                     organizer: organizer, attendees: attendees)
    }

    static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// TEXT values: backslash, semicolon, comma and line breaks escaped.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// A content line longer than 75 octets continues on the next line after a space, never inside a character.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var parts: [String] = []
        var current = ""
        var size = 0
        for character in line {
            let width = String(character).utf8.count
            let limit = parts.isEmpty ? 75 : 74
            if size + width > limit {
                parts.append(current)
                current = ""
                size = 0
            }
            current.append(character)
            size += width
        }
        parts.append(current)
        return parts.joined(separator: "\r\n ")
    }

    private static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !text.contains(" ") && !text.contains(":")
    }
}
