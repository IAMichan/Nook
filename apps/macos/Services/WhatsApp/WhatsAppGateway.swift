// WhatsApp through a local gateway (GOWA or OpenWA) on this Mac: the messages, the conversations kept in memory, and
// what the gateways send and answer. Pure Foundation (and CryptoKit for the webhook's signature), tested without the app
// in Tests/NookTests/WhatsAppTests.swift. Nothing parsed here is ever written to disk or to a log.
//
// Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md). The gateway field names come from their docs:
//   GOWA   — github.com/aldinokemal/go-whatsapp-web-multidevice (docs/webhook-payload.md, docs/openapi.yaml)
//   OpenWA — github.com/rmyndharis/OpenWA (docs/06-api-specification.md)

import Foundation
import CryptoKit

/// What a message holds besides text: a label is shown, and the file itself is only fetched when the notch card shows it
/// (a photo, a video, a document) or you open it.
enum WAMedia: Equatable, Sendable {
    case none
    case image
    case video
    case audio(seconds: Int?)
    case voice(seconds: Int?)
    case document(name: String?)
    case sticker
    case location
    case contact
    case other
}

/// How far your own message got, as WhatsApp's ticks show it: one grey tick when the server has it, two when it
/// reached the phone, two blue ones once it was read.
enum WAReceipt: Int, Comparable, Sendable {
    case failed = -1, pending, sent, delivered, read

    static func < (a: WAReceipt, b: WAReceipt) -> Bool { a.rawValue < b.rawValue }

    /// A gateway's status word: OpenWA's `pending|sent|delivered|read|played|failed`, GOWA's `delivered|read|played`.
    init?(status: String) {
        switch status.lowercased() {
        case "pending": self = .pending
        case "sent", "server": self = .sent
        case "delivered", "delivery": self = .delivered
        case "read", "played": self = .read
        case "failed", "error": self = .failed
        default: return nil
        }
    }

    /// Ticks only move forward; a failure always shows.
    func advanced(to new: WAReceipt) -> WAReceipt {
        new == .failed || new > self ? new : self
    }
}

struct WAMessage: Identifiable, Equatable, Sendable {
    var id: String
    /// The conversation: a person (…@s.whatsapp.net, …@lid, …@c.us) or a group (…@g.us).
    var chat: String
    /// Who wrote it (in a group, the member; in a private chat, the chat itself).
    var sender: String
    var senderName: String
    var text: String
    var media: WAMedia = .none
    var date: Date
    var fromMe: Bool = false
    /// The message mentions this account (only meaningful in groups).
    var mentionsMe: Bool = false
    /// Set by the gateway when the chat name came with the message.
    var chatName: String? = nil
    /// Your own message's ticks; nil when they are unknown (someone else's message, or older history the gateway
    /// keeps no status for).
    var receipt: WAReceipt? = nil
}

extension WAMedia {
    /// A file Nook can fetch from the gateway and open on this Mac.
    var isOpenable: Bool {
        switch self {
        case .image, .video, .audio, .voice, .document: return true
        case .none, .sticker, .location, .contact, .other: return false
        }
    }
}

extension WAMessage {
    /// One line for the pill: the text, else the media's label (English keys, localized by the view).
    var previewKey: (key: String, value: String) {
        switch media {
        case .none: return ("", text)
        case .image: return ("whatsapp.media.photo", text)
        case .video: return ("whatsapp.media.video", text)
        case .audio(let s), .voice(let s): return ("whatsapp.media.voice", s.map(WAJID.duration) ?? "")
        case .document(let name): return ("whatsapp.media.document", name ?? text)
        case .sticker: return ("whatsapp.media.sticker", "")
        case .location: return ("whatsapp.media.location", "")
        case .contact: return ("whatsapp.media.contact", "")
        case .other: return ("whatsapp.media.other", text)
        }
    }
}

struct WAConversation: Identifiable, Equatable, Sendable {
    var id: String   // the chat JID
    var name: String
    var isGroup: Bool
    var kind: WAJID.Kind { WAJID.kind(id) }
    /// Newest last, the last `WAInbox.keep` only.
    var messages: [WAMessage] = []
    var unread: Int = 0
    var lastActivity: Date
}

/// What one chat does when a message arrives, chosen per chat in Settings › WhatsApp.
enum WAChatMode: String, CaseIterable, Sendable {
    /// Follows the rule of its kind (groups, status updates, channels stay quiet; people reach you).
    case automatic
    /// Always reaches you, even a group without a mention or a channel.
    case loud
    /// Never reaches you; the chat is kept and can be opened.
    case muted
}

/// What the user chose in Settings → WhatsApp.
struct WAFilters: Equatable, Sendable {
    /// Groups stay quiet unless the message mentions you.
    var muteGroups = true
    /// Status updates (status@broadcast) stay quiet.
    var muteStatus = true
    /// Channels (…@newsletter) stay quiet.
    var muteChannels = true
    /// Chats never shown (JIDs).
    var ignored: Set<String> = []
    /// Per chat (normalized JID): louder or quieter than its kind. Absent means automatic.
    var modes: [String: WAChatMode] = [:]

