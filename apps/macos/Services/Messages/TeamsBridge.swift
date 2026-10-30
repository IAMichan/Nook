import Foundation
import AppKit
import Combine

/// Your Teams chats with their history, read-only. Signing in on teams.microsoft.com (`TeamsWebSession`), as Nook links
/// Instagram and LinkedIn, reads them from Teams' own chat service with the website's session; that needs nothing but
/// your login. A build with Nook's own app in Microsoft Entra can also add accounts through Microsoft Graph (Chat.Read)
/// with a code on Microsoft's own page; Nook keeps each refresh token in the Keychain and talks only to
/// login.microsoftonline.com and graph.microsoft.com. Work or school accounts only.
@MainActor
final class TeamsBridge: ObservableObject, ChatHistoryBridge {
    let app = "teams"
    let interval: TimeInterval = 60

    enum State: Equatable {
        /// This build of Nook has no app id to sign in as.
        case noClient
        /// Ready to sign in (another) account.
        case idle
        /// Waiting for you to type the code on Microsoft's page.
        case code(TeamsData.DeviceCode)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The accounts you signed in with, in the order you added them.
    @Published private(set) var accounts: [TeamsData.Account] = []
    /// Accounts whose sign-in Microsoft no longer accepts, or whose last read failed, with why.
    @Published private(set) var problems: [String: String] = [:]
    /// The accounts in `problems` whose sign-in is gone, which only signing in again mends (else the failure passes).
    @Published private(set) var signedOutAccounts: Set<String> = []

    /// Notes why an account's read failed (nil: it works again), and whether that was its sign-in.
    private func note(_ id: String, _ problem: String?, signedOut: Bool = false) {
        problems[id] = problem
        let lost = problem != nil && signedOut
        if lost != signedOutAccounts.contains(id) {
            if lost { signedOutAccounts.insert(id) } else { signedOutAccounts.remove(id) }
        }
    }

    static let clientAccount = "chats.teams.clientID"
    private static let accountsKey = "chats.teams.accounts.v1"
    private static let authority = "https://login.microsoftonline.com/organizations/oauth2/v2.0/"
    /// Chats whose history is read per round and account: those whose newest message changed, the newest first. The
    /// others show with the newest message the chat list gives.
    private static let perRead = 15
    private static let history = 30
    /// Pages of 50 chats read from the chat list per round and account.
    private static let maxPages = 20

    /// What Nook keeps of an account while it runs.
    private struct Session {
        var access: (token: String, expires: Date)?
        var me: String?
        /// The newest message per chat at the last read, to read only the chats that moved.
        var seen: [String: Date] = [:]
        /// Reads of a chat whose messages did not list its newest one yet, per chat.
        var retries: [String: Int] = [:]
    }

    private var sessions: [String: Session] = [:]
    private static let maxRetries = 5
    private var waiting: Task<Void, Never>?

    var isReady: Bool {
        TeamsWebSession.shared.isSignedIn || (Self.clientID != nil && accounts.contains { CloudHelp.secret($0.refreshAccount) != nil })
    }
    /// Where `problems` keeps why reading an account linked through the website failed.
    static func webID(_ id: String) -> String { "web:" + id }
    /// What reading an account through the website keeps between rounds: as `Session.seen` and `retries`, and the
    /// names of chats without a topic, learned from their messages.
    private struct WebState {
        var seen: [String: Date] = [:]
        var retries: [String: Int] = [:]
        var names: [String: String] = [:]
    }
    private var web: [String: WebState] = [:]
    private(set) var isWorking = false

    /// Where each chat Nook shows was read, by its key in the inbox: where scrolling back asks.
    private enum Source {
        case graph(account: String, chat: TeamsData.Chat)
        case web(account: String, chat: TeamsData.Chat)
    }
    private var sources: [String: Source] = [:]
    /// The website's link to the page before the oldest messages read of a chat, by the chat's id.
    private var backward: [String: String] = [:]
    /// Chats (by their id) Nook just changed something in (sent, reacted, edited, deleted): their history is read
    /// again at the next read, even when their newest message stayed the same.
    private var changedHere: Set<String> = []
    /// Who wrote each message read through the website ("8:orgid:…"), by its id in Nook: what an answer to it names.
    private var authors: [String: String] = [:]
    /// Pages followed at most in one scroll back, to reach messages older than those Nook shows.
    private static let olderPages = 20

