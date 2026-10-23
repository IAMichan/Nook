// Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).

import Foundation

// The local gateways Nook can talk to for WhatsApp: GOWA and OpenWA. Each call goes to the URL set in
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
    /// The names of every group you are in, by JID, in one call: empty when the gateway cannot list them.
    func groupNames() async -> [String: String]
    /// A group's members (you among them), for who has your messages and who read them: empty when the gateway
    /// cannot list them.
    func groupMembers(_ chat: String) async -> [WAMember]
    /// The chats on the phone, newest first: who Nook may send to, by name.
    func chats(limit: Int) async throws -> [WAChatInfo]
    /// The file of one message (a document, photo, video or voice note), only when you open it.
    func media(chat: String, message: String) async throws -> WAFile
    /// Where a chat's picture is (a person's profile photo, a group's), on WhatsApp's own picture server; nil when it
    /// has none, hides it, or the gateway cannot say.
    func avatar(_ chat: String) async -> URL?
    /// The channels you follow, with their names (and pictures, when the gateway says).
    func channels() async -> [WAChannel]
    /// Whether this gateway can vote on a poll for you.
    var canVote: Bool { get }
    /// Votes on a poll with `choice` (the options' texts; empty takes your vote back).
    func vote(chat: String, poll: String, choice: [String]) async throws
    /// What this gateway can send besides text.
    var sends: Set<ChatOutgoing.Kind> { get }
    /// Sends a file, a poll, a place or a contact card to a chat, as an answer to `replyTo` where the gateway can;
    /// returns the new message's id when the gateway gives it.
    func send(_ outgoing: ChatOutgoing, to chat: String, replyTo: String?) async throws -> String?
}

extension WhatsAppProvider {
    func avatar(_ chat: String) async -> URL? { nil }
    func groupNames() async -> [String: String] { [:] }
    func groupMembers(_ chat: String) async -> [WAMember] { [] }
    func channels() async -> [WAChannel] { [] }
    var canVote: Bool { false }
    func vote(chat: String, poll: String, choice: [String]) async throws { throw WAError.refused("vote") }
    var sends: Set<ChatOutgoing.Kind> { [] }
    func send(_ outgoing: ChatOutgoing, to chat: String, replyTo: String?) async throws -> String? { throw WAError.refused("send") }
}