    func mode(for chat: String) -> WAChatMode { modes[WAJID.normalized(chat)] ?? .automatic }

    mutating func setMode(_ mode: WAChatMode, for chat: String) {
        let key = WAJID.normalized(chat)
        if mode == .automatic { modes[key] = nil } else { modes[key] = mode }
    }

    /// Whether a chat's kind keeps it quiet, before any per-chat choice.
    func kindIsQuiet(_ chat: String) -> Bool {
        switch WAJID.kind(chat) {
        case .person: return false
        case .group: return muteGroups
        case .status: return muteStatus
        case .channel: return muteChannels
        }
    }

    /// Whether a message in this chat stays silent: the per-chat choice first, then the kind's rule. A mention in an
    /// automatic group still reaches you; a muted chat never does.
    func isQuiet(_ chat: String, mentionsMe: Bool = false) -> Bool {
        switch mode(for: chat) {
        case .loud: return false
        case .muted: return true
        case .automatic: return kindIsQuiet(chat) && !(WAJID.kind(chat) == .group && mentionsMe)
        }
    }
}

enum WAJID {
    /// The kinds of chat WhatsApp has, told apart by the JID's server.
    enum Kind: String, Sendable { case person, group, status, channel }

    static func isGroup(_ jid: String) -> Bool { jid.hasSuffix("@g.us") }
    /// The status updates of your contacts arrive as one chat, status@broadcast.
    static func isStatus(_ jid: String) -> Bool { jid.lowercased().hasPrefix("status@") }
    /// A channel (a one-way broadcast you follow).
    static func isChannel(_ jid: String) -> Bool { jid.hasSuffix("@newsletter") }

    static func kind(_ jid: String) -> Kind {
        if isGroup(jid) { return .group }
        if isStatus(jid) { return .status }
        if isChannel(jid) { return .channel }
        return .person
    }

    /// "33612345678@s.whatsapp.net" → "+33 6 12 34 56 78"-ish: the digits with a plus.
    static func displayNumber(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = user.split(separator: ":").first.map(String.init) ?? user
        return digits.allSatisfy(\.isNumber) && !digits.isEmpty ? "+" + digits : digits
    }

    /// Two letters for the avatar: "Marie Dupont" → "MD", "+33 6…" → "#".
    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" }.filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "#" : letters.joined()
    }

    /// 12 → "0:12", 75 → "1:15".
    static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    /// The same person under its several forms: "33612345678:12@s.whatsapp.net" and
    /// "33612345678@c.us" are one chat.
    static func normalized(_ jid: String) -> String {
        let parts = jid.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return jid }
        let user = parts[0].split(separator: ":").first.map(String.init) ?? parts[0]
        let server = parts[1] == "c.us" ? "s.whatsapp.net" : parts[1]
        return "\(user)@\(server)"
    }

    /// The link that opens a person's chat in the WhatsApp Mac app: "whatsapp://send?phone=33612345678". Nil for a
    /// group, a channel or an id that is no phone number, which have no such link.
    static func appLink(_ jid: String) -> URL? {
        let parts = normalized(jid).split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1] == "s.whatsapp.net", !parts[0].isEmpty, parts[0].allSatisfy(\.isASCII),
              parts[0].allSatisfy(\.isNumber) else { return nil }
        return URL(string: "whatsapp://send?phone=" + parts[0])
    }
}

/// The conversations, grouped by chat: one entry per conversation, never one per message.
struct WAInbox: Equatable, Sendable {
    /// Messages kept per chat (in memory only): enough for the notch card to scroll back a while.
    static let keep = 50

    private(set) var conversations: [String: WAConversation] = [:]
    private var seenIds: Set<String> = []
    /// The same ids in arrival order, so the oldest are the ones forgotten.
    private var seenOrder: [String] = []
    /// Receipts that came before their message (the gateway's webhook can beat the answer to the send itself).
    private var earlyReceipts: [String: WAReceipt] = [:]

