import Foundation

/// Bringing over, once, what someone set up in Beeper Desktop, so moving to Nook does not mean setting it all up again.
/// Nook no longer reads chats through Beeper; for the move it asks Beeper Desktop's local API (Beeper › Settings ›
/// Developers, port 23373, only on this Mac) one last time: which apps are linked there and as whom, the chats with
/// their recent history, and which chats are pinned, muted or archived. The apps are switched on in Nook, the history
/// lands in the Chats tab, and the pins, mutes and archives follow each chat once its app is linked in Nook.
///
/// What cannot come over is an app's sign-in itself: Beeper keeps those (on its servers, or encrypted on this Mac) and
/// its API does not hand them out. Each app is linked again in Nook, one click each, with the account Beeper knew shown
/// next to it. Foundation only, so it can be tested anywhere; `BeeperImporter` makes the calls.
enum BeeperImport {
    /// Beeper Desktop's local API.
    static let base = URL(string: "http://localhost:23373")!
    /// Where Nook kept Beeper's access token while it read Beeper (Settings › Chats, or the WhatsApp gateway's).
    static let tokenAccount = "chats.beeper.token"
    static let bundleID = "com.automattic.beeper.desktop"
    /// Chats and messages per chat brought over, as many as Nook keeps of a chat.
    static let chatCount = 200
    static let history = 50
    /// Apps whose chats come back with their own history once linked in Nook, and are not brought over: WhatsApp's
    /// come from your phone, as a chat of its own in the Chats tab.
    static let ownHistory: Set<String> = ["whatsapp"]

    // MARK: Accounts

    /// One account linked in Beeper: the app in Nook it belongs to, and who it is.
    struct Account: Equatable, Sendable, Identifiable {
        var id: String
        /// The app in Nook (`MessagingApp.id`).
        var app: String
        /// Who it is: the name the app knows, else the username, the phone number or the address.
        var name: String
    }

    /// `GET /v1/accounts` (a list, or `{items}`): every account of an app Nook knows, one per app and account, in
    /// Beeper's order. Beeper's own chat network (its Matrix account) is no app of its own in Nook and is left out.
    static func accounts(_ root: Any?) -> [Account] {
        let list = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        var seen: Set<String> = []
        return list.compactMap { account in
            let id = (account["accountID"] as? String) ?? (account["id"] as? String) ?? ""
            let network = (account["network"] as? String) ?? (account["networkName"] as? String) ?? ""
            guard !id.isEmpty, let app = ChatServiceData.app(network: network, account: id) else { return nil }
            let user = account["user"] as? [String: Any] ?? [:]
            let name = ["fullName", "displayName", "username", "phoneNumber", "email"].lazy
                .compactMap { (user[$0] as? String)?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            guard seen.insert(app + "|" + name).inserted else { return nil }
            return Account(id: id, app: app, name: name)
        }
    }

    /// The apps the accounts belong to, each once, in their order.
    static func apps(_ accounts: [Account]) -> [String] {
        var seen: Set<String> = []
        return accounts.map(\.app).filter { seen.insert($0).inserted }
    }

    // MARK: Chat settings

    /// What Beeper had set for one chat. It is matched to the chat by its app and name once that app is linked in Nook,
    /// and done there in the chat's app, as you would have done it yourself.
    struct ChatSetting: Codable, Equatable, Sendable {
        var app: String
        var name: String
        var pinned = false
        var muted = false
        var archived = false
        /// When it was brought over: one whose chat never shows up is let go after a while.
        var since: Date

        var key: String { ChatInbox.key(app: app, chat: name) }
    }

    /// How long a chat's setting waits for its app to be linked in Nook.
    static let settingsKeep: TimeInterval = 60 * 86_400

    /// The pinned, muted and archived chats of `GET /v1/chats`, archived ones included, of the apps Nook knows (WhatsApp
    /// aside).
    static func settings(_ json: [String: Any], now: Date = Date()) -> [ChatSetting] {
        (json["items"] as? [[String: Any]] ?? []).compactMap { chat in
            guard chat["merge"] == nil, (chat["mergedIntoChatID"] as? String ?? "").isEmpty,
                  let app = ChatServiceData.app(network: (chat["network"] as? String) ?? "", account: (chat["accountID"] as? String) ?? ""),
                  !ownHistory.contains(app) else { return nil }
            let name = ((chat["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let setting = ChatSetting(app: app, name: name, pinned: chat["isPinned"] as? Bool == true,
                                      muted: chat["isMuted"] as? Bool == true, archived: chat["isArchived"] as? Bool == true, since: now)
            guard !name.isEmpty, setting.pinned || setting.muted || setting.archived else { return nil }
            return setting
        }
    }

    /// The settings still waiting, with `new` ones added (a newer one for the same chat replaces the older), and those
    /// that waited too long let go.
    static func merged(_ waiting: [ChatSetting], _ new: [ChatSetting], now: Date = Date()) -> [ChatSetting] {
        var byKey: [String: ChatSetting] = [:]
        for setting in waiting + new { byKey[setting.key] = setting }
        return byKey.values.filter { now.timeIntervalSince($0.since) < settingsKeep }.sorted { $0.key < $1.key }
    }

    /// What is still to be done in a chat Nook's chat helper lists, for the setting Beeper had: nothing when the chat
    /// already is that way.
    struct Change: Equatable, Sendable {
        var pin = false
        var mute = false
        var archive = false
        var isEmpty: Bool { !pin && !mute && !archive }
    }

    static func change(_ setting: ChatSetting, for chat: ChatServiceData.Chat) -> Change {
        Change(pin: setting.pinned && !chat.isPinned, mute: setting.muted && !chat.isMuted, archive: setting.archived)
    }

    // MARK: History

    /// The messages of a chat brought over: those with text only. Files stay in Beeper's own folder, which Nook does not
    /// read; once the app is linked in Nook, its chats come in again with their files.
    static func history(_ messages: [InboxMessage]) -> [InboxMessage] {
        messages.filter { $0.media == nil && $0.poll == nil && !$0.text.isEmpty }
    }
}
