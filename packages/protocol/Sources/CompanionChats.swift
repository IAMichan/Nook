import Foundation

// The Chats tab on the phone does what the Mac's Chats tab does (`CompanionFeature.chatActions`): emoji, edits,
// deletions, forwarding, votes, pictures and files, read marks in Nook and in the app, pinning, muting, archiving and
// deleting a chat, older messages, a chat's info, and the photos in a chat. Every action goes through the Mac's one
// way of acting in a chat (`AppModel.runInChat`), after your own tap on the phone, and only where the chat's app takes
// it: the Mac lists per chat what it takes (`InboxChatDigest.abilities`), so the phone offers exactly what works.
// Foundation only, so the rules are tested on Linux.

/// What can be done in one chat besides reading it, as the Mac's `ChatAbilities` says for its app. The Mac lists them
/// per chat in `InboxChatDigest.abilities`; a name this build does not know (from a newer Mac) is ignored.
enum InboxAbility: String, Codable, Sendable, CaseIterable {
    /// An answer quotes the message it answers.
    case reply
    case react
    /// Your own messages can be changed, and deleted for everyone.
    case edit, delete
    /// "Delete for me" also deletes the message in the app itself (else only in Nook).
    case deleteForMe
    /// "Mark as read in <app>" tells the app itself; "Mark as unread" marks it unread there too.
    case markReadInApp, markUnreadInApp
    /// The chat can be pinned, muted and archived in its app, and deleted there for you.
    case pinInApp, muteInApp, archive, deleteChat
    case vote
    /// A picture or a file can go with your words (`CompanionRequest.images`, `CompanionRequest.attachments`).
    case photo, file

    /// The abilities in `names`, the unknown ones left out.
    static func parse(_ names: [String]?) -> Set<InboxAbility> {
        Set((names ?? []).compactMap(InboxAbility.init(rawValue:)))
    }

    static func names(_ abilities: Set<InboxAbility>) -> [String] {
        allCases.filter(abilities.contains).map(\.rawValue)
    }
}

/// One thing the phone does in a chat of the Chats tab (`CompanionOp.inboxAct`, `item` the chat), after your own tap.
struct InboxAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// Your emoji on `message` (`emoji`); the same one again takes it back.
        case react
        /// Your message `message` gets the words `text`.
        case edit
        /// Your message `message` is deleted for everyone.
        case delete
        /// `message` is deleted for you alone: gone from Nook, and from the app where it can (`InboxAbility.deleteForMe`).
        case deleteForMe
        /// Your vote on the poll `message`: the options `choices` (empty takes it back).
        case vote
        /// `message` goes to the chats `targets`, as if you sent it there.
        case forward
        /// Pinned in Nook (`value`): it stays on top of the list, for every app.
        case pin
        /// Pinned or muted in the app itself (`value`).
        case pinInApp, muteInApp
        case archive
        /// The whole chat deleted in its app, for you (a group you also leave).
        case deleteChat
        /// The chat taken out of Nook only; it comes back with a newer message.
        case remove
        /// Read in Nook only, read in the app too, or unread again.
        case markReadInNook, markReadInApp, markUnread
    }

    var kind: Kind
    var message: String? = nil
    var emoji: String? = nil
    var text: String? = nil
    var choices: [String]? = nil
    var targets: [String]? = nil
    var value: Bool? = nil

    /// The most chats one message is forwarded to at once, as on the Mac.
    static let maxTargets = 10

    /// Whether the action carries what it needs; the Mac checks again what the chat's app takes.
    var isComplete: Bool {
        switch kind {
        case .react: return message?.isEmpty == false && emoji.map { !$0.isEmpty && $0.count <= 8 } == true
        case .edit: return message?.isEmpty == false && CompanionPolicy.cleanMessage(text ?? "") != nil
        case .delete, .deleteForMe: return message?.isEmpty == false
        case .vote: return message?.isEmpty == false && choices != nil && (choices?.count ?? 0) <= 32
        case .forward: return message?.isEmpty == false && !(targets ?? []).isEmpty && (targets ?? []).count <= Self.maxTargets
        case .pin, .pinInApp, .muteInApp: return value != nil
        case .archive, .deleteChat, .remove, .markReadInNook, .markReadInApp, .markUnread: return true
        }
    }

    /// What the chat's app has to take for this action; nil for what Nook does by itself.
    var needs: InboxAbility? {
        switch kind {
        case .react: return .react
        case .edit: return .edit
        case .delete: return .delete
        case .vote: return .vote
        case .pinInApp: return .pinInApp
        case .muteInApp: return .muteInApp
        case .archive: return .archive
        case .deleteChat: return .deleteChat
        case .markReadInApp, .deleteForMe, .forward, .pin, .remove, .markReadInNook, .markUnread: return nil
        }
    }
}