    /// Newest activity first.
    var sorted: [WAConversation] {
        conversations.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    var totalUnread: Int { conversations.values.reduce(0) { $0 + $1.unread } }

    enum Outcome: Equatable { case duplicate, ignored, quiet, notify }

    /// Adds a message to its conversation. `.notify` when it should reach you (Mochi reacts),
    /// `.quiet` when it is kept but stays silent (a muted group, your own message).
    /// `history`: an older message loaded on demand (a conversation opened): kept, never counted
    /// as unread, never announced.
    @discardableResult
    mutating func add(_ message: WAMessage, filters: WAFilters, name: String? = nil, history: Bool = false) -> Outcome {
        guard !seenIds.contains(message.id) else { return .duplicate }
        let chat = WAJID.normalized(message.chat)
        guard !filters.ignored.contains(chat) else { return .ignored }
        seenIds.insert(message.id)
        seenOrder.append(message.id)
        if seenOrder.count > 2_000 {
            let dropped = seenOrder.prefix(1_000)
            seenOrder.removeFirst(1_000)
            for id in dropped { seenIds.remove(id) }
        }

        let kind = WAJID.kind(chat)
        let isGroup = kind == .group
        let number = kind == .status ? tr("whatsapp.kind.status") : WAJID.displayNumber(chat)
        // In a private chat the other person names it: never your own name on your own message.
        let personName = kind != .person || message.fromMe ? nil : nonEmpty(message.senderName)
        var conversation = conversations[chat] ?? WAConversation(
            id: chat, name: name ?? message.chatName ?? personName ?? number,
            isGroup: isGroup, lastActivity: message.date)
        if let name = name ?? message.chatName, !name.isEmpty { conversation.name = name }
        else if conversation.name == number, let personName { conversation.name = personName }
        var msg = message
        msg.chat = chat
        if msg.fromMe {
            // Your own message that just went out has reached WhatsApp's server: one tick.
            if msg.receipt == nil, !history { msg.receipt = .sent }
            if let early = earlyReceipts.removeValue(forKey: msg.id) { msg.receipt = (msg.receipt ?? .sent).advanced(to: early) }
        }
        conversation.messages.append(msg)
        conversation.messages.sort { $0.date < $1.date }
        if conversation.messages.count > Self.keep { conversation.messages.removeFirst(conversation.messages.count - Self.keep) }
        conversation.lastActivity = max(conversation.lastActivity, message.date)

        let outcome: Outcome
        if history {
            outcome = .quiet
        } else if message.fromMe {
            // You answered from the phone: it is read there.
            conversation.unread = 0
            outcome = .quiet
        } else {
            conversation.unread += 1
            outcome = filters.isQuiet(chat, mentionsMe: message.mentionsMe) ? .quiet : .notify
        }
        conversations[chat] = conversation
        return outcome
    }

    /// A delivery or read receipt for your own messages: their ticks move forward, never back. The chat whose ticks
    /// changed, nil when none did (a receipt for an incoming message, or for one Nook doesn't keep).
    @discardableResult
    mutating func applyReceipt(_ status: WAReceipt, ids: [String], chat: String) -> String? {
        let key = WAJID.normalized(chat)
        // The gateway can name the chat differently (a person's @lid against their number): then every chat is looked at.
        let keys = conversations[key] != nil ? [key] : Array(conversations.keys)
        var pending = Set(ids)
        var changed: String?
        for chatKey in keys {
            guard var conversation = conversations[chatKey] else { continue }
            var touched = false
            for index in conversation.messages.indices where pending.contains(conversation.messages[index].id) {
                pending.remove(conversation.messages[index].id)
                guard conversation.messages[index].fromMe else { continue }
                let old = conversation.messages[index].receipt
                let new = (old ?? .sent).advanced(to: status)
                if new != old { conversation.messages[index].receipt = new; touched = true }
            }
            if touched { conversations[chatKey] = conversation; changed = chatKey }
            if pending.isEmpty { break }
        }
        // Not here yet: kept a little while for the message itself (only ids never seen; a few hundred at most).
        for id in pending where !seenIds.contains(id) {
            earlyReceipts[id] = (earlyReceipts[id] ?? status).advanced(to: status)
        }
        if earlyReceipts.count > 500 { earlyReceipts.removeAll() }
        return changed
    }

    /// The conversations the pill lists: quiet chats (a muted group, status updates, a channel, a chat you muted)
    /// stay out of it unless something in them mentions you.
    func visible(filters: WAFilters) -> [WAConversation] {
        sorted.filter { conversation in
            guard !filters.ignored.contains(conversation.id) else { return false }
            return conversation.messages.contains { !$0.fromMe && !filters.isQuiet(conversation.id, mentionsMe: $0.mentionsMe) }
                || !filters.isQuiet(conversation.id)
        }
    }

    /// Unread messages in the conversations the pill shows (a muted group's quiet messages
    /// and an ignored chat can't be opened, so they don't count).
    func visibleUnread(filters: WAFilters) -> Int {
        visible(filters: filters).reduce(0) { $0 + $1.unread }
    }

    /// A chat dropped from the inbox (the user ignores it).
    mutating func remove(_ chat: String) {
        conversations[WAJID.normalized(chat)] = nil
    }

    mutating func markRead(_ chat: String) {
        conversations[WAJID.normalized(chat)]?.unread = 0
    }

    /// History loaded at connection: whether it was read is unknown, so nothing counts as new.
    mutating func markAllRead() {
        for key in conversations.keys { conversations[key]?.unread = 0 }
    }

    mutating func rename(_ chat: String, to name: String) {
        guard !name.isEmpty else { return }
        conversations[WAJID.normalized(chat)]?.name = name
    }

    /// Everything goes (Nook quits, WhatsApp turned off).
    mutating func clear() {
        conversations = [:]
        seenIds = []
        seenOrder = []
        earlyReceipts = [:]
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

/// What may be sent from the notch: a reply, in a conversation already there, one at a time.
enum WAReply {
    enum Refusal: Equatable, Sendable { case empty, tooLong, notAConversation }
    /// The gateways' own cap (OpenWA's send-text takes 4,096 characters at most).
    static let maxLength = 4096

    static func check(_ text: String, to chat: String, in inbox: WAInbox) -> Refusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maxLength { return .tooLong }
        // Never a new chat, never a list of recipients: only a conversation that wrote to you.
        guard inbox.conversations[WAJID.normalized(chat)] != nil else { return .notAConversation }
        return nil
    }
}

/// A few sends a minute at most, whatever is clicked: Nook is no bulk sender.
struct WARateLimit: Sendable {
    var limit = 6
    var window: TimeInterval = 60
    private(set) var sent: [Date] = []

    init(limit: Int = 6, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(now: Date = Date()) -> Bool {
        sent.removeAll { now.timeIntervalSince($0) > window }
        guard sent.count < limit else { return false }
        sent.append(now)
        return true
    }
}

// MARK: - The webhook's HTTP request

/// One HTTP request read from the local socket: enough of HTTP/1.1 for a gateway's webhook.
struct WAHTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Lowercased names.
    var headers: [String: String]
    var body: Data

    enum Parse: Equatable { case incomplete, invalid, done(WAHTTPRequest) }

    /// Parses what arrived so far; `.incomplete` until the whole body is there.
    static func parse(_ data: Data, maxBody: Int = 1_000_000) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16_384 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .done(WAHTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body)))
    }

    static func response(_ status: Int, _ reason: String) -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}

