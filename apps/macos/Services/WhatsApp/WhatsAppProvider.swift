// Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).

import Foundation

// The local gateways Nook can talk to: GOWA and OpenWA for WhatsApp, Beeper Desktop for every network it bridges. Each call goes to the URL set in
// Settings (127.0.0.1 by default) and nowhere else: nothing from WhatsApp's own servers. A
// photo or document is only fetched when you click it in a chat, and then from the gateway.
// Endpoints, headers and bodies follow each gateway's docs (see WhatsAppGateway.swift for the
// references).

enum WAError: Error, Equatable {
    /// Nothing answers at that URL.
    case unreachable
    /// Wrong user:pass (GOWA) or API key (OpenWA).
    case unauthorized
    /// The gateway answered with an error (its own message, never a message's content).
    case refused(String)
    /// WhatsApp isn't linked yet.
    case notLoggedIn
}

protocol WhatsAppProvider: Sendable {
    var kind: WAGatewayKind { get }
    /// The link to WhatsApp (sets up the gateway's device or session the first time).
    func status() async throws -> WAStatus
    /// The QR to scan, as PNG bytes, and how long it stays valid; nil when there is none to
    /// show (already linked, not ready yet).
    func qrCode() async throws -> (png: Data, seconds: Int)?
    /// Tells the gateway to post new messages to Nook's local webhook, signed with `secret`.
    func registerWebhook(url: String, secret: String) async throws
    /// Messages of every chat since `date` (the polling fallback), oldest first.
    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage]
    /// The latest `limit` messages of one chat, oldest first.
    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage]
    /// Sends a text to an existing chat, as an answer to the message `replyTo` when set; returns the new message's id
    /// when the gateway gives it.
    func send(text: String, to chat: String, replyTo: String?) async throws -> String?
    /// Puts `emoji` on a message in `chat`; an empty `emoji` takes back your reaction (`old`, the one you had).
    func react(_ emoji: String, to message: String, chat: String, old: String?) async throws
    /// Marks the chat read up to `lastIncoming` (the newest message received in it).
    func markRead(chat: String, lastIncoming: String?) async throws
    /// A group's name, when the messages don't carry it.
    func groupName(_ chat: String) async -> String?
    /// The chats on the phone, newest first: who Nook may send to, by name.
    func chats(limit: Int) async throws -> [WAChatInfo]
    /// The file of one message (a document, photo, video or voice note), only when you open it.
    func media(chat: String, message: String) async throws -> WAFile
    /// Where a chat's picture is (a person's profile photo, a group's), on WhatsApp's own picture server; nil when it
    /// has none, hides it, or the gateway cannot say.
    func avatar(_ chat: String) async -> URL?
}

extension WhatsAppProvider {
    func avatar(_ chat: String) async -> URL? { nil }
}

/// A message's file as the gateway hands it over.
struct WAFile: Sendable {
    var data: Data
    /// The name the gateway gives it, if any.
    var name: String?
    /// Its MIME type, if the gateway says.
    var mimeType: String?

    /// Larger files are refused: the same cap both gateways use by default.
    static let maxBytes = 50 * 1024 * 1024
}

/// Never follows a redirect: a request (with its credentials and, for a send, the reply's
/// text) goes to the configured gateway and nowhere else.
final class WANoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// HTTP to the local gateway: no cookies, no cache, no redirect, nothing stored on disk.
final class WAHTTP: Sendable {
    let base: URL
    let headers: [String: String]
    private let session: URLSession

    init(base: URL, headers: [String: String]) {
        self.base = base
        self.headers = headers
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 60   // each request sets its own (10 s, longer for a QR)
        config.connectionProxyDictionary = [:]   // straight to the local gateway
        session = URLSession(configuration: config, delegate: WANoRedirect(), delegateQueue: nil)
    }

    /// `path` is appended to the base URL as given (already percent-encoded where needed).
    func call(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil,
              timeout: TimeInterval = 10) async throws -> (Data, Int) {
        let (data, response) = try await perform(method, path, query: query, json: json, timeout: timeout, accept: "application/json")
        return (data, response.statusCode)
    }