    /// The app Nook signs in as: its own, or the one an earlier version of Nook asked you to register.
    static var clientID: String? { CloudHelp.secret(clientAccount) ?? builtInClientID }

    /// Nook's own app in Microsoft Entra: a multi-tenant public client ("Allow public client flows" on) with the
    /// delegated permissions Chat.Read and User.Read. Signing in with it needs nothing but the account itself.
    /// Comes with the build (Info.plist, from the NOOK_TEAMS_CLIENT_ID build setting); nil while that is empty.
    static let builtInClientID: String? = (Bundle.main.object(forInfoDictionaryKey: "NookTeamsClientID") as? String)
        .flatMap { $0.isEmpty ? nil : $0 }

    init() {
        accounts = Self.loadAccounts()
        state = Self.clientID == nil ? .noClient : .idle
    }

    /// The accounts kept in the user defaults; a sign-in from a version that knew one account becomes the first.
    private static func loadAccounts() -> [TeamsData.Account] {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let stored = try? JSONDecoder().decode([TeamsData.Account].self, from: data) {
            return stored
        }
        let legacy = TeamsData.Account(id: "")
        return CloudHelp.secret(legacy.refreshAccount) == nil ? [] : [legacy]
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.accountsKey) }
    }

    // MARK: Signing in

    /// Asks Microsoft for a code, opens its page, and waits until you typed it there. The account you sign in with is
    /// added, or replaces itself when Nook already has it.
    func signIn() {
        guard let client = Self.clientID else { state = .noClient; return }
        waiting?.cancel()
        waiting = Task {
            do {
                let json = try await post(Self.authority + "devicecode", ["client_id": client, "scope": TeamsData.scopes])
                guard let code = TeamsData.deviceCode(json) else {
                    state = .failed((json["error_description"] as? String) ?? tr("chats.teams.failed"))
                    return
                }
                state = .code(code)
                NSWorkspace.shared.open(code.verificationURL)
                try await waitForToken(code, client: client)
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        waiting?.cancel()
        waiting = nil
        state = Self.clientID == nil ? .noClient : .idle
    }

    /// Forgets one account and its token; the chats it brought stay until they grow old.
    func signOut(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        Keychain.remove(account.refreshAccount)
        accounts.removeAll { $0.id == id }
        saveAccounts()
        sessions[id] = nil
        note(id, nil)
        if accounts.isEmpty { isWorking = false }
    }

    private func waitForToken(_ code: TeamsData.DeviceCode, client: String) async throws {
        var interval = code.interval
        while Date() < code.expires {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let json = try await post(Self.authority + "token", [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": client, "device_code": code.deviceCode,
            ])
            switch TeamsData.token(json) {
            case .token(let token, let refresh, let expires):
                try await add(token: token, refresh: refresh, expires: expires)
                state = .idle
                return
            case .pending(let slowDown):
                if slowDown { interval += 5 }
            case .failed(let why):
                state = .failed(why)
                return
            }
        }
        state = .failed(tr("chats.teams.expired"))
    }

    /// Keeps a new sign-in: as a new account, or in place of the same account signed in before.
    private func add(token: String, refresh: String?, expires: Date) async throws {
        let profile = TeamsData.me(try await get(URL(string: "https://graph.microsoft.com/v1.0/me")!, token: token))
        var account = accounts.first { profile != nil && $0.userID == profile?.id }
            // The account of a version that knew only one, whose user id was never kept.
            ?? accounts.first { $0.userID == nil && accounts.count == 1 }
            ?? TeamsData.Account(id: UUID().uuidString)
        if let profile {
            account.userID = profile.id
            account.name = profile.name
            account.email = profile.email
        }
        if let refresh { Keychain.write(refresh, account: account.refreshAccount) }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        saveAccounts()
        var session = sessions[account.id] ?? Session()
        session.access = (token, expires)
        session.me = profile?.id
        sessions[account.id] = session
        note(account.id, nil)
    }

    /// A valid access token for an account: the one kept, or a new one from its refresh token (which Microsoft then
    /// replaces).
    private func token(_ account: TeamsData.Account, client: String) async throws -> String {
        if let access = sessions[account.id]?.access, access.expires > Date().addingTimeInterval(60) { return access.token }
        guard let refresh = CloudHelp.secret(account.refreshAccount) else { throw NookError(tr("chats.teams.signInAgain"), kind: .auth) }
        let json = try await post(Self.authority + "token", [
            "grant_type": "refresh_token", "client_id": client, "refresh_token": refresh, "scope": TeamsData.scopes,
        ])
        guard case .token(let token, let newRefresh, let expires) = TeamsData.token(json) else {
            // The refresh token was revoked or expired: only signing in again helps. A passing refusal keeps it.
            guard TeamsData.signInGone(json) else { throw NookError(tr("chats.teams.failed")) }
            Keychain.remove(account.refreshAccount)
            throw NookError(tr("chats.teams.signInAgain"), kind: .auth)
        }
        sessions[account.id, default: Session()].access = (token, expires)
        if let newRefresh { Keychain.write(newRefresh, account: account.refreshAccount) }
        return token
    }

    // MARK: ChatBridge

    func read() async throws -> [BridgedChat] {
        var result: [BridgedChat] = []
        var failure: Error?
        let linked = TeamsWebSession.shared.accounts
        for key in problems.keys where key.hasPrefix(Self.webID("")) && !linked.contains(where: { Self.webID($0.id) == key }) {
            note(key, nil)
        }
        // Every account's chat list first: a chat name two accounts share is told apart before anything is read.
        var lists: [(account: TeamsWebData.Account, chats: [TeamsData.Chat])] = []
        for account in linked {
            do {
                lists.append(try await listWeb(account))
                note(Self.webID(account.id), nil)
            } catch {
                note(Self.webID(account.id), error.localizedDescription, signedOut: ConnectorErrorKind.classify(error) == .auth)
                failure = failure ?? error
            }
        }
        let distinct = TeamsData.distinguish(lists.map { $0.chats }, labels: lists.map { $0.account.label })
        for (index, entry) in lists.enumerated() {
            result += await readWeb(distinct[index], account: entry.account)
        }
        guard let client = Self.clientID, !accounts.isEmpty else {
            if result.isEmpty, let failure {
                isWorking = false
                throw failure
            }
            isWorking = !lists.isEmpty
            return result
        }
        // Every account's chat list first: a chat name two accounts share is told apart before anything is read.
        var listed: [(account: TeamsData.Account, bearer: String, chats: [TeamsData.Chat])] = []
        for account in accounts where CloudHelp.secret(account.refreshAccount) != nil {
            do {
                let bearer = try await token(account, client: client)
                let me = try await profile(account, bearer: bearer)
                let list = try await chats(bearer: bearer, me: me, myName: account.name)
                listed.append((account, bearer, list))
                note(account.id, nil)
            } catch {
                note(account.id, error.localizedDescription, signedOut: ConnectorErrorKind.classify(error) == .auth)
                failure = failure ?? error
            }
        }
        for account in accounts where CloudHelp.secret(account.refreshAccount) == nil {
            note(account.id, tr("chats.teams.signInAgain"), signedOut: true)
        }
        if listed.isEmpty, result.isEmpty, let failure {
            isWorking = false
            throw failure
        }
        let named = TeamsData.distinguish(listed.map { $0.chats }, labels: listed.map { $0.account.label })
        for (index, entry) in listed.enumerated() {
            for chat in named[index] { sources[ChatInbox.key(app: app, chat: chat.name)] = .graph(account: entry.account.id, chat: chat) }
            result += await read(named[index], account: entry.account, bearer: entry.bearer)
        }
        isWorking = true
        return result
    }

    /// Your own id in an account, asked once per run; the account's name and address are brought up to date with it.
    private func profile(_ account: TeamsData.Account, bearer: String) async throws -> String? {
        if let me = sessions[account.id]?.me { return me }
        guard let profile = TeamsData.me(try await get(URL(string: "https://graph.microsoft.com/v1.0/me")!, token: bearer)) else { return nil }
        sessions[account.id, default: Session()].me = profile.id
        if let index = accounts.firstIndex(where: { $0.id == account.id }),
           accounts[index].userID != profile.id || accounts[index].name != profile.name || accounts[index].email != profile.email {
            accounts[index].userID = profile.id
            accounts[index].name = profile.name
            accounts[index].email = profile.email
            saveAccounts()
        }
        return profile.id
    }

    /// Every chat of an account, page by page, the most recently active first.
    private func chats(bearer: String, me: String?, myName: String) async throws -> [TeamsData.Chat] {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/chats")!
        components.queryItems = [
            URLQueryItem(name: "$expand", value: "members,lastMessagePreview"),
            URLQueryItem(name: "$orderby", value: "lastMessagePreview/createdDateTime desc"),
            URLQueryItem(name: "$top", value: "50"),
        ]
        var next = components.url
        var chats: [TeamsData.Chat] = []
        var ids: Set<String> = []
        for _ in 0..<Self.maxPages {
            guard let url = next else { break }
            let page = try await get(url, token: bearer)
            for chat in TeamsData.chats(page, me: me, myName: myName) where ids.insert(chat.id).inserted { chats.append(chat) }
            next = TeamsData.nextLink(page)
        }
        return chats
    }

    /// An account's chats for the inbox: the history of those that moved, and every other one with the newest message
    /// the list gives, so each chat you are in shows, whether anyone wrote in it lately or not.
    private func read(_ chats: [TeamsData.Chat], account: TeamsData.Account, bearer: String) async -> [BridgedChat] {
        // Only what a read changes is written back: a token dropped meanwhile (a 401) stays dropped.
        var seen = sessions[account.id]?.seen ?? [:]
        var retries = sessions[account.id]?.retries ?? [:]
        defer {
            sessions[account.id, default: Session()].seen = seen
            sessions[account.id, default: Session()].retries = retries
        }
        let me = sessions[account.id]?.me
        let moved = chats.filter { chat in chat.last.map { seen[chat.id] != $0 } ?? false }.prefix(Self.perRead)
        var fetched: Set<String> = []
        var result: [BridgedChat] = []
        for chat in moved {
            var messagesURL = URLComponents(string: "https://graph.microsoft.com/v1.0/me/chats/" + chat.id + "/messages")!
            messagesURL.queryItems = [URLQueryItem(name: "$top", value: String(Self.history))]
            guard let url = messagesURL.url else { continue }
            // One chat Graph refuses (a chat you left, a moment's hiccup) must not lose the others' new messages:
            // it stays unseen and is read again next time. A lost sign-in or a rate limit stops reading histories for
            // this round; the other chats still show with their newest message.
            let answer: [String: Any]
            do {
                answer = try await get(url, token: bearer)
            } catch let error as NookError where error.kind == .auth || error.kind == .rateLimited {
                break
            } catch {
                continue
            }
            let messages = TeamsData.messages(answer, chat: chat, me: me)
            // A chat whose messages do not list the announced one yet stays unseen and is read again next round
            // (a few times at most, so a message Graph never lists does not keep it read forever).
            let early = retries[chat.id] ?? 0
            if TeamsData.caughtUp(answer, last: chat.last) || early >= Self.maxRetries {
                seen[chat.id] = chat.last ?? Date.distantPast
                retries[chat.id] = nil
            } else {
                retries[chat.id] = early + 1
            }
            fetched.insert(chat.id)
            result.append(BridgedChat(app: app, name: chat.name, messages: messages,
                                      unread: TeamsData.unread(messages, readUntil: chat.readUntil),
                                      members: chat.members.isEmpty ? nil : chat.members, listed: true))
        }
        for chat in chats where !fetched.contains(chat.id) {
            let preview = chat.preview.map { [$0] } ?? []
            // Until its history is read, the list's newest message is all Nook knows: it is unread when it came after
            // you last read the chat. After that the count from the history stands.
            let unread = seen[chat.id] == nil ? TeamsData.unread(preview, readUntil: chat.readUntil) : nil
            result.append(BridgedChat(app: app, name: chat.name, messages: preview, unread: unread,
                                      members: chat.members.isEmpty ? nil : chat.members, listed: true))
        }
        return result
    }

    // MARK: Through the website's session

    /// An account's chat list as the Teams website reads it, with the session it was read with. A token about to run
    /// out, or refused, is renewed by loading the website out of sight first.
    private func listWeb(_ account: TeamsWebData.Account) async throws -> (account: TeamsWebData.Account, chats: [TeamsData.Chat]) {
        let site = TeamsWebSession.shared
        var current = account
        if current.session.expires < Date().addingTimeInterval(600) {
            guard let renewed = await site.renew(account.id) else { throw NookError(tr("chats.teams.signInAgain"), kind: .auth) }
            current.session = renewed
        }
        let address = { (session: TeamsWebData.Session) in session.base + "/v1/users/ME/conversations?view=msnp24Equivalent&pageSize=100" }
        let list: [String: Any]
        do {
            list = try await webGet(address(current.session), token: current.session.token, account: account.id)
        } catch let error as NookError where error.kind == .auth {
            guard let renewed = await site.renew(account.id) else { throw NookError(tr("chats.teams.signInAgain"), kind: .auth) }
            current.session = renewed
            list = try await webGet(address(current.session), token: current.session.token, account: account.id)
        }
        var names = web[account.id]?.names ?? [:]
        var chats = TeamsWebData.chats(list, me: current.session.me)
        for index in chats.indices {
            // A private chat is named after the other person while their message is the newest; once yours is, the
            // name it had stays, so your message lands in that chat and not in one of its own.
            if chats[index].name.isEmpty {
                chats[index].name = names[chats[index].id] ?? ""
            } else {
                names[chats[index].id] = chats[index].name
            }
        }
        web[account.id, default: WebState()].names = names
        return (current, chats)
    }

    /// An account's chats as the Teams website reads them: the history of those that moved (and of those whose name
    /// only their messages tell), and every other one with its newest message.
    private func readWeb(_ chats: [TeamsData.Chat], account: TeamsWebData.Account) async -> [BridgedChat] {
        let session = account.session
        var state = web[account.id] ?? WebState()
        defer { web[account.id] = state }
        let moved = chats.filter { chat in
            (chat.last.map { state.seen[chat.id] != $0 } ?? false) || (chat.name.isEmpty && state.seen[chat.id] == nil)
                || changedHere.contains(chat.id)
        }.prefix(Self.perRead)
        var fetched: Set<String> = []
        var result: [BridgedChat] = []
        for var chat in moved {
            let address = session.base + "/v1/users/ME/conversations/" + ChatJSON.segment(chat.id)
                + "/messages?view=msnp24Equivalent%7CsupportsMessageProperties&pageSize=\(Self.history)&startTime=1"
            let answer: [String: Any]
            do {
                answer = try await webGet(address, token: session.token, account: account.id)
            } catch let error as NookError where error.kind == .auth || error.kind == .rateLimited {
                break
            } catch {
                continue
            }
            if chat.name.isEmpty {
                chat.name = TeamsWebData.people(answer, me: session.me).joined(separator: ", ")
                if !chat.name.isEmpty { state.names[chat.id] = chat.name }
            }
            if let mine = TeamsWebData.myName(answer, me: session.me) { TeamsWebSession.shared.named(mine, in: account.id) }
            authors.merge(TeamsWebData.authors(answer)) { _, new in new }
            if backward[chat.id] == nil, let link = TeamsWebData.backwardLink(answer, base: session.base) { backward[chat.id] = link }
            let early = state.retries[chat.id] ?? 0
            if TeamsWebData.caughtUp(answer, last: chat.last) || early >= Self.maxRetries {
                state.seen[chat.id] = chat.last ?? Date.distantPast
                state.retries[chat.id] = nil
            } else {
                state.retries[chat.id] = early + 1
            }
            changedHere.remove(chat.id)
            fetched.insert(chat.id)
            guard !chat.name.isEmpty else { continue }
            sources[ChatInbox.key(app: app, chat: chat.name)] = .web(account: account.id, chat: chat)
            var messages = TeamsWebData.messages(answer, chat: chat, me: session.me)
            // How far the others read it: your messages get their ticks and readers, as in every app that says so.
            if messages.contains(where: \.isMine), let horizons = try? await webGet(
                session.base + "/v1/threads/" + ChatJSON.segment(chat.id) + "/consumptionhorizons", token: session.token, account: account.id) {
                messages = TeamsWebData.read(messages, horizons: TeamsWebData.horizons(horizons, me: session.me), group: chat.isGroup,
                                             names: TeamsWebData.displayNames(answer))
            }
            // Messages deleted since (here or in Teams) leave the chat in Nook too.
            result.append(BridgedChat(app: app, name: chat.name, messages: messages,
                                      unread: TeamsData.unread(messages, readUntil: chat.readUntil), listed: true,
                                      deleted: TeamsWebData.deleted(answer)))
        }
        for chat in chats where !fetched.contains(chat.id) && !chat.name.isEmpty {
            sources[ChatInbox.key(app: app, chat: chat.name)] = .web(account: account.id, chat: chat)
            let preview = chat.preview.map { [$0] } ?? []
            let unread = state.seen[chat.id] == nil ? TeamsData.unread(preview, readUntil: chat.readUntil) : nil
            result.append(BridgedChat(app: app, name: chat.name, messages: preview, unread: unread, listed: true))
        }
        return result
    }

    // MARK: Scrolling back

    func canLoadOlder(name: String) -> Bool { sources[ChatInbox.key(app: app, chat: name)] != nil }

    /// The batch before the oldest message Nook shows, as far back as Teams keeps the chat.
    func older(name: String, before: Date, oldestID: String?) async throws -> (chat: BridgedChat?, hasMore: Bool) {
        switch sources[ChatInbox.key(app: app, chat: name)] {
        case .graph(let id, let chat):
            guard let client = Self.clientID, let account = accounts.first(where: { $0.id == id }) else { return (nil, false) }
            let bearer = try await token(account, client: client)
            let me = sessions[id]?.me
            var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/chats/" + chat.id + "/messages")!
            components.queryItems = [
                URLQueryItem(name: "$top", value: String(ChatHistory.step)),
                URLQueryItem(name: "$orderby", value: "createdDateTime desc"),
                URLQueryItem(name: "$filter", value: "createdDateTime lt " + ISO8601DateFormatter().string(from: before)),
            ]
            var next = components.url
            // Graph pages backwards from there; a page of only system notes goes on to the next.
            for _ in 0..<Self.olderPages {
                guard let url = next else { break }
                let page = try await get(url, token: bearer)
                next = TeamsData.nextLink(page)
                let messages = TeamsData.messages(page, chat: chat, me: me).filter { $0.date < before }
                if !messages.isEmpty {
                    return (BridgedChat(app: app, name: name, messages: messages, unread: nil,
                                        members: chat.members.isEmpty ? nil : chat.members), next != nil)
                }
            }
            return (nil, next != nil)
        case .web(let id, let chat):
            guard let account = TeamsWebSession.shared.accounts.first(where: { $0.id == id }) else { return (nil, false) }
            // The website pages back through links; pages Nook already shows are passed over.
            for _ in 0..<Self.olderPages {
                guard let link = backward[chat.id] else { return (nil, false) }
                let page = try await webGet(link, token: account.session.token, account: id)
                backward[chat.id] = TeamsWebData.backwardLink(page, base: account.session.base)
                let messages = TeamsWebData.messages(page, chat: chat, me: account.session.me).filter { $0.date < before }
                if !messages.isEmpty {
                    return (BridgedChat(app: app, name: name, messages: messages, unread: nil, listed: true), backward[chat.id] != nil)
                }
            }
            return (nil, backward[chat.id] != nil)
        case nil:
            return (nil, false)
        }
    }

    // MARK: Sending

    /// Whether Nook can write in the chat it shows as `name`: one read through the website's session, of an account
    /// still linked. A chat read only through Microsoft Graph (Chat.Read) is read-only.
    func canSend(name: String) -> Bool {
        guard case .web(let id, _) = sources[ChatInbox.key(app: app, chat: name)] else { return false }
        return TeamsWebSession.shared.accounts.contains { $0.id == id }
    }

    /// Sends what you typed to the chat Nook shows as `name`, as the website does, as an answer to `replyTo` (a
    /// message's id in Nook) when set, with the account's current session (renewed first when it is about to run out,
    /// or when Teams refuses it). The chat shows it at the next read, which comes at once. Throws with a sentence you
    /// can act on.
    func send(text: String, to name: String, replyTo: String? = nil) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        let (account, chat) = try await webChat(name)
        var html = TeamsWebData.html(body)
        if let replyTo, let answered = ChatCaptureService.shared.inbox.threads[ChatInbox.key(app: app, chat: name)]?
            .messages.first(where: { $0.id == replyTo }) {
            let author = answered.isMine ? account.session.me : authors[replyTo]
            let sender = answered.isMine ? account.session.name : (answered.sender.isEmpty ? name : answered.sender)
            html = TeamsWebData.replyHTML(to: replyTo, author: author, sender: sender, text: answered.summary) + html
        }
        // One id for both tries: Teams keeps a message once even when the first try reached it.
        let clientID = String(UInt64.random(in: 1_000_000_000_000_000...9_999_999_999_999_999))
        let json = TeamsWebData.outgoing(html: html, name: account.session.name, clientMessageID: clientID)
        try await webAct("POST", account: account, path: "/v1/users/ME/conversations/" + ChatJSON.segment(chat.id) + "/messages",
                         json: json)
        // The chat moved: its history is read again, with the message just sent.
        changedHere.insert(chat.id)
        ChatCaptureService.shared.readSoon(app)
    }

    /// Puts your emoji on a message (its id in Nook) of the chat Nook shows as `name`, or takes it back when it is
    /// yours already, as the website does.
    func react(_ emoji: String, to message: String, in name: String, mine: Bool) async throws {
        guard message.hasPrefix("teams-") else { throw NookError(tr("chat.compose.unsupported")) }
        let (account, chat) = try await webChat(name)
        let path = "/v1/users/ME/conversations/" + ChatJSON.segment(chat.id) + "/messages/"
            + ChatJSON.segment(String(message.dropFirst("teams-".count))) + "/properties?name=emotions"
        // Teams shows only the emoji of its own list; any other would be a placeholder there.
        guard let key = TeamsData.key(emoji: emoji) else { throw NookError(tr("chat.react.notInApp", "Teams")) }
        if mine {
            try await webAct("DELETE", account: account, path: path, json: ["emotions": ["key": key]])
        } else {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try await webAct("PUT", account: account, path: path, json: ["emotions": ["key": key, "value": now]])
        }
        changedHere.insert(chat.id)
        ChatCaptureService.shared.readSoon(app)
    }

    /// Changes the text of your message (its id in Nook) in the chat Nook shows as `name`, as the website does: the
    /// message is put again with the new text, an answer keeping its quote. The chat shows it at the next read, which
    /// comes at once.
    func edit(_ message: String, in name: String, to text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NookError(tr("whatsapp.reply.empty")) }
        guard let id = TeamsWebData.serviceID(message) else { throw NookError(tr("chat.compose.unsupported")) }
        let (account, chat) = try await webChat(name)
        var html = TeamsWebData.html(body)
        if let quote = ChatCaptureService.shared.inbox.threads[ChatInbox.key(app: app, chat: name)]?
            .messages.first(where: { $0.id == message })?.quote, let answered = quote.id {
            let author = quote.mine ? account.session.me : authors[answered]
            let sender = quote.mine ? account.session.name : (quote.sender.isEmpty ? name : quote.sender)
            html = TeamsWebData.replyHTML(to: answered, author: author, sender: sender, text: quote.text) + html
        }
        // One id for both tries, as when sending.
        let clientID = String(UInt64.random(in: 1_000_000_000_000_000...9_999_999_999_999_999))
        let json = TeamsWebData.edited(html: html, name: account.session.name, clientMessageID: clientID)
        try await webAct("PUT", account: account, path: TeamsWebData.messagePath(chat: chat.id, message: id), json: json)
        changedHere.insert(chat.id)
        ChatCaptureService.shared.readSoon(app)
    }

    /// Deletes your message (its id in Nook) for everyone in the chat Nook shows as `name`, as the website does. The
    /// next read, which comes at once, finds it marked deleted and drops it from the chat in Nook.
    func delete(_ message: String, in name: String) async throws {
        guard let id = TeamsWebData.serviceID(message) else { throw NookError(tr("chat.compose.unsupported")) }
        let (account, chat) = try await webChat(name)
        try await webAct("DELETE", account: account, path: TeamsWebData.messagePath(chat: chat.id, message: id), json: [:])
        changedHere.insert(chat.id)
        ChatCaptureService.shared.readSoon(app)
    }

    /// Marks the chat Nook shows as `name` read up to its newest message Nook knows (from the chat's messages in Nook,
    /// or the chat list's newest one), as the website does. Nothing happens for a chat without any.
    func markRead(name: String) async throws {
        let (account, chat) = try await webChat(name)
        var known = ChatCaptureService.shared.inbox.threads[ChatInbox.key(app: app, chat: name)]?.messages.map(\.id) ?? []
        if let preview = chat.preview?.id { known.append(preview) }
        guard let newest = TeamsWebData.newest(known) else { return }
        try await webAct("PUT", account: account, path: TeamsWebData.horizonPath(chat: chat.id),
                         json: TeamsWebData.horizon(newest: newest.id, arrived: newest.arrived))
        changedHere.insert(chat.id)
        ChatCaptureService.shared.readSoon(app)
    }

    /// The linked account and chat behind the chat Nook shows as `name`, with a session that does not run out within
    /// the minute.
    private func webChat(_ name: String) async throws -> (TeamsWebData.Account, TeamsData.Chat) {
        guard case .web(let id, let chat) = sources[ChatInbox.key(app: app, chat: name)],
              var account = TeamsWebSession.shared.accounts.first(where: { $0.id == id }) else {
            throw NookError(tr("chats.teams.signInAgain"), kind: .auth)
        }
        if account.session.expires < Date().addingTimeInterval(60) {
            guard let renewed = await TeamsWebSession.shared.renew(id) else { throw NookError(tr("chats.teams.signInAgain"), kind: .auth) }
            account.session = renewed
        }
        return (account, chat)
    }

    /// A change on the chat service at `path` (after the session's base), tried again once with a renewed session
    /// when Teams refuses the one it had.
    private func webAct(_ method: String, account: TeamsWebData.Account, path: String, json: [String: Any]) async throws {
        do {
            try await webPost(method, account.session.base + path, json, token: account.session.token, account: account.id)
        } catch let error as NookError where error.kind == .auth {
            guard let renewed = await TeamsWebSession.shared.renew(account.id) else {
                throw NookError(tr("chats.teams.signInAgain"), kind: .auth)
            }
            try await webPost(method, renewed.base + path, json, token: renewed.token, account: account.id)
        }
    }

    /// Sends a change to Teams' chat service with the website's token, as `webGet` asks it.
    private func webPost(_ method: String, _ address: String, _ json: [String: Any], token: String, account: String) async throws {
        guard let url = URL(string: address) else { throw NookError(address) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // A change without a body (deleting a message) sends none.
        if !json.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("skypetoken=" + token, forHTTPHeaderField: "Authentication")
        request.setValue("redirectAs404", forHTTPHeaderField: "BehaviorOverride")
        request.timeoutInterval = 30
        let (_, response) = try await ConnectorHTTP.session(timeout: request.timeoutInterval).data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            TeamsWebSession.shared.expire(account)
            throw NookError(tr("chats.teams.signInAgain"), kind: .auth)
        }
        if code == 429 { throw NookError(tr("chats.teams.rateLimited"), kind: .rateLimited) }
        guard (200..<300).contains(code) else { throw NookError(tr("chats.teams.notSent", "HTTP \(code)")) }
    }

    /// Asks Teams' chat service with the website's token; a refused token is dropped, so the next read renews it.
    private func webGet(_ address: String, token: String, account: String) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw NookError(address) }
        var request = URLRequest(url: url)
        request.setValue("skypetoken=" + token, forHTTPHeaderField: "Authentication")
        request.setValue("redirectAs404", forHTTPHeaderField: "BehaviorOverride")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            TeamsWebSession.shared.expire(account)
            throw NookError(tr("chats.teams.signInAgain"), kind: .auth)
        }
        if code == 429 { throw NookError(tr("chats.teams.rateLimited"), kind: .rateLimited) }
        guard (200..<300).contains(code), let json = ChatJSON.object(data) else {
            throw NookError(tr("chats.teams.refused", "HTTP \(code)"))
        }
        return json
    }

    // MARK: HTTP

    private func post(_ address: String, _ fields: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw NookError(address) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = TeamsData.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await ConnectorHTTP.session.data(for: request)
        // The token endpoint answers 400 with the reason ("authorization_pending"): that is an answer, not a failure.
        guard let json = ChatJSON.object(data) else { throw NookError(tr("chats.teams.failed")) }
        return json
    }

    private func get(_ url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            for id in sessions.keys where sessions[id]?.access?.token == token { sessions[id]?.access = nil }
        }
        if code == 429 { throw NookError(tr("chats.teams.rateLimited"), kind: .rateLimited) }
        guard (200..<300).contains(code), let json = ChatJSON.object(data) else {
            let reason = (ChatJSON.object(data)?["error"] as? [String: Any])?["message"] as? String
            throw NookError(tr("chats.teams.refused", reason ?? "HTTP \(code)"), kind: code == 401 ? .auth : .other)
        }
        return json
    }
}
