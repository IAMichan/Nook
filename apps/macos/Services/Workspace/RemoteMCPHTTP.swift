import Foundation

// The HTTP side of Nook in another app (see `RemoteMCP`): what the relay passes in, the OAuth endpoints with the pairing page,
// and the MCP endpoint's guard. The relay (apps/relay/worker/mcp.js) passes each request as JSON and takes the answer the same
// way; only the headers listed there get through. Foundation only, tested on its own.
enum RemoteMCPHTTP {
    struct Request: Equatable, Sendable {
        var id: String
        var method: String
        /// Relative to the room: "/", "/authorize", "/token", "/register" or "/.well-known/<document>".
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data
    }

    struct Answer: Equatable, Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    static let maxBody = 1024 * 1024

    static func incoming(_ text: String) -> Request? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["id"] as? String, let method = object["method"] as? String, let path = object["path"] as? String,
              let encoded = object["body"] as? String, let body = Data(base64Encoded: encoded), body.count <= maxBody else { return nil }
        let headers = (object["headers"] as? [String: String]) ?? [:]
        return Request(id: id, method: method.uppercased(), path: path, query: (object["query"] as? String) ?? "",
                       headers: Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first }),
                       body: body)
    }

    static func frame(id: String, _ answer: Answer) -> String {
        let object: [String: Any] = ["id": id, "status": answer.status, "headers": answer.headers,
                                     "body": answer.body.base64EncodedString()]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Answers

    static func json(_ status: Int, _ object: [String: Any], extra: [String: String] = [:]) -> Answer {
        var headers = ["content-type": "application/json", "cache-control": "no-store", "access-control-allow-origin": "*"]
        headers.merge(extra) { _, new in new }
        return Answer(status: status, headers: headers,
                      body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    static func oauthError(_ failure: RemoteMCPAccess.Failure, status: Int = 400) -> Answer {
        json(failure == .tooMany ? 503 : status, ["error": failure.rawValue])
    }

    /// The 401 that tells an assistant where to sign in.
    static func unauthorized(metadata: String) -> Answer {
        json(401, ["error": "unauthorized"], extra: ["www-authenticate": "Bearer resource_metadata=\"\(metadata)\""])
    }

    static func bearer(_ request: Request) -> String? {
        guard let value = request.headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        let token = value.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func form(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            func decode(_ part: Substring) -> String {
                part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(part)
            }
            values[decode(key)] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return values
    }

    // MARK: OAuth

    /// Page texts, by key, in the user's language.
    typealias Texts = (String) -> String

    /// Everything but the MCP endpoint itself: the discovery documents, registration, the pairing page and the token endpoint.
    /// Nil when `request` is for the MCP endpoint (`/`).
    static func oauth(_ request: Request, access: inout RemoteMCPAccess, base: String, now: Date,
                      random: RemoteMCPAccess.Random, texts: Texts) -> Answer? {
        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource"):
            return json(200, RemoteMCP.protectedResource(base: base))
        case ("GET", "/.well-known/oauth-authorization-server"), ("GET", "/.well-known/openid-configuration"):
            return json(200, RemoteMCP.authorizationServer(base: base))
        case ("OPTIONS", _):
            return Answer(status: 204, headers: ["access-control-allow-origin": "*", "access-control-allow-headers":
                "authorization, content-type, mcp-protocol-version, mcp-session-id", "access-control-allow-methods": "GET, POST, DELETE, OPTIONS"])
        case ("POST", "/register"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let redirects = object["redirect_uris"] as? [String] else { return oauthError(.invalidRequest) }
            switch access.register(name: object["client_name"] as? String, redirects: redirects, now: now, random: random) {
            case .failure(let failure): return oauthError(failure)
            case .success(let client):
                return json(201, ["client_id": client.id, "client_name": client.name, "redirect_uris": client.redirects,
                                  "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"],
                                  "response_types": ["code"]])
            }
        case ("GET", "/authorize"):
            let query = form(request.query)
            switch access.begin(clientID: query["client_id"] ?? "", redirect: query["redirect_uri"] ?? "",
                                responseType: query["response_type"] ?? "", state: query["state"],
                                challenge: query["code_challenge"], method: query["code_challenge_method"], now: now, random: random) {
            case .failure(let failure): return page(status: failure == .tooMany ? 503 : 400, message: texts("remotemcp.page.failed"), texts: texts)
            case .success(let signIn): return page(signIn: signIn, error: nil, base: base, texts: texts)
            }
        case ("POST", "/authorize"):
            let fields = form(String(decoding: request.body, as: UTF8.self))
            let id = fields["id"] ?? ""
            switch access.confirm(id, typed: fields["code"] ?? "", now: now, random: random) {
            case .approved(let redirect):
                return Answer(status: 302, headers: ["location": redirect, "cache-control": "no-store"])
            case .wrong(let left):
                guard let signIn = access.waiting.first(where: { $0.id == id }) else { return page(status: 400, message: texts("remotemcp.page.gone"), texts: texts) }
                return page(signIn: signIn, error: texts("remotemcp.page.wrong").replacingOccurrences(of: "%ld", with: String(left)), base: base, texts: texts)
            case .gone:
                return page(status: 400, message: texts("remotemcp.page.gone"), texts: texts)
            }
        case ("POST", "/token"):
            let fields = form(String(decoding: request.body, as: UTF8.self))
            let result: Result<RemoteMCPAccess.Tokens, RemoteMCPAccess.Failure>
            switch fields["grant_type"] {
            case "authorization_code":
                result = access.exchange(code: fields["code"] ?? "", verifier: fields["code_verifier"] ?? "", clientID: fields["client_id"] ?? "",
                                         redirect: fields["redirect_uri"] ?? "", now: now, random: random)
            case "refresh_token":
                result = access.refresh(token: fields["refresh_token"] ?? "", clientID: fields["client_id"] ?? "", now: now, random: random)
            default:
                return json(400, ["error": "unsupported_grant_type"])
            }
            switch result {
            case .failure(let failure): return oauthError(failure)
            case .success(let tokens):
                return json(200, ["access_token": tokens.access, "token_type": "Bearer", "expires_in": tokens.expiresIn,
                                  "refresh_token": tokens.refresh, "scope": tokens.level.scope])
            }
        case (_, "/"):
            return nil
        default:
            return json(404, ["error": "not_found"])
        }
    }

    // MARK: The pairing page

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let pageHeaders = [
        "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-frame-options": "DENY",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
        "referrer-policy": "no-referrer", "x-content-type-options": "nosniff",
    ]

    private static func shell(_ inner: String, texts: Texts) -> Data {
        Data("""
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Nook</title><style>body{font:16px -apple-system,system-ui,sans-serif;max-width:26rem;margin:12vh auto;padding:0 1.25rem;\
        color:#222}h1{font-size:1.3rem}input[type=text]{font:inherit;font-size:1.6rem;letter-spacing:.2em;width:100%;box-sizing:border-box;\
        padding:.5rem;margin:.75rem 0}button{font:inherit;padding:.55rem 1.1rem}.e{color:#b00020}p{color:#555}\
        @media(prefers-color-scheme:dark){body{background:#1b1b1d;color:#eee}p{color:#aaa}input{background:#2a2a2d;color:#eee}}</style></head>
        <body>\(inner)</body></html>
        """.utf8)
    }

    static func page(status: Int, message: String, texts: Texts) -> Answer {
        Answer(status: status, headers: pageHeaders, body: shell("<h1>Nook</h1><p>\(escape(message))</p>", texts: texts))
    }

    static func page(signIn: RemoteMCPAccess.SignIn, error: String?, base: String, texts: Texts) -> Answer {
        let intro = texts("remotemcp.page.intro").replacingOccurrences(of: "%@", with: escape(signIn.clientName))
        let problem = error.map { "<p class=\"e\">\(escape($0))</p>" } ?? ""
        let inner = """
        <h1>\(escape(texts("remotemcp.page.title")))</h1><p>\(intro)</p>\(problem)
        <form method="post" action="\(escape(base))/authorize"><input type="hidden" name="id" value="\(escape(signIn.id))">
        <input type="text" name="code" inputmode="numeric" autocomplete="off" autofocus maxlength="7" placeholder="000 000" aria-label="\(escape(texts("remotemcp.page.code")))">
        <button type="submit">\(escape(texts("remotemcp.page.connect")))</button></form>
        """
        return Answer(status: 200, headers: pageHeaders, body: shell(inner, texts: texts))
    }
}
