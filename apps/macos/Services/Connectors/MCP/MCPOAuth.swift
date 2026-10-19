import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Signing in to a remote MCP server the way the MCP authorization spec describes it: OAuth 2.1 with PKCE. Nook finds the
// server's authorization server on its own (protected resource metadata, RFC 9728; server metadata, RFC 8414), registers
// itself there (dynamic client registration, RFC 7591), so no client id or secret has to be shipped in the app, and asks
// for a token bound to that one server (resource indicator, RFC 8707). Tokens never leave the Keychain; this file holds
// only the protocol and stores nothing.

/// Why signing in or staying signed in did not work. The app turns these into plain sentences.
enum MCPOAuthError: Error, Equatable {
    /// The server or one of its endpoints is not on https.
    case insecure
    /// Could not find where to sign in.
    case noAuthorizationServer
    /// The authorization server does not offer PKCE with S256: Nook will not sign in without it.
    case noPKCE
    /// The authorization server does not let apps register themselves.
    case noRegistration
    case registrationFailed(String)
    /// The person said no on the service's consent page.
    case declined
    /// The sign-in window was closed.
    case cancelled
    /// The answer did not belong to the sign-in Nook started (possible CSRF): ignored.
    case stateMismatch
    case callbackFailed(String)
    case tokenFailed(String)
    /// No usable token anymore and refreshing did not help: sign in again.
    case expired
    /// The server needs a sign-in that has not happened yet.
    case notSignedIn

    /// How the connection list shows it: sign in again, or try again later.
    var connectorKind: ConnectorErrorKind {
        switch self {
        case .expired, .notSignedIn, .declined, .stateMismatch, .cancelled: return .auth
        case .insecure, .noAuthorizationServer, .noPKCE, .noRegistration, .registrationFailed: return .config
        case .callbackFailed, .tokenFailed: return .other
        }
    }
}

enum MCPOAuth {
    /// Where the service sends the browser back to. The sign-in window (ASWebAuthenticationSession) catches it, so no
    /// other app or web page can receive the code.
    static let callbackScheme = "nook"
    static let redirectURI = "nook://oauth/callback"

    // MARK: PKCE and state

    struct PKCE: Equatable {
        let verifier: String
        let challenge: String

        /// A fresh verifier (43 characters of 32 random bytes) and its S256 challenge.
        static func make() -> PKCE {
            let verifier = randomToken(bytes: 32)
            return PKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    /// Unguessable, URL-safe text from the system's cryptographic random generator.
    static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares without stopping at the first difference, so timing says nothing about the expected state.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    // MARK: Metadata

    /// What the MCP server says about itself (RFC 9728).
    struct ResourceMetadata: Equatable {
        var resource: String?
        var authorizationServers: [String]
        var scopes: [String]

        init?(_ json: [String: Any]) {
            resource = json["resource"] as? String
            authorizationServers = (json["authorization_servers"] as? [String]) ?? []
            scopes = (json["scopes_supported"] as? [String]) ?? []
            if resource == nil && authorizationServers.isEmpty { return nil }
        }
    }

    /// Where to sign in, get tokens and register (RFC 8414 / OpenID discovery).
    struct ServerMetadata: Codable, Equatable {
        var issuer: String
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var revocationEndpoint: String?
        var codeChallengeMethods: [String]?
        var scopes: [String]?

        init(issuer: String, authorizationEndpoint: String, tokenEndpoint: String, registrationEndpoint: String? = nil,
             revocationEndpoint: String? = nil, codeChallengeMethods: [String]? = nil, scopes: [String]? = nil) {
            self.issuer = issuer
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
            self.registrationEndpoint = registrationEndpoint
            self.revocationEndpoint = revocationEndpoint
            self.codeChallengeMethods = codeChallengeMethods
            self.scopes = scopes
        }

        init?(_ json: [String: Any], fallbackIssuer: String) {
            guard let authorize = json["authorization_endpoint"] as? String, let token = json["token_endpoint"] as? String else { return nil }
            self.init(
                issuer: (json["issuer"] as? String) ?? fallbackIssuer,
                authorizationEndpoint: authorize,
                tokenEndpoint: token,
                registrationEndpoint: json["registration_endpoint"] as? String,
                revocationEndpoint: json["revocation_endpoint"] as? String,
                codeChallengeMethods: json["code_challenge_methods_supported"] as? [String],
                scopes: json["scopes_supported"] as? [String]
            )
        }

        /// Every endpoint Nook will send a code, token or verifier to is on https.
        var isSecure: Bool {
            [authorizationEndpoint, tokenEndpoint, registrationEndpoint, revocationEndpoint].compactMap { $0 }
                .allSatisfy { URL(string: $0).map(MCPOAuth.isSecure) ?? false }
        }

        /// PKCE with S256 is required by OAuth 2.1. A server that lists methods without S256 is refused; one that lists
        /// none is given the benefit of the doubt (several older servers leave the field out but do support it).
        var supportsS256: Bool { codeChallengeMethods.map { $0.contains("S256") } ?? true }
    }

    /// The registration Nook got from the authorization server.
    struct Client: Codable, Equatable {
        var id: String
        /// Only when the server insists on one; it lives in the Keychain together with the tokens.
        var secret: String?
    }

    struct Tokens: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        /// Refresh a minute early, so a request never goes out with a token that dies on the way.
        func needsRefresh(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) < 60
        }
    }

