import Foundation
import Combine

/// Every WhatsApp account Nook links through the gateway: the first one (`WhatsAppLink.shared`) and the ones added after
/// it in Settings (a business number, a second phone), each a `WhatsAppLink` of its own on a device (GOWA) or session
/// (OpenWA) of its own, with its own QR, webhook and read marks. The rest of Nook knows a chat by its key across accounts
/// (`WAChatKey`): `route` finds the account it is in and its JID there.
@MainActor
final class WhatsAppAccounts: ObservableObject {
    static let shared = WhatsAppAccounts()

    /// The first account first, then the others in the order they were added.
    @Published private(set) var links: [WhatsAppLink]

    /// What every account reports, by the chat's key (see `WhatsAppLink.onMessage`).
    var onMessage: ((_ chat: String) -> Void)? { didSet { links.forEach(wire) } }
    var onReceipt: ((_ chat: String) -> Void)? { didSet { links.forEach(wire) } }
    var onReadElsewhere: ((_ chat: String) -> Void)? { didSet { links.forEach(wire) } }

    private var watching: [AnyCancellable] = []

    private init() {
        links = [WhatsAppLink.shared] + WhatsAppSettings.accounts.map { WhatsAppLink(account: $0.id) }
        watch()
    }

    /// Called once at launch.
    func start() {
        for link in links { link.start() }
    }

    /// Settings changed (on/off, gateway, address, password, port): every account starts over.
    func settingsChanged() {
        for link in links { link.settingsChanged() }
    }

    func setEnabled(_ on: Bool) {
        WhatsAppSettings.enabled = on
        settingsChanged()
    }

    // MARK: Accounts

    /// The accounts besides the first, as Settings lists them.
    var accounts: [WAAccount] { WhatsAppSettings.accounts }

    /// Another account, after your click in Settings: its device or session is made at the gateway and its QR shows.
    @discardableResult
    func add(name: String) -> WhatsAppLink {
        var accounts = WhatsAppSettings.accounts
        let id = WAAccount.newID(taken: Set(accounts.map(\.id)).union(["nook"]))
        accounts.append(WAAccount(id: id, name: WAAccount.cleanName(name)))
        WhatsAppSettings.accounts = accounts
        let link = WhatsAppLink(account: id)
        wire(link)
        links.append(link)
        watch()
        // Only the new account starts: the others keep their device and their webhook port (the new one takes the next).
        link.start()
        Log.connectors.info("WhatsApp: account added")
        return link
    }

    /// An account you removed: it is unlinked at the gateway and forgotten on this Mac. The first account stays.
    func remove(_ id: String) {
        guard !id.isEmpty, let index = links.firstIndex(where: { $0.account == id }) else { return }
        let link = links[index]
        link.remove()
        WhatsAppSettings.accounts.removeAll { $0.id == id }
        links.remove(at: index)
        watch()
        // The accounts after it moved down one webhook port: only they start over.
        for later in links[index...] { later.settingsChanged() }
        Log.connectors.info("WhatsApp: account removed")
    }

    /// What you call an account; empty, it goes by its number.
    func rename(_ id: String, to name: String) {
        if id.isEmpty {
            WhatsAppSettings.mainName = name
        } else {
            WhatsAppSettings.accounts = WhatsAppSettings.accounts.map { $0.id == id ? WAAccount(id: id, name: WAAccount.cleanName(name)) : $0 }
        }
        objectWillChange.send()
    }

    /// An account as the Chats tab and Settings name it: what you called it, else its number, else "WhatsApp".
    func name(of link: WhatsAppLink) -> String {
        let given = link.account.isEmpty ? WhatsAppSettings.mainName : accounts.first { $0.id == link.account }?.name ?? ""
        if !given.isEmpty { return given }
        return link.me.map(WAJID.displayNumber) ?? "WhatsApp"
    }

    /// Where a WhatsApp chat is, as its card, notice and search result say it: "WhatsApp", and with more than one account
    /// linked the account too ("WhatsApp · Business").
    func context(of link: WhatsAppLink) -> String {
        showsAccounts ? "WhatsApp · " + name(of: link) : "WhatsApp"
    }

    /// Whether more than one account is linked: only then do chats say which account they are in.
    var showsAccounts: Bool { connected.count > 1 }

    // MARK: Chats

    /// The accounts linked now.
    var connected: [WhatsAppLink] { links.filter(\.isConnected) }

    /// Whether any account is linked.
    var isConnected: Bool { links.contains(where: \.isConnected) }

    /// The account a chat is in, and its JID there; a key of an account that is gone goes to the first account.
    func route(_ key: String) -> (link: WhatsAppLink, jid: String) {
        let (account, jid) = WAChatKey.split(key)
        return (links.first { $0.account == account } ?? WhatsAppLink.shared, jid)
    }

    func link(for key: String) -> WhatsAppLink { route(key).link }

    /// A chat by its name or number in any linked account, the first account first: its key and its name.
    func resolve(_ recipient: String, also: [(jid: String, name: String)] = []) -> (key: String, name: String)? {
        for link in connected {
            if let found = link.resolve(recipient, also: link === WhatsAppLink.shared ? also : []) {
                return (link.chatKey(found.jid), found.name)
            }
        }
        return nil
    }

    /// A message to a chat by its key, or by a name or number (in the first account that has it).
    @discardableResult
    func send(_ text: String, to recipient: String, replyTo: String? = nil,
              also: [(jid: String, name: String)] = []) async throws -> String {
        let (link, jid) = target(recipient)
        return try await link.send(text, to: jid, replyTo: replyTo, also: also)
    }

    /// The account and the chat in it that `recipient` names: a chat's key (or a JID of the first account), else the
    /// first account that knows the name or number.
    func target(_ recipient: String) -> (link: WhatsAppLink, jid: String) {
        if recipient.contains(WAChatKey.separator) || recipient.contains("@") { return route(recipient) }
        for link in connected where link.resolve(recipient) != nil { return (link, recipient) }
        return (WhatsAppLink.shared, recipient)
    }

    /// The chats of every linked account by name, for the brain's choice of who to write to.
    func chatNames() -> [String] {
        var unique: [String] = []
        for name in connected.flatMap({ $0.chatNames() }) where !unique.contains(name) { unique.append(name) }
        return unique
    }

    /// New messages in every account, for the dot on the Chats tab.
    var visibleUnread: Int { connected.reduce(0) { $0 + $1.visibleUnread } }

    /// Every chat of every linked account, for Settings' list per chat: the chat's JID (the choice holds in every
    /// account), once.
    var chatsForSettings: [(jid: String, name: String)] {
        var seen = Set<String>()
        return links.flatMap(\.chatsForSettings).filter { seen.insert($0.jid).inserted }
    }

    // MARK: Private

    private func wire(_ link: WhatsAppLink) {
        link.onMessage = onMessage
        link.onReceipt = onReceipt
        link.onReadElsewhere = onReadElsewhere
    }

    /// A change in any account is a change here, so a view watching every account redraws for each.
    private func watch() {
        // perf: forwards each account's own change once; the accounts publish only what changed (see `WhatsAppLink`).
        watching = links.map { link in
            link.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
}
