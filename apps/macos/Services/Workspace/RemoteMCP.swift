import Foundation

// Nook in another app (remote MCP): a cloud assistant such as Claude.ai or ChatGPT reaches the tools Nook offers its coding
// agents over HTTPS, through the relay (apps/relay/worker/mcp.js). This file is the pure part and the part that decides: the
// access levels, the OAuth sign-in with a pairing code shown in Nook, the 30-day grants and their tokens. `RemoteMCPServer`
// runs the HTTP side and the tool calls. Every tool call still goes through the bridge's approvals and the audit log.
// Foundation only, tested on its own.

/// How much of Nook an assistant may use. A level never offers a tool that needs a project folder or this Mac's screen
/// (terminal, browser, simulators, pages, secrets, taking over the screen, pull requests): those stay with agents in Nook.
enum RemoteAccessLevel: String, CaseIterable, Codable, Sendable {
    /// Look at sessions, pull requests and Nook's chats; change nothing.
    case readOnly
    /// Also follow up and start sessions (each one still asks you).
    case sessions
    /// Also use Nook's apps (messages, calendar, music) and schedule tasks (each action still asks you).
    case full

    static let reads: Set<BridgeTool> = [
        .workspaceInfo, .sessionList, .sessionRead, .sessionSearch, .listScheduledTasks, .getPullRequestStatus, .taskStatus,
        .orchestratorCapabilities, .nookChatList, .nookChatRead,
    ]
    static let steering: Set<BridgeTool> = [.sessionSend, .sessionStart, .sessionQuestions, .sessionOrganize]
    static let apps: Set<BridgeTool> = [
        .nookTools, .nookUse, .nookChatSend, .scheduleTask, .updateScheduledTask, .runScheduledTaskNow, .watchPullRequest,
    ]

    var tools: Set<BridgeTool> {
        switch self {
        case .readOnly: return Self.reads
        case .sessions: return Self.reads.union(Self.steering)
        case .full: return Self.reads.union(Self.steering).union(Self.apps)
        }
    }

    func allows(_ tool: BridgeTool) -> Bool { tools.contains(tool) }

    /// The tools in the order the bridge lists them.
    var offered: [BridgeTool] { BridgeTool.allCases.filter(allows) }

    /// What a grant may do, in OAuth's words.
    var scope: String { "nook:" + rawValue }
}

enum RemoteMCP {
    /// How long a grant lasts; the assistant must be signed in again after that.
    static let grantLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// An access token is short; the refresh token renews it until the grant ends.
    static let accessLifetime: TimeInterval = 60 * 60
    /// A sign-in that waits for its code, and an authorization code on its way to the token endpoint.
    static let signInLifetime: TimeInterval = 10 * 60
    static let authCodeLifetime: TimeInterval = 2 * 60
    /// Wrong codes before a sign-in is dropped, and sign-ins waiting at once.
    static let maxAttempts = 5
    static let maxWaiting = 3
    static let maxClients = 50
    static let maxGrants = 20

    /// The hash a token is kept as: Nook never stores a token it handed out.
    static func hash(_ token: String) -> String { WebhookHex.encode(PureSHA256.hash(Data(token.utf8))) }

    /// PKCE S256: base64url of the SHA-256 of the verifier.
    static func challenge(verifier: String) -> String { base64URL(PureSHA256.hash(Data(verifier.utf8))) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The code the user types: six digits shown as `123 456`.
    static func display(code: String) -> String { code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code }

    /// A redirect an assistant may register: https, or http on this Mac (a desktop assistant); no fragment, no credentials.
    static func isValidRedirect(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.fragment == nil, url.user == nil, url.password == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
    }

    /// The address of the endpoint and its sign-in: `<relay>/v1/mcp/<room>`.
    static func baseURL(relay: String, room: String) -> String { relay + "/v1/mcp/" + room }

    /// Where an assistant finds the documents, per RFC 9728 and 8414, for the room's path.
    static func metadataURL(relay: String, room: String, name: String) -> String { relay + "/.well-known/" + name + "/v1/mcp/" + room }

    /// RFC 9728: which server signs callers in for this endpoint.
    static func protectedResource(base: String) -> [String: Any] {
        ["resource": base, "authorization_servers": [base], "bearer_methods_supported": ["header"],
         "scopes_supported": RemoteAccessLevel.allCases.map(\.scope), "resource_name": "Nook"]
    }

    /// RFC 8414, with dynamic client registration (RFC 7591) and PKCE as every assistant needs them.
    static func authorizationServer(base: String) -> [String: Any] {
        ["issuer": base, "authorization_endpoint": base + "/authorize", "token_endpoint": base + "/token",
         "registration_endpoint": base + "/register", "response_types_supported": ["code"],
         "grant_types_supported": ["authorization_code", "refresh_token"], "code_challenge_methods_supported": ["S256"],
         "token_endpoint_auth_methods_supported": ["none"], "scopes_supported": RemoteAccessLevel.allCases.map(\.scope)]
    }
}

/// What the sign-in and the grants know. A value type so the rules are tested without a socket; the server keeps one, saves
/// `clients` and `grants`, and loses `waiting` and `codes` when Nook quits (a sign-in then starts over).
struct RemoteMCPAccess: Equatable, Sendable {
    struct Client: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var redirects: [String]
        var created: Date
    }