    /// Everything Nook keeps for one signed-in server (in the Keychain, as JSON).
    struct Credentials: Codable, Equatable {
        var server: ServerMetadata
        var client: Client
        var tokens: Tokens
        var resource: String
        var scope: String?
        var account: String?
    }

    // MARK: Discovery helpers

    static func isSecure(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        return scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1"))
    }

    /// The server's own address as OAuth identifies it: lowercase scheme and host, no query, fragment or trailing slash.
    static func canonicalResource(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? url.absoluteString
    }

    /// A parameter from a `WWW-Authenticate: Bearer resource_metadata="…", scope="…"` header.
    static func authenticateParameter(_ name: String, in header: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|([^\\s,]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, range: range) else { return nil }
        for group in [1, 2] {
            if let found = Range(match.range(at: group), in: header) { return String(header[found]) }
        }
        return nil
    }

    /// Where the protected resource metadata may live when the server does not say: path-aware first, then the root.
    static func resourceMetadataCandidates(for server: URL) -> [URL] {
        guard let origin = origin(of: server) else { return [] }
        let path = server.path == "/" ? "" : server.path
        var result: [URL] = []
        if !path.isEmpty, let url = URL(string: origin + "/.well-known/oauth-protected-resource" + path) { result.append(url) }
        if let url = URL(string: origin + "/.well-known/oauth-protected-resource") { result.append(url) }
        return result
    }

    /// Where an authorization server's metadata may live (RFC 8414 section 3, then OpenID Connect discovery).
    static func serverMetadataCandidates(issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        var path = issuer.path
        if path.hasSuffix("/") { path.removeLast() }
        let strings: [String] = path.isEmpty
            ? [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"]
            : [origin + "/.well-known/oauth-authorization-server" + path,
               origin + "/.well-known/openid-configuration" + path,
               origin + path + "/.well-known/openid-configuration"]
        return strings.compactMap(URL.init(string:))
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: Authorization request and callback

    static func authorizationURL(server: ServerMetadata, client: Client, pkce: PKCE, state: String, resource: String, scope: String?) -> URL? {
        guard var components = URLComponents(string: server.authorizationEndpoint) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource)
        ]
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        // `+` is legal in a query but servers read it as a space: encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    enum Callback: Equatable {
        case code(String)
        case failed(MCPOAuthError)
    }

