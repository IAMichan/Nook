import Foundation

/// Changes to messages in the Mail app that the chat can propose: move to Trash, mark read or unread, flag or unflag.
/// Foundation only, so the request parsing and the AppleScript can be tested on their own; MailConnector runs the script
/// after the user approved the plan.
enum MailActions {
    enum Change: String, CaseIterable {
        case trash, read, unread, flagged, unflagged

        /// The AppleScript statement that applies the change to message `m`.
        var statement: String {
            switch self {
            case .trash: return "delete m"
            case .read: return "set read status of m to true"
            case .unread: return "set read status of m to false"
            case .flagged: return "set flagged status of m to true"
            case .unflagged: return "set flagged status of m to false"
            }
        }
    }

    /// Which inbox messages a change applies to: exact message ids, or a filter on sender and subject.
    struct Selection: Equatable {
        var ids: [String] = []
        var from: String?
        var subject: String?
        var unreadOnly = false
        /// Only mail received in the last this many days.
        var days: Int?
    }

    /// At most this many messages change in one action, so a broad filter can never empty a whole inbox.
    static let limit = 200
    /// Only the newest messages of each inbox are searched, like search_mail (Mail is slow on large mailboxes).
    static let scanned = 600

    /// The selection from a tool call. Ids come from search_mail (bare, in angle brackets, or as a message: link).
    static func selection(_ input: [String: Any]) -> Selection {
        func text(_ key: String) -> String? {
            let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        var raw: [String] = []
        if let list = input["ids"] as? [Any] { raw = list.compactMap { $0 as? String } }
        else if let single = text("ids") ?? text("id") { raw = single.components(separatedBy: CharacterSet(charactersIn: ",\n")) }
        let days = (input["days"] as? Int) ?? (input["days"] as? Double).map { Int($0) } ?? text("days").flatMap { Int($0) }
        return Selection(ids: ids(raw), from: text("from"), subject: text("subject"),
                         unreadOnly: (input["unread_only"] as? Bool) ?? false, days: days.map { min(max($0, 1), 365) })
    }

    /// Clean message ids: "message:%3Cabc@x%3E", "<abc@x>" and "id: abc@x" all become "abc@x". Duplicates are dropped.
    static func ids(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { value -> String? in
            var id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.lowercased().hasPrefix("message:") { id = String(id.dropFirst("message:".count)) }
            if id.lowercased().hasPrefix("id:") { id = String(id.dropFirst(3)) }
            id = (id.removingPercentEncoding ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "<> \n\t\""))
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// What is wrong with a request, in plain language (empty = fine). Moving to Trash needs ids or a sender or subject:
    /// "everything unread" alone is too broad to throw away, but fine to mark as read.
    static func problems(_ change: Change, _ selection: Selection) -> [String] {
        let narrowed = !selection.ids.isEmpty || selection.from != nil || selection.subject != nil
        if change == .trash, !narrowed { return ["give ids from search_mail, or a sender (from) or subject to select the mail"] }
        if !narrowed, !selection.unreadOnly, selection.days == nil {
            return ["give ids from search_mail, or a filter (from, subject, unread_only or days)"]
        }
        return []
    }

    /// One line for the plan, e.g. "Move mail from LinkedIn to Trash (last 30 days)".
    static func summary(_ change: Change, _ selection: Selection) -> String {
        var target: String
        if !selection.ids.isEmpty {
            target = selection.ids.count == 1 ? "1 message" : "\(selection.ids.count) messages"
        } else {
            var parts = [selection.unreadOnly ? "unread mail" : "mail"]
            if let from = selection.from { parts.append("from \(from)") }
            if let subject = selection.subject { parts.append("about \"\(subject)\"") }
            target = parts.joined(separator: " ")
        }
        if let days = selection.days { target += " (last \(days) days)" }
        switch change {
        case .trash: return "Move \(target) to Trash"
        case .read: return "Mark \(target) as read"
        case .unread: return "Mark \(target) as unread"
        case .flagged: return "Flag \(target)"
        case .unflagged: return "Unflag \(target)"
        }
    }

    /// The script that applies a change in every account's inbox. Output: the number changed on the first line, then
    /// "subject|||sender" per changed message.
    static func script(_ change: Change, _ selection: Selection) -> String {
        var conditions: [String] = []
        if !selection.ids.isEmpty {
            conditions.append("(" + selection.ids.map { "message id is \(quote($0))" }.joined(separator: " or ") + ")")
        }
        if let from = selection.from { conditions.append("sender contains \(quote(from))") }
        if let subject = selection.subject { conditions.append("subject contains \(quote(subject))") }
        if selection.unreadOnly { conditions.append("read status is false") }
        if selection.days != nil { conditions.append("date received > cutoff") }
        let filter = conditions.isEmpty ? "" : " whose " + conditions.joined(separator: " and ")
        let cutoff = selection.days.map { "set cutoff to (current date) - (\($0) * days)\n" } ?? ""
        return """
        \(cutoff)tell application "Mail"
            set found to {}
            repeat with acc in accounts
                repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                    set total to count of messages of box
                    if total > 0 then
                        if total > \(scanned) then
                            set hits to (messages 1 thru \(scanned) of box\(filter))
                        else
                            set hits to (messages of box\(filter))
                        end if
                        repeat with h in hits
                            if (count of found) >= \(limit) then exit repeat
                            set end of found to contents of h
                        end repeat
                    end if
                end repeat
            end repeat
            set out to ""
            set changed to 0
            repeat with m in found
                set line_ to (subject of m) & "|||" & (sender of m)
                try
                    \(change.statement)
                    set changed to changed + 1
                    set out to out & line_ & linefeed
                end try
            end repeat
            return (changed as string) & linefeed & out
        end tell
        """
    }

    /// What the model and the audit log see after the script ran.
    static func describe(_ change: Change, raw: String) -> String {
        var lines = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let count = lines.isEmpty ? 0 : (Int(lines.removeFirst().trimmingCharacters(in: .whitespaces)) ?? 0)
        guard count > 0 else { return "No matching mail found in the inbox; nothing changed." }
        let verb: String
        switch change {
        case .trash: verb = "Moved to Trash"
        case .read: verb = "Marked as read"
        case .unread: verb = "Marked as unread"
        case .flagged: verb = "Flagged"
        case .unflagged: verb = "Unflagged"
        }
        let items = lines.prefix(20).map { line -> String in
            let parts = line.components(separatedBy: "|||")
            return "- \(parts[0])" + (parts.count > 1 ? " (from \(MailStats.senderName(parts[1])))" : "")
        }
        let more = lines.count > 20 ? ["… and \(lines.count - 20) more"] : []
        let capped = count >= limit ? " (the limit per action; ask again for the rest)" : ""
        return (["\(verb): \(count) message\(count == 1 ? "" : "s")\(capped)."] + items + more).joined(separator: "\n")
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