// MARK: - Hex

extension Data {
    var waHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Compares two strings in constant time (signatures).
func waConstantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}

enum WAGatewayKind: String, CaseIterable, Sendable {
    case gowa, openwa

    var name: String { self == .gowa ? "GOWA" : "OpenWA" }
    var defaultURL: String { self == .gowa ? "http://127.0.0.1:3000" : "http://127.0.0.1:2785" }
    /// The header carrying the webhook's HMAC-SHA256 ("sha256=<hex>"), lowercased.
    var signatureHeader: String { self == .gowa ? "x-hub-signature-256" : "x-openwa-signature" }
}

/// What one webhook delivery holds for Nook.
enum WAWebhookEvent: Equatable, Sendable {
    case message(WAMessage)
    /// Your own messages reached the phone or were read: their ticks move.
    case receipt(ids: [String], chat: String, status: WAReceipt)
    /// A valid delivery Nook has no use for (reactions, a test ping…).
    case ignored
}

enum WAWebhook {
    /// "sha256=<lowercase hex>" of HMAC-SHA256(secret, body): what both gateways send.
    static func signature(body: Data, secret: String) -> String {
        "sha256=" + waHMACSHA256(key: Data(secret.utf8), message: body).waHex
    }

    /// True when the delivery carries the signature `secret` gives, over the raw body bytes.
    static func verify(kind: WAGatewayKind, headers: [String: String], body: Data, secret: String) -> Bool {
        guard !secret.isEmpty, let sent = headers[kind.signatureHeader], sent.hasPrefix("sha256=") else { return false }
        return waConstantTimeEqual(sent, signature(body: body, secret: secret))
    }

