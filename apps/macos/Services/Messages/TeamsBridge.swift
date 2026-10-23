import Foundation
import AppKit
import Combine

/// Your Teams chats with their history, through Microsoft Graph, read-only (Chat.Read), for every account you add. You
/// sign in once per account with a code on Microsoft's own page; Nook keeps each refresh token in the Keychain and talks
/// only to login.microsoftonline.com and graph.microsoft.com. It signs in as Nook's own app in Microsoft Entra, so
/// logging in is all it takes. Work or school accounts only.
@MainActor
final class TeamsBridge: ObservableObject, ChatBridge {
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

    var isReady: Bool { Self.clientID != nil && accounts.contains { CloudHelp.secret($0.refreshAccount) != nil } }
    private(set) var isWorking = false

    /// The app Nook signs in as: its own, or the one an earlier version of Nook asked you to register.
    static var clientID: String? { CloudHelp.secret(clientAccount) ?? builtInClientID }

    /// Nook's own app in Microsoft Entra: a multi-tenant public client ("Allow public client flows" on) with the
    /// delegated permissions Chat.Read and User.Read. Signing in with it needs nothing but the account itself.
    static let builtInClientID: String? = nil

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
        problems[id] = nil
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
        problems[account.id] = nil
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
            // The refresh token was revoked or expired: only signing in again helps.
            Keychain.remove(account.refreshAccount)
            throw NookError(tr("chats.teams.signInAgain"), kind: .auth)
        }
        sessions[account.id, default: Session()].access = (token, expires)
        if let newRefresh { Keychain.write(newRefresh, account: account.refreshAccount) }
        return token
    }

    // MARK: ChatBridge

    func read() async throws -> [BridgedChat] {
        guard let client = Self.clientID else { return [] }
        // Every account's chat list first: a chat name two accounts share is told apart before anything is read.
        var listed: [(account: TeamsData.Account, bearer: String, chats: [TeamsData.Chat])] = []
        var failure: Error?
        for account in accounts where CloudHelp.secret(account.refreshAccount) != nil {
            do {
                let bearer = try await token(account, client: client)
                let me = try await profile(account, bearer: bearer)
                let list = try await chats(bearer: bearer, me: me, myName: account.name)
                listed.append((account, bearer, list))
                problems[account.id] = nil
            } catch {
                problems[account.id] = error.localizedDescription
                failure = failure ?? error
            }
        }
        for account in accounts where CloudHelp.secret(account.refreshAccount) == nil {
            problems[account.id] = tr("chats.teams.signInAgain")
        }
        if listed.isEmpty, let failure {
            isWorking = false
            throw failure
        }
        let named = TeamsData.distinguish(listed.map { $0.chats }, labels: listed.map { $0.account.label })
        var result: [BridgedChat] = []
        for (index, entry) in listed.enumerated() {
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

    // MARK: HTTP

    private func post(_ address: String, _ fields: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw NookError(address) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = TeamsData.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await ConnectorHTTP.session.data(for: request)
        // The token endpoint answers 400 with the reason ("authorization_pending"): that is an answer, not a failure.
        guard let json = TeamsData.object(data) else { throw NookError(tr("chats.teams.failed")) }
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
        guard (200..<300).contains(code), let json = TeamsData.object(data) else {
            let reason = (TeamsData.object(data)?["error"] as? [String: Any])?["message"] as? String
            throw NookError(tr("chats.teams.refused", reason ?? "HTTP \(code)"), kind: code == 401 ? .auth : .other)
        }
        return json
    }
}