    /// Checks the address the service sent the browser back to. Only Nook's own redirect, with the state Nook made for
    /// this sign-in (and, when the server names itself, the expected issuer) is accepted.
    static func parseCallback(_ url: URL, expectedState: String, issuer: String?) -> Callback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: redirectURI),
              components.scheme?.lowercased() == expected.scheme,
              components.host?.lowercased() == expected.host,
              components.path == expected.path else {
            return .failed(.callbackFailed("unexpected redirect"))
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let state = value("state"), constantTimeEqual(state, expectedState) else { return .failed(.stateMismatch) }
        if let error = value("error") {
            if error == "access_denied" { return .failed(.declined) }
            return .failed(.callbackFailed(value("error_description") ?? error))
        }
        if let iss = value("iss"), let issuer, iss != issuer { return .failed(.callbackFailed("issuer mismatch")) }
        guard let code = value("code"), !code.isEmpty else { return .failed(.callbackFailed("no code")) }
        return .code(code)
    }

    // MARK: Token responses

    /// Reads a token response. A refresh that returns no new refresh token keeps the previous one.
    static func tokens(from json: [String: Any], previousRefreshToken: String? = nil, now: Date = Date()) throws -> Tokens {
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            if let error = json["error"] as? String {
                if error == "invalid_grant" { throw MCPOAuthError.expired }
                throw MCPOAuthError.tokenFailed((json["error_description"] as? String) ?? error)
            }
            throw MCPOAuthError.tokenFailed("no access token")
        }
        if let type = json["token_type"] as? String, type.lowercased() != "bearer" {
            throw MCPOAuthError.tokenFailed("unsupported token type \(type)")
        }
        let seconds = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init)
            ?? (json["expires_in"] as? String).flatMap(Double.init)
        return Tokens(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? previousRefreshToken,
            expiresAt: seconds.map { now.addingTimeInterval($0) }
        )
    }

    /// `application/x-www-form-urlencoded`, encoding everything but the unreserved characters.
    static func formBody(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = items.map { key, value in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    // MARK: Network

    /// What a sign-in needs to know about a server before opening the browser. `nil`: the server needs no sign-in.
    struct Discovery: Equatable {
        var server: ServerMetadata
        var resource: String
        var scope: String?
    }

    static func discover(server url: URL, session: URLSession = .shared) async throws -> Discovery? {
        guard isSecure(url) else { throw MCPOAuthError.insecure }
        // Ask the server like any MCP client would; without a token it answers 401 and says where to sign in.
        var probe = URLRequest(url: url)
        probe.httpMethod = "POST"
        probe.timeoutInterval = 20
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Nook","version":"1.0"}}}"#.utf8)
        let (_, response) = try await session.data(for: probe)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 401 || http?.statusCode == 403 else { return nil }
        let header = http?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""

        var candidates = resourceMetadataCandidates(for: url)
        if let hinted = authenticateParameter("resource_metadata", in: header).flatMap(URL.init(string:)), isSecure(hinted) {
            candidates.insert(hinted, at: 0)
        }
        var metadata: ResourceMetadata?
        for candidate in candidates {
            if let json = try? await getJSON(candidate, session: session), let found = ResourceMetadata(json) {
                metadata = found
                break
            }
        }

        // Older servers (spec 2025-03-26) have no resource metadata: their own origin is the authorization server.
        let issuerString = metadata?.authorizationServers.first ?? origin(of: url)
        guard let issuerString, let issuer = URL(string: issuerString), isSecure(issuer) else { throw MCPOAuthError.noAuthorizationServer }
        var serverMetadata: ServerMetadata?
        for candidate in serverMetadataCandidates(issuer: issuer) {
            if let json = try? await getJSON(candidate, session: session), let found = ServerMetadata(json, fallbackIssuer: issuerString) {
                serverMetadata = found
                break
            }
        }
        guard let serverMetadata else { throw MCPOAuthError.noAuthorizationServer }
        guard serverMetadata.isSecure else { throw MCPOAuthError.insecure }
        guard serverMetadata.supportsS256 else { throw MCPOAuthError.noPKCE }

        let canonical = canonicalResource(url)
        // Use the server's own name for itself when it belongs to the same origin; never a foreign one.
        let resource = metadata?.resource.flatMap { declared in
            URL(string: declared).flatMap(origin(of:)) == origin(of: url) ? declared : nil
        } ?? canonical
        let scope = authenticateParameter("scope", in: header)
            ?? metadata.map { $0.scopes.joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 }
        return Discovery(server: serverMetadata, resource: resource, scope: scope)
    }

    /// Registers Nook as a public client (no secret), allowed to use the redirect above.
    static func register(_ server: ServerMetadata, session: URLSession = .shared) async throws -> Client {
        guard let endpoint = server.registrationEndpoint.flatMap(URL.init(string:)) else { throw MCPOAuthError.noRegistration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Nook",
            "client_uri": "https://github.com/IAMichan/nook",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        let (data, response) = try await session.data(for: request)
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let id = json["client_id"] as? String, !id.isEmpty else {
            throw MCPOAuthError.registrationFailed((json["error_description"] as? String) ?? (json["error"] as? String) ?? "no client id")
        }
        return Client(id: id, secret: json["client_secret"] as? String)
    }

    /// Trades the code from the callback for tokens, proving with the PKCE verifier that Nook started this sign-in.
    static func exchange(code: String, verifier: String, server: ServerMetadata, client: Client, resource: String,
                         session: URLSession = .shared) async throws -> Tokens {
        var items: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
            ("resource", resource)
        ]
        return try await tokenRequest(&items, server: server, client: client, previousRefreshToken: nil, session: session)
    }

    /// A new access token from the refresh token. `expired` when the service no longer accepts it.
    static func refresh(_ credentials: Credentials, session: URLSession = .shared) async throws -> Tokens {
        guard let refreshToken = credentials.tokens.refreshToken else { throw MCPOAuthError.expired }
        var items: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("resource", credentials.resource)
        ]
        return try await tokenRequest(&items, server: credentials.server, client: credentials.client,
                                      previousRefreshToken: refreshToken, session: session)
    }

    /// Asks the service to forget a token (RFC 7009) when the user disconnects. Best effort: the Keychain copy is
    /// removed either way.
    static func revoke(_ credentials: Credentials, session: URLSession = .shared) async {
        guard let endpoint = credentials.server.revocationEndpoint.flatMap(URL.init(string:)), isSecure(endpoint) else { return }
        for (token, hint) in [(credentials.tokens.refreshToken, "refresh_token"), (Optional(credentials.tokens.accessToken), "access_token")] {
            guard let token else { continue }
            var items: [(String, String)] = [("token", token), ("token_type_hint", hint)]
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            authenticate(&request, &items, client: credentials.client)
            request.httpBody = formBody(items)
            _ = try? await session.data(for: request)
        }
    }

    private static func tokenRequest(_ items: inout [(String, String)], server: ServerMetadata, client: Client,
                                     previousRefreshToken: String?, session: URLSession) async throws -> Tokens {
        guard let endpoint = URL(string: server.tokenEndpoint), isSecure(endpoint) else { throw MCPOAuthError.insecure }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authenticate(&request, &items, client: client)
        request.httpBody = formBody(items)
        let (data, response) = try await session.data(for: request)
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A refresh token that is refused will not start working again: sign in anew.
        if previousRefreshToken != nil && (status == 400 || status == 401) { throw MCPOAuthError.expired }
        guard (200..<300).contains(status) else {
            if (json["error"] as? String) == "invalid_grant" { throw MCPOAuthError.expired }
            throw MCPOAuthError.tokenFailed((json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)")
        }
        return try tokens(from: json, previousRefreshToken: previousRefreshToken)
    }

    /// Public clients send their id in the body; a client that was given a secret uses it (client_secret_post).
    private static func authenticate(_ request: inout URLRequest, _ items: inout [(String, String)], client: Client) {
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        items.append(("client_id", client.id))
        if let secret = client.secret, !secret.isEmpty { items.append(("client_secret", secret)) }
    }

    private static func getJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MCPOAuthError.noAuthorizationServer
        }
        return json
    }
}
