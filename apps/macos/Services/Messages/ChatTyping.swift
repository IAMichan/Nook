import Foundation

// Who is typing in which chat, in every chat app that says so: WhatsApp (GOWA's `chat_presence`), Telegram
// (`updateChatAction`) and the apps of Nook's chat helper (Signal, Instagram, Messenger…). Each app says it in its own
// way; this is the one shape they end up in, for the moment only and never stored. Foundation only, so it can be tested
// anywhere; `ChatTypingCenter` keeps it live for the views.

/// Someone typing in a chat, until `until` (an app repeats it while they keep typing, and may never say they stopped).
struct ChatTypist: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// Typing a message.
        case text
        /// Recording a voice message or a video.
        case recording
        /// Sending a photo, a video or a file.
        case uploading
    }

    /// Who it is, by their id in the app (to replace their own earlier word).
    var id: String
    /// Their name, as the chat shows it; empty in a private chat, whose name already says who.
    var name: String
    var kind: Kind
    var until: Date
}

/// Every chat's typists by the chat's id in the Chats tab (`ChatsEntry.id`).
struct ChatTypingState: Equatable, Sendable {
    private(set) var chats: [String: [ChatTypist]] = [:]

    /// How long a word that someone is typing holds when the app does not say: WhatsApp repeats it every few seconds and
    /// says when they stop; a missed "stopped" never leaves it standing longer than this.
    static let hold: TimeInterval = 15

    /// `person` is typing in `chat` until `until`: their earlier word is replaced.
    mutating func typing(_ person: ChatTypist, in chat: String) {
        var list = chats[chat, default: []].filter { $0.id != person.id }
        list.append(person)
        chats[chat] = list
    }

    /// `person` stopped typing in `chat`, or a message from them came in. True when that changed anything.
    @discardableResult
    mutating func stopped(_ person: String, in chat: String) -> Bool {
        guard let list = chats[chat], list.contains(where: { $0.id == person }) else { return false }
        let rest = list.filter { $0.id != person }
        chats[chat] = rest.isEmpty ? nil : rest
        return true
    }

    /// Everyone whose word ran out by `now` is gone. True when anyone was.
    @discardableResult
    mutating func expire(now: Date) -> Bool {
        var changed = false
        for (chat, list) in chats {
            let rest = list.filter { $0.until > now }
            guard rest.count != list.count else { continue }
            chats[chat] = rest.isEmpty ? nil : rest
            changed = true
        }
        return changed
    }

    /// Who is typing in `chat` at `now`, the first to start first.
    func typists(in chat: String, now: Date) -> [ChatTypist] {
        (chats[chat] ?? []).filter { $0.until > now }
    }

    /// When the next word runs out, to look again then; nil when no one types anywhere.
    var nextExpiry: Date? { chats.values.flatMap { $0 }.map(\.until).min() }
}

enum ChatTypingLine {
    /// What a chat shows while people type, as WhatsApp says it: "typing…" in a private chat, "Jan is typing…" in a group,
    /// "Jan and Anna are typing…" for two, "3 people are typing…" for more; recording and sending a file each have their
    /// own words. Nil when no one types.
    static func text(_ typists: [ChatTypist]) -> String? {
        guard let first = typists.first else { return nil }
        let names = typists.map(\.name).filter { !$0.isEmpty }
        if typists.count > 2 { return tr("chat.typing.many", typists.count) }
        if typists.count == 2, names.count == 2 { return tr("chat.typing.two", names[0], names[1]) }
        let who = names.first
        switch first.kind {
        case .text: return who.map { tr("chat.typing.named", $0) } ?? tr("chat.typing")
        case .recording: return who.map { tr("chat.recording.named", $0) } ?? tr("chat.recording")
        case .uploading: return who.map { tr("chat.uploading.named", $0) } ?? tr("chat.uploading")
        }
    }
}