extension ChatAttachment {
    /// The file's bytes, read off the main thread by the gateway that sends it; refused when it is gone or too large.
    func read() throws -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { throw WAError.refused("file") }
        guard data.count <= ChatAttachment.maxBytes else { throw WAError.refused("too large") }
        return data
    }
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

    /// A file to the gateway as multipart form data: the fields, then the file.
    func upload(_ path: String, query: [URLQueryItem] = [], fields: [WAFormField], upload: WAUpload, data: Data,
                timeout: TimeInterval = 120) async throws -> (Data, Int) {
        let boundary = WAMultipart.boundary()
        let body = WAMultipart.body(boundary: boundary, fields: fields, upload: upload, data: data)
        let (answer, response) = try await perform("POST", path, query: query, json: nil, timeout: timeout, accept: "application/json",
                                                   body: (body, WAMultipart.contentType(boundary: boundary)))
        return (answer, response.statusCode)
    }

    /// A file from the gateway: its bytes, status code and MIME type.
    func download(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 60) async throws -> (Data, Int, String?) {
        let (data, response) = try await perform("GET", path, query: query, json: nil, timeout: timeout, accept: "*/*")
        return (data, response.statusCode, response.mimeType)
    }

    private func perform(_ method: String, _ path: String, query: [URLQueryItem], json: [String: any Sendable]?,
                         timeout: TimeInterval, accept: String,
                         body: (data: Data, type: String)? = nil) async throws -> (Data, HTTPURLResponse) {
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
        } else if let body {
            req.httpBody = body.data
            req.setValue(body.type, forHTTPHeaderField: "Content-Type")
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
            throw WAError.refused(WAGOWA.errorReason(data) ?? "HTTP \(code)")
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

    nonisolated var sends: Set<ChatOutgoing.Kind> { ChatOutgoing.Kind.everything }

    /// A file goes as form data with the device in the query, as every GOWA route takes it; the rest as JSON.
    func send(_ outgoing: ChatOutgoing, to chat: String, replyTo: String?) async throws -> String? {
        let request = WASend.gowa(outgoing, chat: chat, replyTo: replyTo)
        let data: Data
        if let upload = request.upload, case .file(let file) = outgoing {
            let bytes = try file.read()
            let id: String
            if let deviceId { id = deviceId } else { id = try await device().id }
            let (answer, code) = try await http.upload(request.path, query: [URLQueryItem(name: "device_id", value: id)],
                                                       fields: request.fields, upload: upload, data: bytes)
            try check(answer, code)
            data = answer
        } else {
            data = try await scoped("POST", request.path, json: request.json, timeout: 30)
        }
        return (WAGOWA.results(data) as? [String: Any])?["message_id"] as? String
    }

    func markRead(chat: String, lastIncoming: String?) async throws {
        guard let id = lastIncoming else { return }
        _ = try await scoped("POST", "/message/\(WAHTTP.pathComponent(id))/read", json: ["phone": chat])
    }

    func groupName(_ chat: String) async -> String? {
        guard let info = await groupInfo(chat) else { return nil }
        if let name = info.name { return name }
        // A community's announcement group has no name of its own: it takes its community's.
        guard let parent = info.parent, parent != chat else { return nil }
        return await groupInfo(parent)?.name
    }

    private func groupInfo(_ chat: String) async -> (name: String?, parent: String?)? {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/group/info", query: [URLQueryItem(name: "group_id", value: chat)]) else { return nil }
        return WAGOWA.groupInfo(data)
    }

    func groupNames() async -> [String: String] {
        guard let data = try? await scoped("GET", "/user/my/groups", timeout: 30) else { return [:] }
        return WAGOWA.groupNames(data)
    }

    func groupMembers(_ chat: String) async -> [WAMember] {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/group/info", query: [URLQueryItem(name: "group_id", value: chat)]) else { return [] }
        return WAGOWA.members(data)
    }

    /// Page by page (GOWA refuses more than 100 at once) until the list runs out or `limit` chats are in. A page that
    /// fails after the first keeps what came; one that brings nothing new ends it (a gateway that ignores the offset).
    func chats(limit: Int) async throws -> [WAChatInfo] {
        var out: [WAChatInfo] = []
        var seen = Set<String>()
        var offset: Int? = 0
        while let start = offset, out.count < limit {
            let data: Data
            do {
                data = try await scoped("GET", "/chats", query: [URLQueryItem(name: "limit", value: String(WAGOWA.chatPage)),
                                                                 URLQueryItem(name: "offset", value: String(start))])
            } catch {
                if out.isEmpty { throw error }
                break
            }
            let page = WAGOWA.chats(data).filter { seen.insert($0.jid).inserted }
            out += page.map { WAChatInfo(jid: $0.jid, name: $0.name, last: $0.last) }
            offset = page.isEmpty ? nil : WAGOWA.nextChatOffset(data, offset: start)
        }
        return Array(out.prefix(limit))
    }

    func channels() async -> [WAChannel] {
        guard let data = try? await scoped("GET", "/user/my/newsletters") else { return [] }
        return WAAvatar.gowaChannels(data)
    }

    func avatar(_ chat: String) async -> URL? {
        // A community's picture is only given when asked as one: a group without a picture is asked that way too.
        if let url = await avatar(chat, community: false) { return url }
        return WAJID.isGroup(chat) ? await avatar(chat, community: true) : nil
    }

    private func avatar(_ chat: String, community: Bool) async -> URL? {
        guard let data = try? await scoped("GET", "/user/avatar", query: [
            URLQueryItem(name: "phone", value: chat), URLQueryItem(name: "is_preview", value: "true"),
            URLQueryItem(name: "is_community", value: community ? "true" : "false"),
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

    private func scoped(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil,
                        timeout: TimeInterval = 10) async throws -> Data {
        let id = try await sid()
        let (data, code) = try await http.call(method, "/api/sessions/\(id)" + path, query: query, json: json, timeout: timeout)
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

    func groupMembers(_ chat: String) async -> [WAMember] {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/groups/\(WAHTTP.pathComponent(chat))"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return WAMembers.list(obj["participants"])
    }

    func channels() async -> [WAChannel] {
        guard let data = try? await scoped("GET", "/channels") else { return [] }
        return WAAvatar.openwaChannels(data)
    }

    nonisolated var canVote: Bool { true }

    nonisolated var sends: Set<ChatOutgoing.Kind> { ChatOutgoing.Kind.everything }

    func send(_ outgoing: ChatOutgoing, to chat: String, replyTo: String?) async throws -> String? {
        var bytes: Data?
        if case .file(let file) = outgoing { bytes = try file.read() }
        let request = WASend.openwa(outgoing, chatId: Self.openwaId(chat), replyTo: replyTo, data: bytes)
        let data = try await scoped("POST", request.path, json: request.json, timeout: bytes == nil ? 30 : 120)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["messageId"] as? String
    }

    func vote(chat: String, poll: String, choice: [String]) async throws {
        _ = try await scoped("POST", "/messages/vote-poll", json: ["chatId": Self.openwaId(chat), "pollMessageId": poll, "options": choice])
    }

    func avatar(_ chat: String) async -> URL? {
        let path = WAJID.isGroup(chat) ? "/groups/\(WAHTTP.pathComponent(chat))/picture"
            : "/contacts/\(WAHTTP.pathComponent(Self.openwaId(chat)))/profile-picture"
        guard let data = try? await scoped("GET", path) else { return nil }
        return WAAvatar.url(data)
    }

    func chats(limit: Int) async throws -> [WAChatInfo] {
        WAOpenWA.chats(try await scoped("GET", "/chats")).prefix(limit)
            .map { WAChatInfo(jid: WAJID.normalized($0.jid), name: $0.name, last: $0.last, unread: $0.unread) }
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
