import Foundation
import AppKit
import Combine

/// Your Teams chats with their history, through Microsoft Graph, read-only (Chat.Read). You sign in once with a code
/// on Microsoft's own page; Nook keeps the refresh token in the Keychain and talks only to login.microsoftonline.com and
/// graph.microsoft.com. The app it signs in as is one you register in Microsoft Entra (a public client), whose
/// application id you set in Settings › Chats. Work or school accounts only.
@MainActor
final class TeamsBridge: ObservableObject, ChatBridge {
    let app = "teams"
    let interval: TimeInterval = 60

    enum State: Equatable {
        /// The application id is not set yet.
        case noClient
        case signedOut
        /// Waiting for you to type the code on Microsoft's page.
        case code(TeamsData.DeviceCode)
        case signedIn
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var account: String?

    static let clientAccount = "chats.teams.clientID"
    private static let refreshAccount = "chats.teams.refresh"
    private static let authority = "https://login.microsoftonline.com/organizations/oauth2/v2.0/"
    /// Chats read per round: those whose newest message changed, the newest first.
    private static let perRead = 15
    private static let history = 30

    private var access: (token: String, expires: Date)?
    private var me: String?
    /// The newest message per chat at the last read, to read only the chats that moved.
    private var seen: [String: Date] = [:]
    private var waiting: Task<Void, Never>?

    var isReady: Bool { Self.clientID != nil && CloudHelp.secret(Self.refreshAccount) != nil }
    private(set) var isWorking = false

    static var clientID: String? { CloudHelp.secret(clientAccount) }

    init() {
        state = Self.clientID == nil ? .noClient : (CloudHelp.secret(Self.refreshAccount) == nil ? .signedOut : .signedIn)
    }

    /// The application id changed in Settings: sign in again.
    func clientChanged() {
        signOut()
        state = Self.clientID == nil ? .noClient : .signedOut
    }

    // MARK: Signing in

    /// Asks Microsoft for a code, opens its page, and waits until you typed it there.
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
        state = Self.clientID == nil ? .noClient : .signedOut
    }

    func signOut() {
        waiting?.cancel()
        Keychain.remove(Self.refreshAccount)
        access = nil
        me = nil
        account = nil
        seen = [:]
        isWorking = false
        state = Self.clientID == nil ? .noClient : .signedOut
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
                access = (token, expires)
                if let refresh { Keychain.write(refresh, account: Self.refreshAccount) }
                state = .signedIn
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

    /// A valid access token: the one kept, or a new one from the refresh token (which Microsoft then replaces).
    private func token(client: String) async throws -> String {
        if let access, access.expires > Date().addingTimeInterval(60) { return access.token }
        guard let refresh = CloudHelp.secret(Self.refreshAccount) else { throw NookError(tr("chats.teams.signInAgain")) }
        let json = try await post(Self.authority + "token", [
            "grant_type": "refresh_token", "client_id": client, "refresh_token": refresh, "scope": TeamsData.scopes,
        ])
        guard case .token(let token, let newRefresh, let expires) = TeamsData.token(json) else {
            // The refresh token was revoked or expired: only signing in again helps.
            Keychain.remove(Self.refreshAccount)
            state = .signedOut
            throw NookError(tr("chats.teams.signInAgain"))
        }
        access = (token, expires)
        if let newRefresh { Keychain.write(newRefresh, account: Self.refreshAccount) }
        return token
    }

    // MARK: ChatBridge

    func read() async throws -> [BridgedChat] {
        guard let client = Self.clientID else { return [] }
        do {
            let bearer = try await token(client: client)
            if me == nil, let profile = TeamsData.me(try await get(URL(string: "https://graph.microsoft.com/v1.0/me")!, token: bearer)) {
                me = profile.id
                account = profile.name
            }
            var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/chats")!
            components.queryItems = [
                URLQueryItem(name: "$expand", value: "members,lastMessagePreview"),
                URLQueryItem(name: "$orderby", value: "lastMessagePreview/createdDateTime desc"),
                URLQueryItem(name: "$top", value: "50"),
            ]
            let chats = TeamsData.chats(try await get(components.url!, token: bearer), me: me)
            var result: [BridgedChat] = []
            for chat in chats.filter({ chat in chat.last.map { seen[chat.id] != $0 } ?? (seen[chat.id] == nil) }).prefix(Self.perRead) {
                var messagesURL = URLComponents(string: "https://graph.microsoft.com/v1.0/me/chats/" + chat.id + "/messages")!
                messagesURL.queryItems = [URLQueryItem(name: "$top", value: String(Self.history))]
                guard let url = messagesURL.url else { continue }
                // One chat Graph refuses (a chat you left, a moment's hiccup) must not lose the others' new messages:
                // it stays unseen and is read again next time. A lost sign-in or a rate limit stops the round.
                let answer: [String: Any]
                do {
                    answer = try await get(url, token: bearer)
                } catch let error as NookError where error.kind == .auth || error.kind == .rateLimited {
                    if result.isEmpty { throw error }
                    break
                } catch {
                    continue
                }
                let messages = TeamsData.messages(answer, chat: chat, me: me)
                seen[chat.id] = chat.last ?? Date.distantPast
                guard !messages.isEmpty else { continue }
                result.append(BridgedChat(app: app, name: chat.name, messages: messages,
                                          unread: TeamsData.unread(messages, readUntil: chat.readUntil),
                                          members: chat.members.isEmpty ? nil : chat.members))
            }
            isWorking = true
            if state != .signedIn { state = .signedIn }
            return result
        } catch {
            isWorking = false
            throw error
        }
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
        if code == 401 { access = nil }
        if code == 429 { throw NookError(tr("chats.teams.rateLimited"), kind: .rateLimited) }
        guard (200..<300).contains(code), let json = TeamsData.object(data) else {
            let reason = (TeamsData.object(data)?["error"] as? [String: Any])?["message"] as? String
            throw NookError(tr("chats.teams.refused", reason ?? "HTTP \(code)"), kind: code == 401 ? .auth : .other)
        }
        return json
    }
}
