import Foundation

// How far your own messages got, in every chat app Nook reads: sent, delivered, read, and in a group with whom. Each app
// says it in its own way (WhatsApp per member, Telegram as "read up to here", Messages per message); this file is the
// one shape they all end up in. Foundation only, so it can be tested anywhere.

/// How far your own message got, as WhatsApp's ticks show it: a clock while it goes out, one grey tick when the app's
/// server has it, two when it reached them, two blue ones once it was read, a red mark when it could not be sent.
enum ChatReceipt: Int, Codable, Comparable, Sendable {
    case failed = -1, pending, sent, delivered, read

    static func < (a: ChatReceipt, b: ChatReceipt) -> Bool { a.rawValue < b.rawValue }

    /// A gateway's status word: OpenWA's `pending|sent|delivered|read|played|failed`, GOWA's `delivered|read|played`.
    init?(status: String) {
        switch status.lowercased() {
        case "pending": self = .pending
        case "sent", "server": self = .sent
        case "delivered", "delivery": self = .delivered
        case "read", "played": self = .read
        case "failed", "error": self = .failed
        default: return nil
        }
    }

    /// Ticks only move forward; a failure always shows.
    func advanced(to new: ChatReceipt) -> ChatReceipt {
        new == .failed || new > self ? new : self
    }
}

/// One person in a group and how far your message got with them: still on its way, on their phone, or read (and when).
struct ChatReader: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var receipt: ChatReceipt
    /// When it reached them or they read it, when the app says.
    var date: Date? = nil

    var id: String { name }

    /// A newer receipt from the same person: it only moves forward, and keeps the time of the step it took.
    func advanced(to new: ChatReceipt, at date: Date?) -> ChatReader {
        let next = receipt.advanced(to: new)
        guard next != receipt else { return self }
        return ChatReader(name: name, receipt: next, date: date ?? self.date)
    }
}

enum ChatReceipts {
    /// A group message's ticks from its members' receipts, as WhatsApp draws them: two ticks once every member has it,
    /// two blue ones once every member read it. `members` is how many others are in the group; while that is not known
    /// the ticks stay where the app put them (`current`), since one member's receipt says nothing of the rest.
    static func overall(_ readers: [ChatReader], members: Int?, current: ChatReceipt) -> ChatReceipt {
        guard current != .failed, let members, members > 0 else { return current }
        let answered = readers.filter { $0.receipt >= .delivered }
        guard answered.count >= members else { return current }
        let lowest = answered.map(\.receipt).min() ?? current
        return current.advanced(to: lowest)
    }

    /// Everyone in the group with how far the message got with them, as the message's info lists them: who read it
    /// (the first to read on top), who has it, and the members who answered nothing yet (as `sent`). `members` are the
    /// names of the others in the group; a reader who is not among them (they left since) still shows.
    static func everyone(_ readers: [ChatReader], members: [String]) -> [ChatReader] {
        var seen = Set(readers.map { $0.name.lowercased() })
        var all = readers
        for member in members where !member.isEmpty && seen.insert(member.lowercased()).inserted {
            all.append(ChatReader(name: member, receipt: .sent))
        }
        return all.sorted { a, b in
            if a.receipt != b.receipt { return a.receipt > b.receipt }
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Your message in Messages' own database: an error is a failure, a read date (or `is_read`) is read, `is_delivered`
    /// delivered, `is_sent` sent, anything else still on its way.
    static func messages(sent: Bool, delivered: Bool, read: Bool, failed: Bool) -> ChatReceipt {
        if failed { return .failed }
        if read { return .read }
        if delivered { return .delivered }
        return sent ? .sent : .pending
    }

    /// Your message in WhatsApp's own database on this Mac (`ZWAMESSAGE.ZMESSAGESTATUS`, an undocumented field): 1 on its
    /// way, 2 to 4 on the server, 5 on their phone, 6 read, 8 a voice message played, 7 could not be sent. Nil for a
    /// status this does not know, rather than ticks that might be wrong.
    static func whatsAppDesktop(status: Int) -> ChatReceipt? {
        switch status {
        case 1: return .pending
        case 2, 3, 4: return .sent
        case 5: return .delivered
        case 6, 8: return .read
        case 7: return .failed
        default: return nil
        }
    }

    /// Telegram has no "delivered": one tick once its server has your message, two once someone read it, which the
    /// chat says as the newest of your messages that was read (`last_read_outbox_message_id`).
    static func telegram(message: Int64, readUpTo: Int64, pending: Bool, failed: Bool) -> ChatReceipt {
        if failed { return .failed }
        if pending { return .pending }
        return message <= readUpTo ? .read : .sent
    }
}
