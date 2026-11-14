// Who a chat is with, the same for every chat app: a phone number however it is written, an address, a name folded the
// same way everywhere, and which chat a name someone typed or said means. Each app's bridge only gives what its app says
// (`InboxThread.handle`, `ChatProfile.phone`/`email`, the chat's name); matching them is shared here. Foundation only, so
// it is tested anywhere (ChatIdentityTests).
import Foundation

/// Phone numbers and addresses, one way for every chat app: Contacts, People, the Chats tab's photos, calls, tags and
/// "send to" all read a number through here, so "+31 6 1234 5678", "0612345678" and "31612345678@s.whatsapp.net" are
/// one person everywhere.
enum ChatHandle {
    /// How many digits a phone number has: at least a short local number's six, at most E.164's fifteen. Fewer is a
    /// code or a count, never a person.
    static let digitCount = 6...15
    /// A number is known by its last nine digits, as Contacts matches a number with or without its country code.
    static let keyLength = 9

    /// The digits of a number or a WhatsApp id, in ASCII: "31612345678:3@s.whatsapp.net" → "31612345678",
    /// "+31 6 1234 5678" → "31612345678". An id's server ("@…") and device (":3") are left out.
    static func digits(_ text: String) -> String {
        var user = Substring(text)
        if let at = user.firstIndex(of: "@") {
            user = user[..<at]
            if let colon = user.firstIndex(of: ":") { user = user[..<colon] }
        }
        return String(user.compactMap { character -> Character? in
            guard character.isNumber, let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
            return Character(String(value))
        })
    }

    /// A WhatsApp id that is a phone number ("…@s.whatsapp.net", "…@c.us"): a number, not an address.
    static func isNumberID(_ text: String) -> Bool {
        guard let at = text.firstIndex(of: "@") else { return false }
        let host = text[text.index(after: at)...].lowercased()
        return host.hasSuffix("whatsapp.net") || host == "c.us"
    }

    /// A number's key: its last nine digits. Nil for something with too few digits to be a number.
    static func phoneKey(_ text: String) -> String? {
        let digits = digits(text)
        guard digits.count >= digitCount.lowerBound else { return nil }
        return String(digits.suffix(keyLength))
    }

    /// The same person however the number or address is written: an address in lowercase, a phone number by its last
    /// nine digits. Nil for an empty handle or a number too short to be one.
    static func key(_ handle: String) -> String? {
        let clean = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if clean.contains("@"), !isNumberID(clean) { return clean.lowercased() }
        return phoneKey(clean)
    }

    /// "+31 6 1234 5678" → "+31612345678" (E.164, as FaceTime and the apps' links take it); nil for what is no phone
    /// number (a username, an address, too few or too many digits). A number without "+" or "00" gets a "+" before it
    /// as written.
    static func e164(_ text: String) -> String? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A WhatsApp id ("31612345678@s.whatsapp.net") is its number.
        if let at = raw.firstIndex(of: "@") {
            guard isNumberID(raw) else { return nil }
            raw = String(raw[..<at])
        }
        guard raw.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) else { return nil }
        var digits = digits(raw)
        if raw.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        guard digitCount.contains(digits.count) else { return nil }
        return "+" + digits
    }

    /// Whether text is a phone number (`e164` reads it).
    static func isPhone(_ text: String) -> Bool { e164(text) != nil }

    /// Whether what someone asked for is meant as a number rather than a name: mostly digits, enough of them.
    static func looksLikeNumber(_ text: String) -> Bool {
        let digits = digits(text)
        return digits.count >= digitCount.lowerBound && digits.count * 2 >= text.filter({ !$0.isWhitespace }).count
    }
}