    /// Parses one delivery. nil when it isn't JSON at all. `me` is this account's JID or number,
    /// to tell a mention of you (GOWA also gives it in the delivery itself).
    static func parse(kind: WAGatewayKind, body: Data, me: String? = nil) -> WAWebhookEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        switch kind {
        case .gowa:   return parseGOWA(json, me: me)
        case .openwa: return parseOpenWA(json, me: me)
        }
    }

    // MARK: GOWA

    /// `{"event":"message","device_id":"<own JID>","payload":{id, chat_id, from, from_name,
    /// sender_display_name, timestamp (RFC3339), is_from_me, body, image|video|audio|document|…}}`
    private static func parseGOWA(_ json: [String: Any], me: String?) -> WAWebhookEvent {
        if json["event"] as? String == "message.ack" { return parseGOWAReceipt(json) }
        guard json["event"] as? String == "message",
              let p = json["payload"] as? [String: Any],
              let id = p["id"] as? String, !id.isEmpty,
              let chat = p["chat_id"] as? String, !chat.isEmpty else { return .ignored }
        let from = (p["from"] as? String) ?? chat
        let text = (p["body"] as? String) ?? ""
        let mine = me ?? (json["device_id"] as? String)
        var message = WAMessage(
            id: id, chat: chat, sender: from,
            senderName: nonEmpty(p["sender_display_name"]) ?? nonEmpty(p["from_name"]) ?? "",
            text: text, media: gowaMedia(p),
            date: WADate.rfc3339(p["timestamp"] as? String) ?? Date(),
            fromMe: p["is_from_me"] as? Bool ?? false)
        message.mentionsMe = WAJID.isGroup(chat) && WAMention.textMentions(text, me: mine)
        return .message(message)
    }

    /// `{"event":"message.ack","payload":{ids, chat_id, from, receipt_type: "delivered"|"read"|"played"|…}}`.
    /// A group sends one per member, while WhatsApp's own ticks wait for every member: a group keeps its one tick.
    /// The `-self` receipts are your own phone reading incoming messages, which have no ticks.
    private static func parseGOWAReceipt(_ json: [String: Any]) -> WAWebhookEvent {
        guard let p = json["payload"] as? [String: Any],
              let chat = p["chat_id"] as? String, !chat.isEmpty, !WAJID.isGroup(chat),
              let ids = (p["ids"] as? [String])?.filter({ !$0.isEmpty }), !ids.isEmpty,
              let type = p["receipt_type"] as? String, !type.hasSuffix("-self"),
              let status = WAReceipt(status: type), status >= .delivered else { return .ignored }
        return .receipt(ids: ids, chat: chat, status: status)
    }

    /// GOWA puts each media under its own key; only the label matters to Nook.
    static func gowaMedia(_ p: [String: Any]) -> WAMedia {
        if p["image"] != nil { return .image }
        if p["video"] != nil || p["video_note"] != nil { return .video }
        if p["audio"] != nil { return .voice(seconds: nil) }
        if let doc = p["document"] {
            return .document(name: (doc as? [String: Any]).flatMap { nonEmpty($0["filename"]) })
        }
        if p["sticker"] != nil { return .sticker }
        if p["location"] != nil || p["live_location"] != nil { return .location }
        if p["contact"] != nil || p["contacts_array"] != nil { return .contact }
        if p["poll"] != nil { return .other }
        return .none
    }

    // MARK: OpenWA

    /// `{"event":"message.received"|"message.sent","sessionId","data":{id, from, to, chatId, author,
    /// body, type, timestamp (epoch s), fromMe, isGroup, mentionedIds, contact{name, pushName}, media{filename}}}`
    private static func parseOpenWA(_ json: [String: Any], me: String?) -> WAWebhookEvent {
        let event = json["event"] as? String
        if event == "message.ack" || event == "message.failed" { return parseOpenWAReceipt(json) }
        guard event == "message.received" || event == "message.sent",
              let d = json["data"] as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty,
              let chat = (d["chatId"] as? String) ?? (d["from"] as? String), !chat.isEmpty else { return .ignored }
        let type = (d["type"] as? String) ?? "text"
        guard type != "revoked" else { return .ignored }
        let fromMe = (d["fromMe"] as? Bool) ?? (event == "message.sent")
        let contact = d["contact"] as? [String: Any]
        let media = d["media"] as? [String: Any]
        var message = WAMessage(
            id: id, chat: chat,
            sender: nonEmpty(d["author"]) ?? (d["from"] as? String) ?? chat,
            senderName: nonEmpty(contact?["name"]) ?? nonEmpty(contact?["pushName"]) ?? "",
            text: (d["body"] as? String) ?? "",
            media: openwaMedia(type, filename: nonEmpty(media?["filename"])),
            date: WADate.epoch(d["timestamp"]) ?? Date(),
            fromMe: fromMe)
        let isGroup = (d["isGroup"] as? Bool) ?? WAJID.isGroup(chat)
        if isGroup, let mine = me {
            let ids = (d["mentionedIds"] as? [String]) ?? []
            message.mentionsMe = ids.contains { WAJID.sameUser($0, mine) } || WAMention.textMentions(message.text, me: mine)
        }
        return .message(message)
    }

    /// `{"event":"message.ack"|"message.failed","data":{id, messageId, status, ack, chatId?}}`. OpenWA only moves a
    /// group message past one tick when WhatsApp itself does.
    private static func parseOpenWAReceipt(_ json: [String: Any]) -> WAWebhookEvent {
        guard let d = json["data"] as? [String: Any],
              let id = nonEmpty(d["messageId"]) ?? nonEmpty(d["id"]),
              let status = (d["status"] as? String).flatMap(WAReceipt.init(status:)) else { return .ignored }
        return .receipt(ids: [id], chat: (d["chatId"] as? String) ?? "", status: status)
    }

    /// OpenWA's `type` (text|image|video|audio|voice|document|sticker|location|contact|poll|…).
    static func openwaMedia(_ type: String, filename: String? = nil) -> WAMedia {
        switch type {
        case "text", "":  return .none
        case "image":     return .image
        case "video":     return .video
        case "audio":     return .audio(seconds: nil)
        case "voice":     return .voice(seconds: nil)
        case "document":  return .document(name: filename)
        case "sticker":   return .sticker
        case "location":  return .location
        case "contact":   return .contact
        default:          return .other
        }
    }
}

// MARK: - REST answers (status, QR, polling)

/// What a gateway says of the WhatsApp link.
struct WAStatus: Equatable, Sendable {
    enum Link: Equatable, Sendable {
        /// Logged in and online.
        case connected
        /// Waiting for the QR to be scanned.
        case needsQR
        /// Logged in but offline, starting, or anything in between.
        case connecting
    }
    var link: Link
    /// This account's JID or number, once logged in.
    var me: String?
}

