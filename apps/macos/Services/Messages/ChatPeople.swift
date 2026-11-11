// One card per person across chat apps: the same person in WhatsApp, Messages and Telegram is one row in the People view,
// with every conversation, the latest word, what is new, a birthday and a note of your own. Each app's bridge only gives
// its private chats (`InboxThread`); matching them is shared. Foundation only, so it is tested anywhere.
import Foundation

/// One person, with the private chats they are in.
struct ChatPerson: Equatable, Identifiable, Sendable {
    /// The same person's key in every launch: a phone number when a chat has one, else the folded name.
    var id: String
    var name: String
    /// Their chats, the newest first.
    var chats: [Chat]

    struct Chat: Equatable, Sendable {
        /// The chat's key in `ChatInbox`.
        var chat: String
        var app: String
        var last: Date
        var unread: Int
        var avatar: String?
    }

    var lastInteraction: Date { chats.first?.last ?? .distantPast }
    var unread: Int { chats.reduce(0) { $0 + $1.unread } }
    /// Their picture on this Mac from the first app that has one.
    var avatar: String? { chats.lazy.compactMap(\.avatar).first }
    /// The apps they are in, each once, the one written in last first.
    var apps: [String] {
        var seen = Set<String>()
        return chats.map(\.app).filter { seen.insert($0).inserted }
    }
}

/// What you keep about a person yourself, by their key (`ChatPerson.id`): a note and a birthday.
struct ChatPersonNotes: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var note: String = ""
        /// "MM-dd" (`NookMonthDay.stored`).
        var birthday: String?
    }

    var entries: [String: Entry] = [:]

    mutating func setNote(_ note: String, for person: String) {
        var entry = entries[person] ?? Entry()
        entry.note = note
        store(entry, for: person)
    }

    mutating func setBirthday(_ day: NookMonthDay?, for person: String) {
        var entry = entries[person] ?? Entry()
        entry.birthday = day?.stored
        store(entry, for: person)
    }

    func note(for person: String) -> String { entries[person]?.note ?? "" }

    func birthday(for person: String) -> NookMonthDay? { NookMonthDay(stored: entries[person]?.birthday) }

    /// An empty entry is not kept.
    private mutating func store(_ entry: Entry, for person: String) {
        entries[person] = entry.note.isEmpty && entry.birthday == nil ? nil : entry
    }

    /// People whose birthday falls on `date`, from the ones you listed.
    func birthdays(on date: Date, calendar: Calendar = .current) -> [String] {
        entries.filter { NookMonthDay(stored: $0.value.birthday)?.matches(date, calendar: calendar) == true }.map(\.key).sorted()
    }
}

enum ChatPeople {
    /// Finds each person once across apps. A private chat is the same person as another when they share a phone number
    /// (what the app says: `InboxThread.handle`) or, lacking one, the same name in the same letters; a group, a status
    /// update and a channel are no person. Two people who share only a first name stay two (the whole name must match).
    static func people(_ threads: [InboxThread]) -> [ChatPerson] {
        var byKey: [String: ChatPerson] = [:]
        for thread in threads where thread.noticeKind == .person {
            let last = thread.last
            guard last > .distantPast, !thread.name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let key = Self.key(name: thread.name, handle: thread.handle)
            let chat = ChatPerson.Chat(chat: thread.id, app: thread.app, last: last, unread: thread.unread, avatar: thread.avatar)
            if var person = byKey[key] {
                person.chats.append(chat)
                byKey[key] = person
            } else {
                byKey[key] = ChatPerson(id: key, name: thread.name, chats: [chat])
            }
        }
        return byKey.values.map { person in
            var person = person
            person.chats.sort { $0.last > $1.last }
            return person
        }.sorted {
            if $0.lastInteraction != $1.lastInteraction { return $0.lastInteraction > $1.lastInteraction }
            return $0.name < $1.name
        }
    }

    /// A phone number's digits (without a leading zero's country difference, the last nine count), else the folded name.
    static func key(name: String, handle: String?) -> String {
        let digits = (handle ?? "").filter(\.isNumber)
        if digits.count >= 7 { return "tel:" + String(digits.suffix(9)) }
        return "name:" + fold(name)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// People matching a search by name, the same fold on both sides.
    static func search(_ people: [ChatPerson], _ query: String) -> [ChatPerson] {
        let needle = fold(query)
        guard !needle.isEmpty else { return people }
        return people.filter { fold($0.name).contains(needle) }
    }
}
