import Foundation
import Combine

/// WhatsApp through the linked phone as one of the chat bridges (`ChatBridge`), so its chats are every app's: the Chats
/// tab, the cards, search, the iPhone companion and Nook itself read them from the shared inbox, as they read Telegram's
/// or Slack's. The links stay WhatsApp's own (the gateway, the webhook, the ids and ledgers); this bridge only turns what
/// they keep into the shared inbox's chats (`WhatsAppExport`), each time one of them changes. Their messages stay in
/// memory only (`BridgedChat.ephemeral`), as they always did.
@MainActor
final class WhatsAppGatewayBridge: ChatKeyedHistoryBridge, ChatNewsBridge, ChatSearchBridge {
    let app = "whatsapp"
    /// WhatsApp on this Mac (`WhatsAppDesktopBridge`) reads the same app while no phone is linked: each keeps its own turns.
    let bridgeID = "whatsapp-link"
    /// The links say when something changed (`readNow`); the capture service's turn only looks in now and then.
    let interval: TimeInterval = 300
    /// WhatsApp has its own switch (Settings › WhatsApp) and needs no Full Disk Access: it reads also while collecting
    /// chats is off.
    var alwaysOn: Bool { true }
    private(set) var isWorking = false

    /// A phone is linked, and the chat helper does not bring WhatsApp itself (then that one does: one chat, not two).
    var isReady: Bool { WhatsAppAccounts.shared.isConnected && !ChatHelper.linked(app) }

    /// Whether the chat with this key (`WAChatKey`) is in an account linked now.
    func isLinked(_ key: String) -> Bool {
        WhatsAppAccounts.shared.route(key).link.isConnected && isReady
    }

    /// Whether the linked phone's chats show: as `isReady`, but also through a moment the gateway does not answer, so
    /// one failed check does not empty the Chats tab and close the chat you read.
    var holdsChats: Bool { WhatsAppAccounts.shared.holdsChats && !ChatHelper.linked(app) }

    /// Whether the chat with this key shows (`holdsChats`, for its own account).
    func isListed(_ key: String) -> Bool {
        WhatsAppAccounts.shared.route(key).link.holdsChats && holdsChats
    }

    /// What each chat was made from last time, by its key: a chat made from the same is not made again.
    private struct Source: Equatable {
        var conversation: WAConversation?
        var info: WAChatInfo?
        var name: String
        var facts: WhatsAppExport.Facts
    }
    private var sources: [String: Source] = [:]
    /// What each chat was last handed over as, by its key.
    private var exported: [String: BridgedChat] = [:]
    /// Each account's names when its chats were last made: new names make them again.
    private var books: [String: WANameBook] = [:]
    private var watching: AnyCancellable?
    private var scheduled = false
    /// The chats with news the links told since the last read began, and the ones that read takes along: what came in
    /// during a read is told after the read that brings it.
    private var news: [String] = []
    private var readNews: [String] = []

    /// Follows every linked account from now on (once, at launch): a change of theirs is read into the shared inbox.
    func start() {
        guard watching == nil else { return }
        // perf: each burst of the accounts' changes becomes one read on the next turn of the run loop, and that read makes
        // only the chats that changed; the links publish only what changed.
        watching = WhatsAppAccounts.shared.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        let accounts = WhatsAppAccounts.shared
        // A link says which message is news, as it always did: one from someone else that came in live, not history, not
        // a catch-up after the Mac slept, and not one its chat's rules keep quiet.
        accounts.onMessage = { [weak self] key in self?.noteNews(key) }
        accounts.onForget = { [weak self] account in self?.forget(account: account, remove: false) }
        accounts.onRemove = { [weak self] account in self?.forget(account: account, remove: true) }
        schedule()
    }

    private func noteNews(_ key: String) {
        let id = ChatInbox.key(app: app, id: key)
        news.removeAll { $0 == id }
        news.append(id)
        schedule()
    }