/// Names compared the same way in every chat app: without case, accents or width ("Ｊｏｓé" is "jose").
enum ChatText {
    /// Lowercase, without accents or width, trimmed.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `fold`, with every run of what is no letter or digit one space: "Anna-Marie  (Work)" → "anna marie work". What
    /// People, the Chats tab's photos and "which chat" go by.
    static func words(_ text: String) -> String {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

/// Who a private chat is with, across apps: a phone number (`ChatHandle.key`), else an address, else the name.
enum ChatIdentity {
    /// "tel:" and a number's key, else "mail:" and the address in lowercase, else "name:" and the name's words.
    static func key(name: String, phone: String?, email: String?) -> String {
        if let phone, let key = ChatHandle.phoneKey(phone), !phone.contains("@") || ChatHandle.isNumberID(phone) {
            return "tel:" + key
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), email.contains("@"), !ChatHandle.isNumberID(email) {
            return "mail:" + email.lowercased()
        }
        return "name:" + ChatText.words(name)
    }
}

extension InboxThread {
    /// The other person's phone number as their app says it: the chat's profile, else its handle when that is a number.
    var phone: String? {
        if let phone = ChatProfile.text(profile?.phone) { return phone }
        guard let handle, ChatHandle.phoneKey(handle) != nil, !handle.contains("@") || ChatHandle.isNumberID(handle) else { return nil }
        return handle
    }

    /// The other person's address as their app says it: the chat's profile, else its handle when that is one.
    var email: String? {
        if let email = ChatProfile.text(profile?.email) { return email }
        guard let handle, handle.contains("@"), !ChatHandle.isNumberID(handle) else { return nil }
        return handle
    }

    /// Who the chat is with across apps (`ChatIdentity.key`): the same person in WhatsApp, Telegram, Slack and Mail is one.
    var identity: String { ChatIdentity.key(name: name, phone: phone, email: email) }

    /// What finds the person in Contacts (a number, else an address): what the app said of them.
    var contactHandle: String? { phone ?? email }
}

/// What a name someone gave finds among chats: one chat, several that fit equally well (Nook asks which), or none.
enum ChatPick<Item> {
    case one(Item)
    case several([Item])
    case none

    /// The one chat; nil when there are several or none.
    var found: Item? {
        if case .one(let item) = self { return item }
        return nil
    }
}

/// Which chat someone means, the same for every app (Nook's answers, "@chat", chat_send, WhatsApp's own send): by its
/// id, by a number (the last nine digits), else by name: exact, then a whole word of it (a first name), then a part of
/// it, then a typo (`Fuzzy`). Two different chats that fit equally well are never guessed between: the answer is
/// `several`, and the caller asks which one.
enum ChatRecipients {
    static func pick<Item>(_ wanted: String, in items: [Item], id: (Item) -> String, name: (Item) -> String,
                           number: (Item) -> String? = { _ in nil }, isID: (String, Item) -> Bool) -> ChatPick<Item> {
        let asked = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = ChatText.words(asked)
        guard !asked.isEmpty else { return .none }
        func unique(_ found: [Item]) -> ChatPick<Item> {
            var seen = Set<String>()
            let distinct = found.filter { seen.insert(id($0)).inserted }
            switch distinct.count {
            case 0: return .none
            case 1: return .one(distinct[0])
            default: return .several(distinct)
            }
        }
        let byID = items.filter { isID(asked, $0) }
        if !byID.isEmpty { return unique(byID) }
        if ChatHandle.looksLikeNumber(asked) {
            let key = ChatHandle.phoneKey(asked)
            return unique(items.filter { item in number(item).flatMap(ChatHandle.phoneKey) == key })
        }
        guard !query.isEmpty else { return .none }
        let folded = items.map { (item: $0, name: ChatText.words(name($0))) }
        let exact = folded.filter { $0.name == query }
        if !exact.isEmpty { return unique(exact.map(\.item)) }
        let word = folded.filter { $0.name.split(separator: " ").contains { String($0) == query } }
        if !word.isEmpty { return unique(word.map(\.item)) }
        guard query.count >= 3 else { return .none }
        let partly = folded.filter { $0.name.contains(query) }
        if !partly.isEmpty { return unique(partly.map(\.item)) }
        // A typo ("Lsia"): the one name that is close, never a guess between two.
        guard let close = Fuzzy.best(asked, in: items.map(name)) else { return .none }
        return unique(items.filter { name($0) == close })
    }
}
