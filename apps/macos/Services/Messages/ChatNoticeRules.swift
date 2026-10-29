// Which chats reach you, the same rules for every chat app: per kind of chat (groups only when they mention you, status
// updates and channels never), per chat (automatic, loud, muted), and chats you hid. WhatsApp had these alone
// (`WAFilters`); they are every app's now, kept by the chat's id in `ChatInbox`. Foundation only, so it is tested
// anywhere.
import Foundation

/// What one chat does when a message arrives.
enum ChatMode: String, CaseIterable, Codable, Sendable {
    /// Follows the rule of its kind (`ChatNoticeRules.quietKinds`).
    case automatic
    /// Always reaches you, even a group without a mention or a channel.
    case loud
    /// Never reaches you; the chat is kept and can be opened.
    case muted
}

struct ChatNoticeRules: Codable, Equatable, Sendable {
    /// Per app, the kinds of chat that stay quiet (a group still reaches you when a message mentions you). An app not
    /// in here follows `defaultQuietKinds`.
    var quietKinds: [String: Set<ChatKind>] = [:]
    /// Per chat (its id in `ChatInbox`): louder or quieter than its kind. Absent means automatic.
    var modes: [String: ChatMode] = [:]
    /// Chats you hid (their ids in `ChatInbox`): never shown, never counted, never told, until you show them again.
    var hidden: Set<String> = []

    /// What each app does before you chose: WhatsApp keeps groups, status updates and channels quiet, as it always did;
    /// every other app tells you about every chat, as it always did.
    static let defaultQuietKinds: [String: Set<ChatKind>] = ["whatsapp": [.group, .status, .channel]]

    /// The kinds of chat that stay quiet in this app.
    func quietKinds(for app: String) -> Set<ChatKind> {
        quietKinds[app] ?? Self.defaultQuietKinds[app] ?? []
    }

    /// Keeps a kind of chat quiet in an app, or lets it reach you.
    mutating func setQuiet(_ quiet: Bool, kind: ChatKind, app: String) {
        var kinds = quietKinds(for: app)
        if quiet { kinds.insert(kind) } else { kinds.remove(kind) }
        quietKinds[app] = kinds
    }

    func mode(for chat: String) -> ChatMode { modes[chat] ?? .automatic }

    mutating func setMode(_ mode: ChatMode, for chat: String) {
        modes[chat] = mode == .automatic ? nil : mode
    }

    func isHidden(_ chat: String) -> Bool { hidden.contains(chat) }

    mutating func setHidden(_ hide: Bool, chat: String) {
        if hide { hidden.insert(chat) } else { hidden.remove(chat) }
    }

    /// Whether a chat's kind keeps it quiet in its app, before any per-chat choice. A chat whose kind its app does not
    /// say is treated as a person's.
    func kindIsQuiet(_ kind: ChatKind?, app: String) -> Bool {
        quietKinds(for: app).contains(kind ?? .person)
    }

    /// Whether a new message in this chat stays silent: hidden, the per-chat choice, then the kind's rule. A mention in
    /// an automatic group still reaches you; a muted or hidden chat never does.
    func isQuiet(chat: String, app: String, kind: ChatKind?, mentionsMe: Bool = false) -> Bool {
        if isHidden(chat) { return true }
        switch mode(for: chat) {
        case .loud: return false
        case .muted: return true
        case .automatic: return kindIsQuiet(kind, app: app) && !(kind == .group && mentionsMe)
        }
    }

    /// Whether a chat counts in Nook's badges and in what Nook tells about your chats: not when it is hidden, nor when it
    /// is quiet (muted, or by its kind), unless one of its messages from someone else would reach you anyway (a group
    /// that mentioned you). As WhatsApp's own list did (`WAInbox.visible`).
    func isVisible(_ thread: InboxThread) -> Bool {
        guard !isHidden(thread.id) else { return false }
        if !isQuiet(chat: thread.id, app: thread.app, kind: thread.kind) { return true }
        return thread.messages.contains { message in
            !message.isMine && !isQuiet(chat: thread.id, app: thread.app, kind: thread.kind, mentionsMe: message.mentionsMe == true)
        }
    }

    /// The rules from what Settings › WhatsApp kept before every app had them (`WAFilters`, by WhatsApp's chat ids):
    /// its three kinds, its per-chat choices and its hidden chats, now by the chats' ids in `ChatInbox`. `ids` gives the
    /// ids a WhatsApp chat id has in Nook: one per linked account, since WhatsApp's choices held for all of them.
    static func migrated(from old: ChatNoticeRules = ChatNoticeRules(), muteGroups: Bool, muteStatus: Bool, muteChannels: Bool,
                         ignored: Set<String>, modes: [String: String], ids: (String) -> [String]) -> ChatNoticeRules {
        var rules = old
        var kinds: Set<ChatKind> = []
        if muteGroups { kinds.insert(.group) }
        if muteStatus { kinds.insert(.status) }
        if muteChannels { kinds.insert(.channel) }
        rules.quietKinds["whatsapp"] = kinds
        for chat in ignored { for id in ids(chat) { rules.hidden.insert(id) } }
        for (chat, raw) in modes {
            guard let mode = ChatMode(rawValue: raw) else { continue }
            for id in ids(chat) where rules.modes[id] == nil { rules.setMode(mode, for: id) }
        }
        return rules
    }
}

extension ChatInbox {
    /// What Nook's badges count: every chat's unread messages, except in chats the rules keep out (`isVisible`).
    func visibleUnread(_ rules: ChatNoticeRules) -> Int {
        threads.values.reduce(0) { $0 + (rules.isVisible($1) ? $1.unread : 0) }
    }
}