    func takeNews() -> [String] {
        defer { readNews = [] }
        return readNews
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                ChatCaptureService.shared.readNow(self)
            }
        }
    }

    func read() async throws -> [BridgedChat] {
        readNews = news
        news = []
        guard isReady else {
            isWorking = false
            readNews = []
            return []
        }
        let accounts = WhatsAppAccounts.shared
        var changed: [BridgedChat] = []
        for link in accounts.connected {
            let account = accounts.showsAccounts ? accounts.name(of: link) : nil
            let book = link.names
            let renamed = books[link.account] != book
            books[link.account] = book
            var made = Set<String>()
            // The chats that wrote since the phone was linked (or whose history was fetched), with their messages.
            for conversation in link.inbox.conversations.values where !link.filters.ignored.contains(conversation.id) {
                made.insert(conversation.id)
                let facts = link.exportFacts(conversation.id, account: account, messages: conversation.messages)
                let source = Source(conversation: conversation, name: conversation.name, facts: facts)
                guard renamed || sources[facts.key] != source else { continue }
                sources[facts.key] = source
                var chat = WhatsAppExport.chat(conversation, facts: facts, names: book)
                chat.deleted = WhatsAppExport.deleted(before: exported[facts.key], now: chat)
                hand(chat, key: facts.key, to: &changed)
            }
            // Every other chat on the phone, also the ones that wrote nothing since: their messages load when one opens.
            for info in link.knownChats where !made.contains(info.jid) && WAJID.kind(info.jid) != .status
                && !link.filters.ignored.contains(info.jid) {
                let name = link.chatName(info.jid, fallback: info.name.isEmpty ? WAJID.displayNumber(info.jid) : info.name)
                let facts = link.exportFacts(info.jid, account: account, messages: [])
                let source = Source(info: info, name: name, facts: facts)
                guard renamed || sources[facts.key] != source else { continue }
                sources[facts.key] = source
                hand(WhatsAppExport.listed(info, name: name, facts: facts), key: facts.key, to: &changed)
            }
        }
        isWorking = true
        return changed
    }

    /// Hands every chat over again at the next read, as on the first (the shared inbox was emptied).
    func handAllOver() {
        sources = [:]
        exported = [:]
        books = [:]
        schedule()
    }

    /// Hands a chat over when it differs from what was handed over last.
    private func hand(_ chat: BridgedChat, key: String, to changed: inout [BridgedChat]) {
        guard exported[key] != chat else { return }
        exported[key] = chat
        changed.append(chat)
    }

    /// An account let go of what it kept (WhatsApp turned off): its chats in the shared inbox let go of their messages
    /// too. A removed account's chats go altogether.
    private func forget(account: String, remove: Bool) {
        let keys = Set(exported.keys.filter { WAChatKey.split($0).account == account })
        for key in keys {
            exported[key] = nil
            sources[key] = nil
        }
        books[account] = nil
        let capture = ChatCaptureService.shared
        let ids = Set(capture.loadedInbox.threads.values.filter { thread in
            thread.app == app && thread.chatID.map { WAChatKey.split($0).account == account } == true
        }.map(\.id))
        if remove { capture.drop(ids) } else { capture.forgetMessages(of: ids) }
    }

    // MARK: Search everything

    var searchesHistory: Bool { holdsChats }

    /// Every message the linked accounts hold of each chat (also the ones scrolled back to), past the newest ones the
    /// shared inbox keeps (`ChatInbox.keep`). The gateway has no search of its own: what it never brought is not here,
    /// and WhatsApp on this Mac (`WhatsAppDesktopBridge`) is searched beside it.
    func searchHistory(_ words: [String], limit: Int) async throws -> [BridgedChat] {
        guard holdsChats, !words.isEmpty else { return [] }
        var found: [(chat: BridgedChat, messages: [InboxMessage])] = []
        for word in words {
            var hits: [(chat: BridgedChat, message: InboxMessage)] = []
            for chat in exported.values {
                for message in chat.messages where ChatHistorySearch.matches(message, [word]) { hits.append((chat, message)) }
            }
            hits.sort { $0.message.date > $1.message.date }
            found += hits.prefix(limit).map { (chat: $0.chat, messages: [$0.message]) }
        }
        return ChatHistorySearch.chats(found)
    }

    // MARK: Older messages

    func canLoadOlder(chatID: String) -> Bool {
        let (link, jid) = WhatsAppAccounts.shared.route(chatID)
        return link.isConnected && link.inbox.conversations[WAJID.normalized(jid)]?.canLoadOlder == true
    }

    /// The gateway's next batch of older messages, with the chat as it stands then.
    func older(chatID: String) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        let accounts = WhatsAppAccounts.shared
        let (link, jid) = accounts.route(chatID)
        let key = WAJID.normalized(jid)
        let added = await link.loadOlder(key)
        guard let conversation = link.inbox.conversations[key] else { return (nil, false) }
        guard added else { return (nil, conversation.canLoadOlder) }
        let facts = link.exportFacts(key, account: accounts.showsAccounts ? accounts.name(of: link) : nil,
                                     messages: conversation.messages)
        let chat = WhatsAppExport.chat(conversation, facts: facts, names: link.names)
        sources[facts.key] = Source(conversation: conversation, name: conversation.name, facts: facts)
        exported[facts.key] = chat
        return (chat, conversation.canLoadOlder)
    }
}