    /// A file from the gateway: its bytes, status code and MIME type.
    func download(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 60) async throws -> (Data, Int, String?) {
        let (data, response) = try await perform("GET", path, query: query, json: nil, timeout: timeout, accept: "*/*")
        return (data, response.statusCode, response.mimeType)
    }

    private func perform(_ method: String, _ path: String, query: [URLQueryItem], json: [String: any Sendable]?,
                         timeout: TimeInterval, accept: String) async throws -> (Data, HTTPURLResponse) {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw WAError.unreachable }
        comps.percentEncodedPath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? path : "/" + comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw WAError.unreachable }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: req)
            // Second lock: an answer from anywhere but the gateway is not one.
            if let final = response.url, final.host != url.host || final.port != url.port { throw WAError.unreachable }
            guard let http = response as? HTTPURLResponse else { throw WAError.unreachable }
            return (data, http)
        } catch {
            throw WAError.unreachable
        }
    }

    static func pathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~@"))) ?? s
    }
}

// MARK: - GOWA

/// go-whatsapp-web-multidevice, `./whatsapp rest` (port 3000). Auth: HTTP basic `user:pass`
/// when the gateway was started with `--basic-auth`. Nook works on one device (the one
/// already logged in, else a new one named "nook"), named in `X-Device-Id`.
actor GOWAProvider: WhatsAppProvider {
    nonisolated let kind = WAGatewayKind.gowa
    private let http: WAHTTP
    private var deviceId: String?

    init(base: URL, basicAuth: String?) {
        var headers: [String: String] = [:]
        if let auth = basicAuth, auth.contains(":") {
            headers["Authorization"] = "Basic " + Data(auth.utf8).base64EncodedString()
        }
        http = WAHTTP(base: base, headers: headers)
    }

    private func check(_ data: Data, _ code: Int) throws {
        if code == 401 && WAGOWA.errorCode(data) != "AUTHENTICATION_ERROR" { throw WAError.unauthorized }
        if code == 401 { throw WAError.notLoggedIn }
        guard (200..<300).contains(code) else {
            throw WAError.refused(WAGOWA.errorCode(data) ?? "HTTP \(code)")
        }
    }

    /// The device to work on; created ("nook") when the gateway has none.
    private func device() async throws -> (id: String, status: WAStatus) {
        let (data, code) = try await http.call("GET", "/devices")
        try check(data, code)
        if let found = WAGOWA.device(data) {
            deviceId = found.id
            return found
        }
        let (made, madeCode) = try await http.call("POST", "/devices", json: ["device_id": "nook"])
        try check(made, madeCode)
        deviceId = "nook"
        return ("nook", WAStatus(link: .needsQR, me: nil))
    }

    private func scoped(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil,
                        timeout: TimeInterval = 10) async throws -> Data {
        let id: String
        if let deviceId { id = deviceId } else { id = try await device().id }
        var q = query
        q.append(URLQueryItem(name: "device_id", value: id))
        let (data, code) = try await http.call(method, path, query: q, json: json, timeout: timeout)
        try check(data, code)
        return data
    }

    func status() async throws -> WAStatus {
        try await device().status
    }

    func qrCode() async throws -> (png: Data, seconds: Int)? {
        let id: String
        if let deviceId { id = deviceId } else { id = try await device().id }
        // GOWA answers once WhatsApp has handed it the first code: a few seconds.
        let (data, code) = try await http.call("GET", "/devices/\(WAHTTP.pathComponent(id))/login", timeout: 45)
        if WAGOWA.errorCode(data) == "ALREADY_LOGGED_IN" { return nil }
        try check(data, code)
        guard let qr = WAGOWA.qrPath(data) else { return nil }
        // The PNG is served by the gateway itself under /statics: fetched from the configured
        // URL, whatever host the link names.
        let (png, pngCode) = try await http.call("GET", qr.path)
        guard pngCode == 200, png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        // qr_duration is half the code's life (the PNG is deleted then, the code stays valid):
        // asking again sooner would restart the pairing under the user's phone.
        return (png, max(20, qr.seconds * 2 - 5))
    }

    func registerWebhook(url: String, secret: String) async throws {
        let id: String
        if let deviceId { id = deviceId } else { id = try await device().id }
        let (data, code) = try await http.call("PATCH", "/devices/\(WAHTTP.pathComponent(id))/webhook", json: [
            "webhook_url": url, "webhook_secret": secret, "webhook_events": "message,message.ack,message.reaction",
        ])
        try check(data, code)
    }

    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage] {
        let chats = WAGOWA.chats(try await scoped("GET", "/chats", query: [URLQueryItem(name: "limit", value: "20")]))
        var out: [WAMessage] = []
        // Only the chats that moved since `date` (sorted newest first by the gateway).
        for chat in chats.prefix(8) where chat.last > date {
            let data = try await scoped("GET", "/chat/\(WAHTTP.pathComponent(chat.jid))/messages", query: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "start_time", value: WADate.iso(date)),
            ])
            out += WAGOWA.messages(data, me: me).map { m in
                var m = m
                if m.chatName == nil, !chat.name.isEmpty, WAJID.isGroup(chat.jid) { m.chatName = chat.name }
                return m
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage] {
        let data = try await scoped("GET", "/chat/\(WAHTTP.pathComponent(chat))/messages",
                                    query: [URLQueryItem(name: "limit", value: String(limit))])
        return WAGOWA.messages(data, me: me).sorted { $0.date < $1.date }
    }

    func send(text: String, to chat: String, replyTo: String?) async throws -> String? {
        var body: [String: any Sendable] = ["phone": chat, "message": text]
        if let replyTo { body["reply_message_id"] = replyTo }
        let data = try await scoped("POST", "/send/message", json: body)
        return (WAGOWA.results(data) as? [String: Any])?["message_id"] as? String
    }

    func react(_ emoji: String, to message: String, chat: String, old: String?) async throws {
        _ = try await scoped("POST", "/message/\(WAHTTP.pathComponent(message))/reaction", json: ["phone": chat, "emoji": emoji])
    }

    func markRead(chat: String, lastIncoming: String?) async throws {
        guard let id = lastIncoming else { return }
        _ = try await scoped("POST", "/message/\(WAHTTP.pathComponent(id))/read", json: ["phone": chat])
    }

    func groupName(_ chat: String) async -> String? {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/group/info", query: [URLQueryItem(name: "group_id", value: chat)]),
              let r = WAGOWA.results(data) as? [String: Any],
              let name = r["Name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    func chats(limit: Int) async throws -> [WAChatInfo] {
        WAGOWA.chats(try await scoped("GET", "/chats", query: [URLQueryItem(name: "limit", value: String(limit))]))
            .map { WAChatInfo(jid: $0.jid, name: $0.name, last: $0.last) }
    }

    func avatar(_ chat: String) async -> URL? {
        guard let data = try? await scoped("GET", "/user/avatar", query: [
            URLQueryItem(name: "phone", value: chat), URLQueryItem(name: "is_preview", value: "true"),
            URLQueryItem(name: "is_community", value: "false"),
        ]) else { return nil }
        return WAAvatar.url(data)
    }

    /// GOWA saves the file under its own /statics first and says where; Nook then fetches it from the configured URL,
    /// whatever host the link names.
    func media(chat: String, message: String) async throws -> WAFile {
        let data = try await scoped("GET", "/message/\(WAHTTP.pathComponent(message))/download",
                                    query: [URLQueryItem(name: "phone", value: chat)], timeout: 60)
        guard let saved = WAGOWA.download(data) else { throw WAError.refused("media") }
        let (bytes, code, mime) = try await http.download(saved.path)
        guard code == 200 else { throw WAError.refused("HTTP \(code)") }
        return WAFile(data: bytes, name: saved.name, mimeType: mime)
    }
}

