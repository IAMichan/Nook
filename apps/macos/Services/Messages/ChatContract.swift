// What every chat app promises in the Chats tab: one list of what Nook can do in a chat, one set of checks before any
// action goes to the app, one name per action in the audit log, and one way to wait after a failed read. Each app's
// bridge only translates; these rules hold for all of them (`docs/INTEGRATIONS.md`). Foundation only, so it is tested
// anywhere.
import Foundation

/// What Nook can do in a chat: one list for every app, so the Chats tab offers the same things everywhere, each as far
/// as the app's own service lets Nook do it. The same list also decides what an action may do (`ChatAction.refusal`),
/// so a button and the action behind it never disagree.
struct ChatAbilities: Equatable {
    /// Text goes to the chat (else it is copied for the app).
    var send = false
    /// What can go besides text.
    var sends: Set<ChatOutgoing.Kind> = []
    /// An answer quotes the message it answers.
    var reply = false
    var react = false
    /// Your own messages can be changed and deleted for everyone.
    var edit = false
    var delete = false
    /// "Mark as read in <app>" tells the app itself, instead of opening it.
    var markRead = false
    /// The chat can be pinned, muted and archived in its app; `pinned` and `muted` say where it stands.
    var pin = false
    var mute = false
    var archive = false
    var pinned = false
    var muted = false
    /// A poll in the chat can be voted on from Nook.
    var vote = false
    /// "Delete for me" also deletes the message in the app itself, for you on all your devices (else only in Nook).
    var deleteForMe = false

    /// Whether the chat's app takes this action from Nook.
    func allows(_ action: ChatAction) -> Bool {
        switch action {
        case .send: return send
        case .sendItem(let kind): return send && sends.contains(kind)
        case .react: return react
        case .edit: return edit
        case .delete: return delete
        case .markRead: return markRead
        case .pin: return pin
        case .mute: return mute
        case .archive: return archive
        case .vote: return vote
        }
    }
}

/// One thing you do in a chat from Nook, always after your own click or Return. Every app goes through the same steps
/// (`AppModel.runInChat`): the checks here, then the app's bridge, then the chat is read again from its app and the
/// action is logged under one name, whichever app it went to.
enum ChatAction: Equatable {
    case send
    case sendItem(ChatOutgoing.Kind)
    case react
    case edit
    case delete
    case markRead
    case pin
    case mute
    case archive
    case vote

    /// Why an action cannot go, the same for every app; nil when it can.
    enum Refusal: String, Equatable {
        /// The chat's app does not take it from Nook.
        case unsupported = "chat.compose.unsupported"
        /// No text to send, or to change a message into.
        case empty = "whatsapp.reply.empty"
        /// Only your own messages can be changed or deleted for everyone.
        case notMine = "chat.action.notMine"
    }

    /// The name in the audit log (`nook.sqlite`), the same for every app: which app it went to is in the entry itself.
    var auditTool: String {
        switch self {
        case .send, .sendItem: return "chat_send"
        case .react: return "chat_react"
        case .edit: return "chat_edit"
        case .delete: return "chat_delete"
        case .markRead: return "chat_mark_read"
        case .pin: return "chat_pin"
        case .mute: return "chat_mute"
        case .archive: return "chat_archive"
        case .vote: return "chat_vote"
        }
    }

    /// What has to hold before the action goes to any app: the app takes it, there is text where text is sent, and a
    /// message changed or deleted for everyone is yours. `text` is what is sent or the new text; `fromMe` whether the
    /// message acted on is yours.
    func refusal(_ abilities: ChatAbilities, text: String? = nil, fromMe: Bool = true) -> Refusal? {
        guard abilities.allows(self) else { return .unsupported }
        switch self {
        case .send, .edit:
            if (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        default:
            break
        }
        switch self {
        case .edit, .delete:
            if !fromMe { return .notMine }
        default:
            break
        }
        return nil
    }
}

/// Where a linked chat app's account stands, the same for every app in Settings › Chats (`ChatLinkedAccountRow`):
/// reading, switched off in Nook, failing for a passing reason (the service busy, no network), or signed out, which only
/// signing in again mends.
enum ChatAccountHealth: Equatable {
    case working
    case off
    case failing(String)
    case signedOut(String)

    /// `collecting`: chats are collected at all; `shown`: this app's chats are on; `problem`: why its last read failed;
    /// `signedOut`: that failure was a lost sign-in.
    static func of(collecting: Bool, shown: Bool, problem: String?, signedOut: Bool) -> ChatAccountHealth {
        if let problem { return signedOut ? .signedOut(problem) : .failing(problem) }
        return collecting && shown ? .working : .off
    }

    /// The account's line under its name: what is wrong when something is, else `working` (or `off`).
    func detail(working: String, off: String) -> String {
        switch self {
        case .working: return working
        case .off: return off
        case .failing(let why), .signedOut(let why): return why
        }
    }

    var isProblem: Bool {
        switch self {
        case .failing, .signedOut: return true
        case .working, .off: return false
        }
    }
}

/// How long a chat app's bridge waits after a read failed, the same for every app: a minute (or its own interval when
/// that is longer), then twice as long after each failure in a row, up to a quarter of an hour. A service that refuses
/// (a lost sign-in, a rate limit, no network) is then asked a few times an hour instead of every minute, and a read that
/// works again starts over.
enum ChatBackoff {
    static let first: TimeInterval = 60
    static let longest: TimeInterval = 15 * 60

    static func delay(interval: TimeInterval, failures: Int) -> TimeInterval {
        let start = max(interval, first)
        let doublings = Double(min(max(failures, 1) - 1, 16))
        return min(start * pow(2, doublings), max(longest, start))
    }
}