/// A poll in a chat, as the Mac's `ChatPoll`: its question, its options with their votes and whether you chose them.
struct InboxPoll: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable, Identifiable {
        var text: String
        var votes: Int
        var chosen: Bool
        var id: String { text }
    }

    var question: String
    var options: [Option]
    /// More than one option may be chosen.
    var multiple: Bool
    /// The counts are known (a poll Nook found later may not know them).
    var counted: Bool

    var total: Int { options.reduce(0) { $0 + $1.votes } }
    var chosen: [String] { options.filter(\.chosen).map(\.text) }

    /// Your choice after a tap on `option`, as on the Mac: in a poll of one answer it replaces your choice (a second tap
    /// takes it back), in one of more answers it is added or taken off.
    func choice(afterTapping option: String) -> [String] {
        let now = chosen
        if now.contains(option) { return now.filter { $0 != option } }
        return multiple ? now + [option] : [option]
    }

    /// The poll with `choice` as your vote, so it shows at once, before the app confirms.
    func voting(_ choice: [String]) -> InboxPoll {
        var poll = self
        for index in poll.options.indices {
            let was = poll.options[index].chosen
            let now = choice.contains(poll.options[index].text)
            poll.options[index].chosen = now
            poll.options[index].votes = max(0, poll.options[index].votes + (now ? 1 : 0) - (was ? 1 : 0))
        }
        return poll
    }
}

/// What a chat's app says about the chat itself (`CompanionOp.inboxInfo`), as the Mac's chat info shows it: a group's
/// description, admins and people, a person's bio and details.
struct InboxChatInfo: Codable, Equatable, Sendable {
    /// One line of details: `key` says what it is ("username", "phone", "email", "title", "business", "category",
    /// "address", "website", "location", "created", "createdBy", "memberCount", "ownName"), so the phone names it in its
    /// own language; `value` is as the app says it (`created` in seconds since 1970).
    struct Detail: Codable, Equatable, Sendable {
        var key: String
        var value: String
    }

    var chat: String
    /// A group's description, or a person's bio or status line.
    var about: String?
    var members: [String]
    var admins: [String]
    /// Only admins may write in it.
    var adminsOnly: Bool
    var details: [Detail]
    /// The app's own words: blocked, a bot, verified.
    var blocked: Bool
    var bot: Bool
    var verified: Bool

    /// The most people one answer lists.
    static let maxMembers = 512
}

/// A photo of a chat message, small enough to travel in one answer (`CompanionOp.inboxMedia`): a video's first frame or
/// a sticker as well. The phone shows it in the bubble and enlarges it on a tap.
struct InboxMedia: Codable, Equatable, Sendable {
    /// The message's id (`InboxLine.id`).
    var line: String
    /// The same as `InboxLine.thumb` when it was made.
    var version: String
    /// Base64 JPEG, at most `side` pixels on its longest side.
    var jpeg: String

    static let side = 720
    /// How many photos one `inboxMedia` request asks for, so the answer stays well under a frame.
    static let batch = 3
    /// What one photo may weigh before base64.
    static let maxBytes = 64 * 1024
}

/// Paging back through a chat on the phone: the Mac sends the newest messages that fit, and older pages on request
/// (`CompanionOp.inboxOlder`). These rules keep what the phone already paged back when the newest ones change.
enum InboxPaging {
    /// How many messages one page holds at most (before what fits in a frame).
    static let pageSize = 60

    /// The phone's messages after the Mac sent the newest ones again (`latest`): the older messages the phone paged
    /// back to stay before them, so a new message does not throw away what you scrolled back to read.
    static func merge(latest: [InboxLine], into kept: [InboxLine]) -> [InboxLine] {
        guard let first = latest.first, let index = kept.firstIndex(where: { $0.id == first.id }), index > 0 else {
            // No overlap: the newest ones only, unless they all came before what is kept (never for a fresh answer).
            return latest
        }
        return Array(kept[..<index]) + latest
    }

    /// An older page (`page`, the messages before `before`) put before the phone's messages.
    static func prepend(_ page: [InboxLine], before: String, to kept: [InboxLine]) -> [InboxLine] {
        guard let index = kept.firstIndex(where: { $0.id == before }) else { return kept }
        let known = Set(kept.map(\.id))
        return page.filter { !known.contains($0.id) } + kept[index...]
    }
}