// MARK: - OpenWA

/// OpenWA (port 2785, every route under /api). Auth: `X-API-Key`. Nook works on one session
/// (the one ready, else one named "nook", created and started when missing).
actor OpenWAProvider: WhatsAppProvider {
    nonisolated let kind = WAGatewayKind.openwa
    private let http: WAHTTP
    private var sessionId: String?

    init(base: URL, apiKey: String?) {
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty { headers["X-API-Key"] = apiKey }
        http = WAHTTP(base: base, headers: headers)
    }

    private func check(_ data: Data, _ code: Int) throws {
        if code == 401 || code == 403 { throw WAError.unauthorized }
        guard (200..<300).contains(code) else {
            throw WAError.refused(WAOpenWA.errorMessage(data) ?? "HTTP \(code)")
        }
    }

    private func session() async throws -> (id: String, status: String, phone: String?) {
        let (data, code) = try await http.call("GET", "/api/sessions")
        try check(data, code)
        let all = ((try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []).compactMap(WAOpenWA.session)
        let pick = all.first { $0.status == "ready" }
            ?? all.first { ($0.id == sessionId) }
            ?? named("nook", in: data) ?? all.first
        if var s = pick {
            sessionId = s.id
            if WAOpenWA.needsStart(s.status) {
                let (started, startCode) = try await http.call("POST", "/api/sessions/\(s.id)/start")
                try check(started, startCode)
                s = WAOpenWA.session(try? JSONSerialization.jsonObject(with: started)) ?? s
            }
            return s
        }
        let (made, madeCode) = try await http.call("POST", "/api/sessions", json: ["name": "nook"])
        try check(made, madeCode)
        guard let s = WAOpenWA.session(try? JSONSerialization.jsonObject(with: made)) else { throw WAError.refused("session") }
        sessionId = s.id
        let (started, startCode) = try await http.call("POST", "/api/sessions/\(s.id)/start")
        try check(started, startCode)
        return WAOpenWA.session(try? JSONSerialization.jsonObject(with: started)) ?? s
    }

    private func named(_ name: String, in data: Data) -> (id: String, status: String, phone: String?)? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let s = list.first(where: { $0["name"] as? String == name }) else { return nil }
        return WAOpenWA.session(s)
    }

    private func sid() async throws -> String {
        if let sessionId { return sessionId }
        return try await session().id
    }

    private func scoped(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil) async throws -> Data {
        let id = try await sid()
        let (data, code) = try await http.call(method, "/api/sessions/\(id)" + path, query: query, json: json)
        try check(data, code)
        return data
    }

    func status() async throws -> WAStatus {
        WAOpenWA.status(try await session())
    }

    func qrCode() async throws -> (png: Data, seconds: Int)? {
        let id = try await sid()
        let (data, code) = try await http.call("GET", "/api/sessions/\(id)/qr")
        if code == 400 { return nil }   // not started, already linked, or not ready yet
        try check(data, code)
        // The QR turns every 20 s or so on WhatsApp's side: asked again after 15.
        return WAOpenWA.qrPNG(data).map { ($0, 15) }
    }

    func registerWebhook(url: String, secret: String) async throws {
        let id = try await sid()
        let body: [String: any Sendable] = ["url": url, "events": ["message.received", "message.sent", "message.ack", "message.reaction"],
                                            "secret": secret]
        let (list, listCode) = try await http.call("GET", "/api/sessions/\(id)/webhooks")
        try check(list, listCode)
        let hooks = (try? JSONSerialization.jsonObject(with: list)) as? [[String: Any]] ?? []
        if let mine = hooks.first(where: { $0["url"] as? String == url }), let hookId = mine["id"] as? String {
            let (data, code) = try await http.call("PUT", "/api/sessions/\(id)/webhooks/\(hookId)", json: body)
            try check(data, code)
        } else {
            let (data, code) = try await http.call("POST", "/api/sessions/\(id)/webhooks", json: body)
            try check(data, code)
        }
    }

    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage] {
        let data = try await scoped("GET", "/messages", query: [
            URLQueryItem(name: "since", value: String(Int64(date.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "inlineMedia", value: "false"),
        ])
        return WAOpenWA.messages(data, me: me).sorted { $0.date < $1.date }
    }

    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage] {
        let data = try await scoped("GET", "/messages", query: [
            URLQueryItem(name: "chatId", value: Self.openwaId(chat)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "inlineMedia", value: "false"),
        ])
        return WAOpenWA.messages(data, me: me).sorted { $0.date < $1.date }
    }

    func send(text: String, to chat: String, replyTo: String?) async throws -> String? {
        var body: [String: any Sendable] = ["chatId": Self.openwaId(chat), "text": text]
        if let replyTo { body["quotedMessageId"] = replyTo }
        let data = try await scoped("POST", "/messages/send-text", json: body)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["messageId"] as? String
    }

    /// An empty emoji takes the reaction back.
    func react(_ emoji: String, to message: String, chat: String, old: String?) async throws {
        _ = try await scoped("POST", "/messages/react", json: ["chatId": Self.openwaId(chat), "messageId": message, "emoji": emoji])
    }

    func markRead(chat: String, lastIncoming: String?) async throws {
        _ = try await scoped("POST", "/chats/read", json: ["chatId": Self.openwaId(chat)])
    }

    func groupName(_ chat: String) async -> String? {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/groups/\(WAHTTP.pathComponent(chat))"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    func avatar(_ chat: String) async -> URL? {
        let path = WAJID.isGroup(chat) ? "/groups/\(WAHTTP.pathComponent(chat))/picture"
            : "/contacts/\(WAHTTP.pathComponent(Self.openwaId(chat)))/profile-picture"
        guard let data = try? await scoped("GET", path) else { return nil }
        return WAAvatar.url(data)
    }

    func chats(limit: Int) async throws -> [WAChatInfo] {
        WAOpenWA.chats(try await scoped("GET", "/chats")).prefix(limit)
            .map { WAChatInfo(jid: WAJID.normalized($0.jid), name: $0.name, last: $0.last) }
    }

    func media(chat: String, message: String) async throws -> WAFile {
        let id = try await sid()
        let path = "/api/sessions/\(id)/messages/\(WAHTTP.pathComponent(Self.openwaId(chat)))/\(WAHTTP.pathComponent(message))/media"
        let (bytes, code, mime) = try await http.download(path)
        if code == 401 || code == 403 { throw WAError.unauthorized }
        guard code == 200 else { throw WAError.refused(WAOpenWA.errorMessage(bytes) ?? "HTTP \(code)") }
        return WAFile(data: bytes, name: nil, mimeType: mime)
    }

    /// OpenWA names people `<number>@c.us` (Nook keeps the @s.whatsapp.net form inside).
    static func openwaId(_ jid: String) -> String {
        jid.hasSuffix("@s.whatsapp.net") ? jid.replacingOccurrences(of: "@s.whatsapp.net", with: "@c.us") : jid
    }
}

