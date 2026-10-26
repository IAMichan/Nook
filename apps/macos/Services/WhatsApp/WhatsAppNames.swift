import Foundation

// Who a WhatsApp number is, and how far your messages really got, beyond what one gateway answer says. Names come from
// your own Contacts and the gateway's contact list, so a member, a reader or a sender shows by name instead of by
// number. Receipts that came in live are kept by message id on this Mac, so an older message keeps its real ticks after
// a restart, when the gateway's history has none. Foundation only; tested in Tests/NookTests/WhatsAppTests.swift.

/// One contact as a gateway lists it: its JID (a number, or an @lid) and the name the phone has for it.
struct WAContact: Equatable, Sendable {
    var jid: String
    var name: String
}

/// Names for the people behind WhatsApp ids, as WhatsApp itself shows them. A contact you saved comes first, by the name
/// you gave it (your Contacts on this Mac, then the phone's address book as the gateway lists it). After that comes the
/// name they gave themselves. A number is found by its last nine digits, as Contacts matches it. An @lid id is found
/// as itself, since it carries no number.
struct WANameBook: Equatable, Sendable {
    private var byKey: [String: String] = [:]

    init() {}

    /// `contacts`: your Contacts by `AppData.key` of each phone number. `gateway`: the gateway's contact list.
    init(contacts: [String: String], gateway: [WAContact]) {
        for contact in gateway {
            let name = contact.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !WAJID.isPlaceholderName(name, for: contact.jid), let key = Self.key(contact.jid) else { continue }
            if byKey[key] == nil { byKey[key] = name }
        }
        // Your own Contacts win: they are what you call someone.
        for (key, name) in contacts where !name.isEmpty && key.count >= 6 && key.allSatisfy(\.isNumber) {
            byKey[key] = name
        }
    }

    var isEmpty: Bool { byKey.isEmpty }

    /// The name for an id; nil when no contact has it.
    func name(_ id: String) -> String? {
        Self.key(id).flatMap { byKey[$0] }
    }

    /// The first name any of a person's ids has (their number, their @lid).
    func name(any ids: [String]) -> String? {
        ids.lazy.compactMap { name($0) }.first
    }

    /// The lookup key of an id: "lid:" and the digits for an @lid, else the last nine digits of the number (as
    /// `AppData.key` makes them). Nil for something that is no person (a group, a channel, a number too short).
    static func key(_ id: String) -> String? {
        let digits = WAJID.digits(id)
        guard digits.count >= 6, WAJID.kind(id) == .person else { return nil }
        if id.hasSuffix("@lid") { return "lid:" + digits }
        return digits.count > 9 ? String(digits.suffix(9)) : digits
    }
}

/// The ticks of your own messages as they came in live, kept on this Mac by message id: the gateways' history says
/// nothing of them, so without this an older message would only show one grey tick after a restart. It keeps how
/// far each message got and, in a group, with whom. No text is kept. The newest `limit` messages are kept.
struct WAReceiptLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var receipt: ChatReceipt
        /// In a group, each member by the id their receipt came with; in a private chat, the chat.
        var readers: [String: ChatReader] = [:]
        /// When the message was sent, to keep the newest.
        var date: Date
    }

    private(set) var entries: [String: Entry] = [:]
    /// Counts the changes, so the inbox knows when to write the ledger without comparing it whole.
    private(set) var revision = 0

    static let limit = 5_000

    /// Keeps what a message of yours shows now. True when that is more than was kept.
    @discardableResult
    mutating func record(_ message: WAMessage) -> Bool {
        guard message.fromMe, let receipt = message.receipt, receipt >= .sent else { return false }
        var entry = entries[message.id] ?? Entry(receipt: receipt, date: message.date)
        let before = entries[message.id]
        entry.receipt = entry.receipt.advanced(to: receipt)
        for (id, reader) in message.readers {
            entry.readers[id] = entry.readers[id].map { $0.advanced(to: reader.receipt, at: reader.date) } ?? reader
        }
        guard entry != before else { return false }
        store(entry, id: message.id)
        return true
    }

    /// A receipt for a message Nook does not keep in memory now (it scrolled out of the chat): kept for when the chat's
    /// history brings it back. `reader` is who it came from: a member in a group, the chat in a private one.
    @discardableResult
    mutating func note(_ id: String, receipt: ChatReceipt, reader: String?, at date: Date) -> Bool {
        guard receipt >= .delivered else { return false }
        let before = entries[id]
        var entry = before ?? Entry(receipt: .sent, date: date)
        if let reader {
            entry.readers[reader] = (entry.readers[reader] ?? ChatReader(name: reader, receipt: .sent)).advanced(to: receipt, at: date)
        } else {
            entry.receipt = entry.receipt.advanced(to: receipt)
        }
        guard entry != before else { return false }
        store(entry, id: id)
        return true
    }

    private mutating func store(_ entry: Entry, id: String) {
        entries[id] = entry
        revision &+= 1
        // Pruned in one go once it is a tenth over: not a sort for every receipt of a burst.
        if entries.count > Self.limit + Self.limit / 10 {
            let oldest = entries.sorted { $0.value.date < $1.value.date }.prefix(entries.count - Self.limit).map(\.key)
            for id in oldest { entries[id] = nil }
        }
    }

    /// A message of yours with what was kept of it added: its ticks only move forward, and every reader keeps the
    /// furthest step and the time of that step.
    func restored(_ message: WAMessage) -> WAMessage {
        guard message.fromMe, let entry = entries[message.id] else { return message }
        var message = message
        message.receipt = (message.receipt ?? .sent).advanced(to: entry.receipt)
        for (id, reader) in entry.readers {
            message.readers[id] = message.readers[id].map { $0.advanced(to: reader.receipt, at: reader.date) } ?? reader
        }
        return message
    }
}

extension WAGOWA {
    /// GOWA's `/user/my/contacts`: `{"results": {"data": [{jid, name}]}}`, the phone's contacts with their names.
    static func contacts(_ data: Data) -> [WAContact] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let list = ((json?["results"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let jid = item["jid"] as? String, let name = item["name"] as? String, !jid.isEmpty, !name.isEmpty else { return nil }
            return WAContact(jid: jid, name: name)
        }
    }
}

extension WAOpenWA {
    /// OpenWA's `/contacts`: a bare array of `{id, name, pushName, number}`. The saved name comes first, then the name
    /// they gave themselves.
    static func contacts(_ data: Data) -> [WAContact] {
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = [item["name"], item["pushName"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            return name.map { WAContact(jid: id, name: $0) }
        }
    }
}