enum WAGOWA {
    /// GOWA's envelope: `{code, message, results}` (no "status": the HTTP code says it).
    static func results(_ data: Data) -> Any? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"]
    }

    /// `GET /devices` → `results: [{id, phone_number, display_name, state, jid, created_at}]`.
    /// The device Nook uses: a logged-in one first, else the first one.
    static func device(_ data: Data) -> (id: String, status: WAStatus)? {
        guard let list = results(data) as? [[String: Any]], !list.isEmpty else { return nil }
        let pick = list.first { $0["state"] as? String == "logged_in" } ?? list[0]
        guard let id = pick["id"] as? String, !id.isEmpty else { return nil }
        let jid = nonEmpty(pick["jid"])
        let link: WAStatus.Link
        switch pick["state"] as? String {
        case "logged_in": link = .connected
        case "connecting", "connected": link = jid == nil ? .needsQR : .connecting
        default: link = jid == nil ? .needsQR : .connecting
        }
        return (id, WAStatus(link: link, me: jid))
    }

    /// `GET /devices/{id}/login` → `results: {device_id, qr_link, qr_duration}`. The PNG's path,
    /// to fetch from the gateway itself (never from another host the link may name).
    static func qrPath(_ data: Data) -> (path: String, seconds: Int)? {
        guard let r = results(data) as? [String: Any], let link = r["qr_link"] as? String,
              let url = URL(string: link), !url.path.isEmpty else { return nil }
        return (url.path, (r["qr_duration"] as? Int) ?? 30)
    }

    /// `./whatsapp rest` for Nook's "Start GOWA automatically": on this Mac only, on the
    /// URL's port, and media not downloaded on arrival: only a file Nook asks for (one the
    /// notch card shows, one you open) is fetched.
    static func launchArguments(for url: URL) -> [String] {
        ["rest", "--host=127.0.0.1", "--port=\(url.port ?? 3000)", "--auto-download-media=false"]
    }

    /// The error code of a refused call (`ALREADY_LOGGED_IN`, `DEVICE_ID_REQUIRED`…).
    static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String
    }

    /// `GET /chats` → `results: {data: [{jid, name, last_message_time, …}], pagination}`.
    static func chats(_ data: Data) -> [(jid: String, name: String, last: Date)] {
        guard let r = results(data) as? [String: Any], let list = r["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let jid = c["jid"] as? String, !jid.isEmpty else { return nil }
            return (jid, (c["name"] as? String) ?? "", WADate.rfc3339(c["last_message_time"] as? String) ?? .distantPast)
        }
    }

    /// `GET /chat/{jid}/messages` → `results: {data: [{id, chat_jid, sender_jid, sender_display_name,
    /// content, timestamp, is_from_me, media_type, filename}], chat_info}`. Newest first there.
    static func messages(_ data: Data, me: String?) -> [WAMessage] {
        guard let r = results(data) as? [String: Any], let list = r["data"] as? [[String: Any]] else { return [] }
        let chatName = nonEmpty((r["chat_info"] as? [String: Any])?["name"])
        return list.compactMap { m in
            guard let id = m["id"] as? String, let chat = m["chat_jid"] as? String else { return nil }
            let text = (m["content"] as? String) ?? ""
            var msg = WAMessage(
                id: id, chat: chat, sender: (m["sender_jid"] as? String) ?? chat,
                senderName: nonEmpty(m["sender_display_name"]) ?? "",
                text: text, media: gowaStoredMedia(m["media_type"] as? String, filename: nonEmpty(m["filename"])),
                date: WADate.rfc3339(m["timestamp"] as? String) ?? .distantPast,
                fromMe: m["is_from_me"] as? Bool ?? false)
            msg.chatName = WAJID.isGroup(chat) ? chatName : nil
            msg.mentionsMe = WAJID.isGroup(chat) && WAMention.textMentions(text, me: me)
            return msg
        }
    }

    /// `GET /message/{id}/download` → `results: {filename, file_path, file_url}`. The saved file's path on the
    /// gateway (from `file_url`, else `file_path` under /statics), to fetch from the gateway itself, and its name.
    static func download(_ data: Data) -> (path: String, name: String?)? {
        guard let r = results(data) as? [String: Any] else { return nil }
        let name = nonEmpty(r["filename"])
        if let link = r["file_url"] as? String, let comps = URLComponents(string: link),
           comps.percentEncodedPath.count > 1 {
            return (comps.percentEncodedPath, name)
        }
        if let file = r["file_path"] as? String, file.hasPrefix("statics/"), !file.contains(".."),
           let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return ("/" + encoded, name)
        }
        return nil
    }

    /// `media_type` of a stored message: image|video|video_note|audio|document|sticker|call or "".
    static func gowaStoredMedia(_ type: String?, filename: String?) -> WAMedia {
        switch type ?? "" {
        case "":                    return .none
        case "image":               return .image
        case "video", "video_note": return .video
        case "audio":               return .voice(seconds: nil)
        case "document":            return .document(name: filename)
        case "sticker":             return .sticker
        default:                    return .other
        }
    }
}