// MARK: - Beeper

/// Beeper Desktop's local API (port 23373; turned on in Beeper › Settings › Developers). Auth: `Authorization: Bearer
/// <token>`. Every chat network linked in Beeper (WhatsApp, Telegram, Signal, Instagram, …) arrives as one list of
/// chats. Signing in happens in Beeper itself, so there is no QR; there is no webhook either, so Nook asks every few
/// seconds (all on this Mac, nothing leaves it).
actor BeeperProvider: WhatsAppProvider {
    nonisolated let kind = WAGatewayKind.beeper
    private let http: WAHTTP
    /// The user ids of this account, from the last status (to tell a mention of you).
    private var selves: [String] = []

    init(base: URL, token: String?) {
        var headers: [String: String] = [:]
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            headers["Authorization"] = "Bearer " + token
        }
        http = WAHTTP(base: base, headers: headers)
    }

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil) async throws -> Data {
        let (data, code) = try await http.call(method, path, query: query, json: json)
        if code == 401 || code == 403 { throw WAError.unauthorized }
        guard (200..<300).contains(code) else { throw WAError.refused(WABeeper.errorMessage(data) ?? "HTTP \(code)") }
        return data
    }

    private func chatPath(_ chat: String) -> String {
        "/v1/chats/" + WAHTTP.pathComponent(WAJID.beeperChat(chat))
    }

    /// One chat's newest messages under Nook's id for it, with its title.
    private func chatMessages(_ chat: String, name: String?) async throws -> [WAMessage] {
        WABeeper.messages(try await call("GET", chatPath(chat) + "/messages"), chat: chat, name: name, me: selves)
    }

    func status() async throws -> WAStatus {
        guard let accounts = WABeeper.accounts(try await call("GET", "/v1/accounts")) else {
            throw WAError.refused(tr("beeper.status.noAccounts"))
        }
        selves = accounts.me
        return WAStatus(link: accounts.link, me: nil)
    }

    func qrCode() async throws -> (png: Data, seconds: Int)? { nil }

    func registerWebhook(url: String, secret: String) async throws {}

    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage] {
        let chats = WABeeper.chats(try await call("GET", "/v1/chats", query: [URLQueryItem(name: "limit", value: "25")]))
        var out: [WAMessage] = []
        // Only the chats that moved since `date` (Beeper lists them newest first).
        for chat in chats.prefix(8) where chat.last > date {
            out += try await chatMessages(chat.jid, name: chat.name).filter { $0.date > date }
        }
        return out.sorted { $0.date < $1.date }
    }

    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage] {
        let newest = try await chatMessages(chat, name: nil).sorted { $0.date > $1.date }.prefix(limit)
        return newest.sorted { $0.date < $1.date }
    }

    func send(text: String, to chat: String, replyTo: String?) async throws -> String? {
        var body: [String: any Sendable] = ["text": text]
        if let replyTo { body["replyToMessageID"] = replyTo }
        let data = try await call("POST", chatPath(chat) + "/messages", json: body)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["pendingMessageID"] as? String
    }

    /// Beeper adds a reaction by its key and removes one by its key: taking yours back names the one you had.
    func react(_ emoji: String, to message: String, chat: String, old: String?) async throws {
        let path = chatPath(chat) + "/messages/" + WAHTTP.pathComponent(message) + "/reactions"
        if emoji.isEmpty {
            guard let old, !old.isEmpty else { return }
            _ = try await call("DELETE", path + "/" + WAHTTP.pathComponent(old))
        } else {
            _ = try await call("POST", path, json: ["reactionKey": emoji])
        }
    }

    func markRead(chat: String, lastIncoming: String?) async throws {
        var body: [String: any Sendable] = [:]
        if let lastIncoming { body["messageID"] = lastIncoming }
        _ = try await call("POST", chatPath(chat) + "/read", json: body)
    }

    func groupName(_ chat: String) async -> String? {
        guard WAJID.isGroup(chat), let data = try? await call("GET", chatPath(chat)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    func chats(limit: Int) async throws -> [WAChatInfo] {
        WABeeper.chats(try await call("GET", "/v1/chats", query: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]))
    }

    /// Where Beeper keeps the file, then the file itself from Beeper's own server: never another host.
    func media(chat: String, message: String) async throws -> WAFile {
        let data = try await call("GET", chatPath(chat) + "/messages/" + WAHTTP.pathComponent(message))
        guard let attachment = WABeeper.attachment(data) else { throw WAError.refused("media") }
        let (bytes, code, mime) = try await http.download("/v1/assets/serve", query: [URLQueryItem(name: "url", value: attachment.src)])
        if code == 401 || code == 403 { throw WAError.unauthorized }
        guard code == 200 else { throw WAError.refused(WABeeper.errorMessage(bytes) ?? "HTTP \(code)") }
        return WAFile(data: bytes, name: attachment.name, mimeType: mime)
    }
}