    /// An assistant that asked to sign in and waits for the code from Nook.
    struct SignIn: Equatable, Sendable, Identifiable {
        var id: String
        var clientID: String
        var clientName: String
        var redirect: String
        var state: String
        var challenge: String
        var code: String
        var level: RemoteAccessLevel
        var created: Date
        var attempts = 0
    }

    private struct AuthCode: Equatable, Sendable {
        var clientID: String
        var redirect: String
        var challenge: String
        var level: RemoteAccessLevel
        var clientName: String
        var expires: Date
    }

    /// What the user sees and can revoke.
    struct Grant: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var clientID: String
        var client: String
        var level: RemoteAccessLevel
        var created: Date
        var expires: Date
        var accessHash: String
        var accessExpires: Date
        var refreshHash: String
        var lastUsed: Date?
    }

    enum Failure: String, Error, Equatable, Sendable {
        case invalidClient = "invalid_client", invalidRequest = "invalid_request", invalidGrant = "invalid_grant"
        case unsupported = "unsupported_response_type", tooMany = "temporarily_unavailable"
    }

    struct Tokens: Equatable, Sendable {
        var access: String
        var refresh: String
        var expiresIn: Int
        var level: RemoteAccessLevel
    }

    var clients: [String: Client] = [:]
    var grants: [Grant] = []
    private(set) var waiting: [SignIn] = []
    private var codes: [String: AuthCode] = [:]

    /// A source of random text, so tests run with known values: `secret(bytes)` is hex, `digits(count)` decimal.
    struct Random {
        var secret: (Int) -> String
        var digits: (Int) -> String
    }

    // MARK: Clients

    /// Dynamic client registration: the assistant says its name and where the browser returns to.
    mutating func register(name: String?, redirects: [String], now: Date, random: Random) -> Result<Client, Failure> {
        guard !redirects.isEmpty, redirects.count <= 5, redirects.allSatisfy(RemoteMCP.isValidRedirect) else { return .failure(.invalidRequest) }
        let shown = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if clients.count >= RemoteMCP.maxClients, let oldest = clients.values.min(by: { $0.created < $1.created }) {
            clients[oldest.id] = nil
        }
        let client = Client(id: "c-" + random.secret(12), name: shown.isEmpty ? "Assistant" : String(shown.prefix(60)),
                            redirects: redirects, created: now)
        clients[client.id] = client
        return .success(client)
    }

    // MARK: Sign-in

    /// The browser arrives at /authorize. Nothing is granted yet: Nook shows the code and the user types it on the page.
    mutating func begin(clientID: String, redirect: String, responseType: String, state: String?, challenge: String?,
                        method: String?, now: Date, random: Random) -> Result<SignIn, Failure> {
        prune(now: now)
        guard let client = clients[clientID], client.redirects.contains(redirect) else { return .failure(.invalidClient) }
        guard responseType == "code" else { return .failure(.unsupported) }
        // PKCE is required, and only S256.
        guard let challenge, !challenge.isEmpty, method == "S256" else { return .failure(.invalidRequest) }
        guard waiting.count < RemoteMCP.maxWaiting else { return .failure(.tooMany) }
        let signIn = SignIn(id: random.secret(8), clientID: clientID, clientName: client.name, redirect: redirect,
                            state: state ?? "", challenge: challenge, code: random.digits(6), level: .readOnly, created: now)
        waiting.append(signIn)
        return .success(signIn)
    }

    /// The level the user picks in Nook for a waiting sign-in.
    mutating func setLevel(_ level: RemoteAccessLevel, for id: String) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting[index].level = level
    }

    /// The user turns a waiting sign-in down in Nook.
    mutating func deny(_ id: String) { waiting.removeAll { $0.id == id } }

    enum Confirmation: Equatable, Sendable {
        /// The code was right: send the browser to `redirect` with the authorization code.
        case approved(redirect: String)
        case wrong(attemptsLeft: Int)
        case gone
    }

    /// The user typed the code from Nook on the page. A right code ends the sign-in and makes a one-use authorization code.
    mutating func confirm(_ id: String, typed: String, now: Date, random: Random) -> Confirmation {
        prune(now: now)
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return .gone }
        let digits = typed.filter(\.isNumber)
        if WebhookVerifier.constantTimeEqual(Data(digits.utf8), Data(waiting[index].code.utf8)) {
            let signIn = waiting.remove(at: index)
            let code = random.secret(16)
            codes[RemoteMCP.hash(code)] = AuthCode(clientID: signIn.clientID, redirect: signIn.redirect, challenge: signIn.challenge,
                                                  level: signIn.level, clientName: signIn.clientName,
                                                  expires: now.addingTimeInterval(RemoteMCP.authCodeLifetime))
            var parts = URLComponents(string: signIn.redirect)
            var items = parts?.queryItems ?? []
            items.append(URLQueryItem(name: "code", value: code))
            if !signIn.state.isEmpty { items.append(URLQueryItem(name: "state", value: signIn.state)) }
            parts?.queryItems = items
            return .approved(redirect: parts?.string ?? signIn.redirect)
        }
        waiting[index].attempts += 1
        let left = RemoteMCP.maxAttempts - waiting[index].attempts
        if left <= 0 {
            waiting.remove(at: index)
            return .gone
        }
        return .wrong(attemptsLeft: left)
    }

    // MARK: Tokens

    /// The token endpoint, for an authorization code. The code works once.
    mutating func exchange(code: String, verifier: String, clientID: String, redirect: String, now: Date,
                           random: Random) -> Result<Tokens, Failure> {
        prune(now: now)
        guard let issued = codes.removeValue(forKey: RemoteMCP.hash(code)), issued.expires > now,
              issued.clientID == clientID, issued.redirect == redirect,
              WebhookVerifier.constantTimeEqual(Data(RemoteMCP.challenge(verifier: verifier).utf8), Data(issued.challenge.utf8))
        else { return .failure(.invalidGrant) }
        let access = "nka_" + random.secret(32), refresh = "nkr_" + random.secret(32)
        if grants.count >= RemoteMCP.maxGrants { grants.removeFirst(grants.count - RemoteMCP.maxGrants + 1) }
        grants.append(Grant(id: random.secret(6), clientID: clientID, client: issued.clientName, level: issued.level, created: now,
                            expires: now.addingTimeInterval(RemoteMCP.grantLifetime), accessHash: RemoteMCP.hash(access),
                            accessExpires: now.addingTimeInterval(RemoteMCP.accessLifetime), refreshHash: RemoteMCP.hash(refresh)))
        return .success(Tokens(access: access, refresh: refresh, expiresIn: Int(RemoteMCP.accessLifetime), level: issued.level))
    }

    /// A refresh token buys a new access token, never a longer grant, and is replaced with each use.
    mutating func refresh(token: String, clientID: String, now: Date, random: Random) -> Result<Tokens, Failure> {
        let hashed = RemoteMCP.hash(token)
        guard let index = grants.firstIndex(where: { $0.refreshHash == hashed && $0.clientID == clientID }),
              grants[index].expires > now else { return .failure(.invalidGrant) }
        let access = "nka_" + random.secret(32), refresh = "nkr_" + random.secret(32)
        grants[index].accessHash = RemoteMCP.hash(access)
        grants[index].refreshHash = RemoteMCP.hash(refresh)
        grants[index].accessExpires = min(now.addingTimeInterval(RemoteMCP.accessLifetime), grants[index].expires)
        return .success(Tokens(access: access, refresh: refresh, expiresIn: Int(grants[index].accessExpires.timeIntervalSince(now)),
                               level: grants[index].level))
    }

    /// The grant an access token belongs to, while both the token and the grant are alive.
    func grant(accessToken: String, now: Date) -> Grant? {
        let hashed = RemoteMCP.hash(accessToken)
        return grants.first { $0.accessHash == hashed && $0.accessExpires > now && $0.expires > now }
    }

    mutating func used(_ id: String, now: Date) {
        if let index = grants.firstIndex(where: { $0.id == id }) { grants[index].lastUsed = now }
    }

    /// The user changes what a grant may do, from now on.
    mutating func setLevel(_ level: RemoteAccessLevel, forGrant id: String) {
        if let index = grants.firstIndex(where: { $0.id == id }) { grants[index].level = level }
    }

    mutating func revoke(_ id: String) { grants.removeAll { $0.id == id } }

    mutating func revokeAll() {
        grants = []
        waiting = []
        codes = [:]
    }

    /// Drops what ran out.
    mutating func prune(now: Date) {
        waiting.removeAll { now.timeIntervalSince($0.created) > RemoteMCP.signInLifetime }
        codes = codes.filter { $0.value.expires > now }
        grants.removeAll { $0.expires <= now }
    }
}