/// GOWA's own releases on GitHub, for "Install WhatsApp" (one click, no Terminal): which zip
/// fits this Mac and the SHA-256 GOWA publishes for it. The release workflow (GoReleaser,
/// .github/workflows/release.yml in GOWA's repo) names them `whatsapp_<version>_darwin_<arch>.zip`
/// (the binary inside is `darwin-<arch>`) next to `checksums-macos.txt`.
enum WAGOWARelease {
    static let latestURL = URL(string: "https://api.github.com/repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest")!

    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
        let size: Int
        /// "sha256:<hex>" when GitHub gives it.
        let digest: String?
    }

    /// `GET /releases/latest` → `{tag_name, assets: [{name, browser_download_url, size, digest?}]}`.
    static func parse(_ data: Data) -> (version: String, assets: [Asset])? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String, let list = obj["assets"] as? [[String: Any]] else { return nil }
        let assets: [Asset] = list.compactMap { a in
            guard let name = a["name"] as? String, let s = a["browser_download_url"] as? String,
                  let url = URL(string: s) else { return nil }
            return Asset(name: name, url: url, size: (a["size"] as? Int) ?? 0, digest: a["digest"] as? String)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return (version, assets)
    }

    /// The zip for this Mac ("arm64" or "amd64") and the macOS checksums file.
    static func pick(_ assets: [Asset], arch: String) -> (zip: Asset, checksums: Asset?)? {
        guard let zip = assets.first(where: { $0.name.hasPrefix("whatsapp_") && $0.name.hasSuffix("_darwin_\(arch).zip") }) else { return nil }
        return (zip, assets.first { $0.name == "checksums-macos.txt" })
    }

    /// The binary's name inside the zip.
    static func binaryName(arch: String) -> String { "darwin-\(arch)" }

    /// The SHA-256 (lowercase hex) of `name` in a GoReleaser checksums file ("<hex>  <name>" per line),
    /// else from GitHub's own "sha256:<hex>" digest.
    static func expectedSHA256(for asset: Asset, checksums: String?) -> String? {
        for line in (checksums ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == Substring(asset.name), parts[0].count == 64 { return parts[0].lowercased() }
        }
        if let d = asset.digest, d.hasPrefix("sha256:"), d.count == 71 { return String(d.dropFirst(7)).lowercased() }
        return nil
    }

    /// Only GitHub serves the download (its assets redirect to githubusercontent.com).
    static func allowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }
}

enum WAOpenWA {
    /// A session: `{id (uuid), name, status, phone, pushName, …}`.
    /// status: created|initializing|qr_ready|authenticating|ready|disconnected|action_required|failed.
    static func session(_ obj: Any?) -> (id: String, status: String, phone: String?)? {
        guard let s = obj as? [String: Any], let id = s["id"] as? String, !id.isEmpty else { return nil }
        return (id, (s["status"] as? String) ?? "", nonEmpty(s["phone"]))
    }

    /// `GET /api/sessions?name=…` → a bare array of sessions.
    static func firstSession(_ data: Data) -> (id: String, status: String, phone: String?)? {
        let json = try? JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] { return list.lazy.compactMap(session).first }
        return session(json)
    }

    static func status(_ s: (id: String, status: String, phone: String?)) -> WAStatus {
        switch s.status {
        case "ready":                 return WAStatus(link: .connected, me: s.phone)
        case "qr_ready":              return WAStatus(link: .needsQR, me: nil)
        default:                      return WAStatus(link: .connecting, me: s.phone)
        }
    }

    /// Sessions that must be started before a QR can come: never started, stopped or failed.
    static func needsStart(_ status: String) -> Bool {
        ["created", "disconnected", "failed"].contains(status)
    }

    /// `GET /api/sessions/{id}/qr` → `{qrCode: "data:image/png;base64,…", status}`: the PNG bytes.
    static func qrPNG(_ data: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = obj["qrCode"] as? String,
              let comma = url.firstIndex(of: ","), url.hasPrefix("data:image/png;base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// `GET /api/sessions/{id}/chats` → bare `[{id, name, isGroup, unreadCount, timestamp, …}]`.
    static func chats(_ data: Data) -> [(jid: String, name: String, unread: Int, last: Date)] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let id = c["id"] as? String, !id.isEmpty else { return nil }
            return (id, (c["name"] as? String) ?? "", (c["unreadCount"] as? Int) ?? 0, WADate.epoch(c["timestamp"]) ?? .distantPast)
        }
    }

    /// `GET /api/sessions/{id}/messages` → `{messages: [{waMessageId, chatId, from, author, chatName,
    /// body, type, direction, timestamp (s), metadata}], total}`.
    static func messages(_ data: Data, me: String?) -> [WAMessage] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["messages"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = nonEmpty(m["waMessageId"]) ?? nonEmpty(m["id"]),
                  let chat = m["chatId"] as? String, !chat.isEmpty else { return nil }
            let type = (m["type"] as? String) ?? "text"
            guard type != "revoked" else { return nil }
            let media = (m["metadata"] as? [String: Any])?["media"] as? [String: Any]
            var msg = WAMessage(
                id: id, chat: chat, sender: nonEmpty(m["author"]) ?? (m["from"] as? String) ?? chat,
                senderName: "", text: (m["body"] as? String) ?? "",
                media: WAWebhook.openwaMedia(type, filename: nonEmpty(media?["filename"])),
                date: WADate.epoch(m["timestamp"]) ?? .distantPast,
                fromMe: m["direction"] as? String == "outgoing")
            msg.chatName = nonEmpty(m["chatName"])
            if msg.fromMe { msg.receipt = (m["status"] as? String).flatMap(WAReceipt.init(status:)) }
            if WAJID.isGroup(chat), let me { msg.mentionsMe = WAMention.textMentions(msg.text, me: me) }
            return msg
        }
    }

    /// NestJS error: `{statusCode, message (string or [string]), error}`.
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let s = obj["message"] as? String { return s }
        return (obj["message"] as? [String])?.joined(separator: ", ")
    }
}

// MARK: - Helpers

