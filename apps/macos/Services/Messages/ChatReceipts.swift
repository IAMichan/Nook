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
    /// Who it is in the app (a member's id), when known: two people can share a name. Nil for a member known by name only.
    var key: String? = nil

    var id: String { name }

    /// A newer receipt from the same person: it only moves forward, and keeps the time of the step it took.
    func advanced(to new: ChatReceipt, at date: Date?) -> ChatReader {
        let next = receipt.advanced(to: new)
        guard next != receipt else { return self }
        return ChatReader(name: name, receipt: next, date: date ?? self.date, key: key)
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

    /// Your messages' ticks as a chat shows them, oldest first, given whether each message is yours and what its app
    /// says of it. An older message of yours often comes without a word on it (a chat's history keeps none): it is in the
    /// chat, so it has at least one tick, and it got as far as a later one of yours did, since reading a chat reads what
    /// came before. In a private chat (`private`), a message they wrote after yours says it reached them. A clock stays
    /// only while no later message of yours is said to have gone out; a red mark stays as it is; their messages have none (nil).
    static func filled(_ messages: [(mine: Bool, receipt: ChatReceipt?)], private: Bool = false) -> [ChatReceipt?] {
        var later: ChatReceipt?
        /// A later message of yours that its app says went out.
        var laterWentOut = false
        var theirsLater = false
        var out = [ChatReceipt?](repeating: nil, count: messages.count)
        for index in messages.indices.reversed() {
            let message = messages[index]
            guard message.mine else {
                theirsLater = true
                continue
            }
            var receipt = message.receipt ?? .sent
            // A later message of yours went out, so this one did too: apps send in order. A clock left on it is one the
            // app never took back (WhatsApp keeps some at "waiting" for good).
            if receipt == .pending, laterWentOut { receipt = .sent }
            if receipt >= .sent, let later, later > receipt { receipt = later }
            if receipt == .sent, `private`, theirsLater { receipt = .delivered }
            if receipt >= .sent { later = max(later ?? receipt, receipt) }
            if let said = message.receipt, said >= .sent { laterWentOut = true }
            out[index] = receipt
        }
        return out
    }

    /// Every message's info with what a later one says, oldest first (one list per message, empty for theirs): someone
    /// who has or read a later message of yours has the earlier ones too, since reading a chat reads what came before.
    /// A step that comes from a later message has no time of its own (when they read the earlier one is not known).
    /// People are told apart by their `key`. Someone known by name only is matched by that name, as long as one person
    /// alone goes by it: two members called "Jan" never pass each other's reads on.
    /// `speakers` (one per message, same length as `lists`) names who wrote a message that is not yours and when: someone
    /// who wrote a message after yours has seen it, so they read it no later than that, even when the app sent no read
    /// receipt for them.
    static func filledReaders(_ lists: [[ChatReader]], speakers: [(name: String, date: Date?)?]? = nil) -> [[ChatReader]] {
        var spoken: [String: Date?] = [:]
        var later: [String: ChatReceipt] = [:]
        var byName: [String: Set<String>] = [:]
        func identityOf(_ reader: ChatReader) -> String? {
            if let key = reader.key, !key.isEmpty { return key }
            return reader.name.isEmpty ? nil : "\u{1}" + reader.name
        }
        func laterStep(_ reader: ChatReader) -> ChatReceipt? {
            if let key = reader.key, !key.isEmpty { return later[key] }
            guard let people = byName[reader.name], people.count == 1, let only = people.first else { return nil }
            return later[only]
        }
        var out = lists
        for index in lists.indices.reversed() {
            if let speaker = speakers?[index] {
                let name = speaker.name.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty { spoken[name] = speaker.date }
            }
            out[index] = lists[index].map { reader in
                if reader.receipt < .read, let when = spoken[reader.name.lowercased()] {
                    return ChatReader(name: reader.name, receipt: .read, date: when, key: reader.key)
                }
                guard reader.receipt >= .sent, let step = laterStep(reader), step > reader.receipt else { return reader }
                return ChatReader(name: reader.name, receipt: step, date: nil, key: reader.key)
            }
            for reader in out[index] where reader.receipt >= .delivered {
                guard let identity = identityOf(reader) else { continue }
                later[identity] = max(later[identity] ?? reader.receipt, reader.receipt)
                if !reader.name.isEmpty { byName[reader.name, default: []].insert(identity) }
            }
        }
        return out
    }

    /// A message's own ticks from everyone in its info: as far as the one it got least far with; nil for no one.
    static func overall(of readers: [ChatReader]) -> ChatReceipt? {
        readers.map(\.receipt).min()
    }

    /// The other person of a private chat and how far your message got with them, for the message's info as a group's
    /// has it: who read it, and when the app says. Empty while it only went out (nothing to tell yet, and all an app
    /// without receipts such as Slack ever says), when it failed, or without a name.
    static func person(_ name: String, receipt: ChatReceipt?, date: Date?) -> [ChatReader] {
        guard let receipt, receipt >= .delivered, !name.isEmpty else { return [] }
        return [ChatReader(name: name, receipt: receipt, date: date)]
    }

    /// Everyone in the group with how far the message got with them, as the message's info lists them: who read it
    /// (the first to read on top), who has it, and the members who answered nothing yet (as `sent`). `members` are the
    /// names of the others in the group; a reader who is not among them (they left since) still shows.
    static func everyone(_ readers: [ChatReader], members: [String]) -> [ChatReader] {
        // A reader without a name only says when a private chat's person read it: in a group there is no one to show.
        let named = readers.filter { !$0.name.isEmpty }
        var seen = Set(named.map { $0.name.lowercased() })
        var all = named
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

    /// Your message in Messages' own database: an error is a failure, a read date is read, `is_delivered`
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