enum WAMention {
    /// "@33612345678" in the text, for this account's number (how GOWA shows a mention of you).
    static func textMentions(_ text: String, me: String?) -> Bool {
        guard let me, case let digits = WAJID.digits(me), digits.count >= 6 else { return false }
        return text.contains("@" + digits)
    }
}

extension WAJID {
    /// The user part's digits: "33612345678:3@s.whatsapp.net" → "33612345678".
    static func digits(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let base = user.split(separator: ":").first.map(String.init) ?? user
        return base.filter(\.isNumber)
    }

    /// Two ids of the same person, whatever their server part (@c.us, @s.whatsapp.net, a bare number).
    static func sameUser(_ a: String, _ b: String) -> Bool {
        let x = digits(a), y = digits(b)
        return !x.isEmpty && x == y
    }
}

enum WADate {
    static func rfc3339(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return standard.date(from: s) ?? NookDates.isoFractional.date(from: s)
    }

    static func iso(_ date: Date) -> String { standard.string(from: date) }

    /// Default options, UTC; never changed, so one serves every message.
    private static let standard = ISO8601DateFormatter()

    /// Epoch seconds, as a number or a numeric string.
    static func epoch(_ v: Any?) -> Date? {
        if let n = v as? Double, n > 0 { return Date(timeIntervalSince1970: n) }
        if let n = v as? Int, n > 0 { return Date(timeIntervalSince1970: TimeInterval(n)) }
        if let s = v as? String, let n = Double(s), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }
}

private func nonEmpty(_ v: Any?) -> String? {
    guard let s = v as? String, !s.isEmpty else { return nil }
    return s
}

// MARK: - Text for the brain

/// Pure helpers: who a recipient means, and messages as text. Tested in WhatsAppTests.
enum WhatsAppRecipients {
    /// A chat by id or number, else by name: exact, then the first name or a word of it, then a part of it.
    /// Nil when nothing matches or two different chats match equally well.
    static func match(_ wanted: String, in chats: [(jid: String, name: String)]) -> (jid: String, name: String)? {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let query = fold(wanted)
        if wanted.contains("@"), let chat = chats.first(where: { WAJID.normalized($0.jid) == WAJID.normalized(wanted) }) {
            return chat
        }
        let digits = wanted.filter(\.isNumber)
        if digits.count >= 8, digits.count * 2 >= wanted.filter({ !$0.isWhitespace }).count {
            if let chat = chats.first(where: { WAJID.digits($0.jid).hasSuffix(String(digits.suffix(9))) }) { return chat }
            return nil
        }
        func unique(_ found: [(jid: String, name: String)]) -> (jid: String, name: String)? {
            let ids = Set(found.map(\.jid))
            return ids.count == 1 ? found.first : nil
        }
        let exact = chats.filter { fold($0.name) == query }
        if !exact.isEmpty { return unique(exact) }
        let word = chats.filter { fold($0.name).split(separator: " ").contains { String($0) == query } }
        if !word.isEmpty { return unique(word) }
        guard query.count >= 3 else { return nil }
        let partly = chats.filter { fold($0.name).contains(query) }
        if !partly.isEmpty { return unique(partly) }
        // A typo ("Lsia"): the one name that is close, never a guess between two.
        guard let name = Fuzzy.best(wanted, in: chats.map(\.name)) else { return nil }
        return unique(chats.filter { $0.name == name })
    }

    static func label(_ media: WAMedia) -> String? {
        switch media {
        case .none: return nil
        case .image: return "[photo]"
        case .video: return "[video]"
        case .audio, .voice: return "[voice message]"
        case .document(let name): return "[document\(name.map { ": \($0)" } ?? "")]"
        case .sticker: return "[sticker]"
        case .location: return "[location]"
        case .contact: return "[contact]"
        case .other: return "[attachment]"
        }
    }

    /// One line per message: "2026-10-18 14:02 Lisa: text".
    static func lines(_ messages: [WAMessage], chatName: String, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return messages.sorted { $0.date < $1.date }.map { message in
            let who = message.fromMe ? "Me" : (message.senderName.isEmpty ? chatName : message.senderName)
            let text = [label(message.media), message.text.isEmpty ? nil : message.text].compactMap { $0 }.joined(separator: " ")
            return "\(format.string(from: message.date)) \(who): \(text)"
        }.joined(separator: "\n")
    }

    /// The conversations with something new, for the brain's context and the overview tool.
    static func overview(_ conversations: [WAConversation], limit: Int = 12) -> String {
        conversations.prefix(limit).map { conversation in
            let last = conversation.messages.last
            let preview = last.map { message in
                (message.fromMe ? "Me: " : "") + ([label(message.media), message.text.isEmpty ? nil : String(message.text.prefix(120))]
                    .compactMap { $0 }.joined(separator: " "))
            } ?? ""
            let unread = conversation.unread > 0 ? " (\(conversation.unread) unread)" : ""
            return "- \(conversation.name)\(conversation.isGroup ? " [group]" : "")\(unread): \(preview)"
        }.joined(separator: "\n")
    }
}

// MARK: - HMAC-SHA256

func waHMACSHA256(key: Data, message: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
}
