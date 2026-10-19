import Foundation

// Nook Companion: the iPhone app that shows which sessions need you, and lets you approve, answer, send and stop.
// This file is shared by the Mac app and the iPhone app and depends on Foundation only, so its rules are tested on Linux.
//
// Security model (docs/COMPANION.md):
// - A device pairs once with a 32-byte key that the Mac shows as a code (QR or text) while a pairing window of five minutes
//   is open. The key never travels over the network again.
// - Every message is sealed (ChaCha20-Poly1305, see CompanionSeal) with a key derived from it, so the network sees neither
//   session titles nor commands, and a message cannot be changed or forged.
// - A request carries a timestamp and a unique id; the Mac refuses old ones and repeats (RequestGuard).
// - The phone may approve only what is low risk (CompanionPolicy); anything else it can deny or leave for the Mac.

enum CompanionConstants {
    static let bonjourType = "_nookcompanion._tcp"
    static let linkScheme = "nook"
    static let linkHost = "pair"
    static let maxFrame = 256 * 1024
    /// How far a request's clock may differ from the Mac's.
    static let freshness: TimeInterval = 60
    static let pairingWindow: TimeInterval = 300
    static let excerptLimit = 600
}

/// What the Mac shows to pair: where to connect and the key. `nook://pair?h=<host>&p=<port>&k=<base64url key>&n=<name>`.
struct PairingLink: Equatable, Sendable {
    var host: String
    var port: UInt16
    var key: Data
    var macName: String

    static let keyLength = 32

    var url: URL? {
        var c = URLComponents()
        c.scheme = CompanionConstants.linkScheme
        c.host = CompanionConstants.linkHost
        c.queryItems = [URLQueryItem(name: "h", value: host), URLQueryItem(name: "p", value: String(port)),
                        URLQueryItem(name: "k", value: Base64URL.encode(key)), URLQueryItem(name: "n", value: macName)]
        return c.url
    }

    static func parse(_ text: String) -> PairingLink? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == CompanionConstants.linkScheme, c.host == CompanionConstants.linkHost else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        guard let host = q["h"], validHost(host), let portText = q["p"], let port = UInt16(portText), port > 0,
              let keyText = q["k"], let key = Base64URL.decode(keyText), key.count == keyLength else { return nil }
        let name = String((q["n"] ?? "Mac").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(60))
        return PairingLink(host: host, port: port, key: key, macName: name.isEmpty ? "Mac" : name)
    }

    /// An IPv4/IPv6 address or a host name; nothing with a scheme, path, credentials or spaces.
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.allSatisfy { $0.isLetter || $0.isNumber || "-._:".contains($0) }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

// MARK: Messages

enum CompanionOp: String, Codable, Sendable {
    case hello, list, decide, answer, send, stop
    /// The phone's APNs token (`text`, hex) and its environment (`item`: "production" or "development"); `unregister` removes it.
    case register, unregister
}

/// One request from the phone. `id` is unique per request; `sent` is the phone's clock (seconds since 1970).
struct CompanionRequest: Codable, Equatable, Sendable {
    var id: String
    var sent: Double
    var op: CompanionOp
    var session: String?
    var item: String?
    var text: String?
    var allow: Bool?

    init(id: String = UUID().uuidString, sent: Double = Date().timeIntervalSince1970, op: CompanionOp, session: String? = nil,
         item: String? = nil, text: String? = nil, allow: Bool? = nil) {
        self.id = id; self.sent = sent; self.op = op; self.session = session; self.item = item; self.text = text; self.allow = allow
    }
}

enum CompanionError: String, Codable, Sendable {
    case stale, replay, rateLimited, unknownSession, unknownItem, notAllowedFromPhone, badRequest, busy, failed
}

struct CompanionResponse: Codable, Equatable, Sendable {
    var id: String
    var ok: Bool
    var error: CompanionError?
    var macName: String?
    var sessions: [SessionDigest]?
    var message: String?

    static func failure(_ id: String, _ error: CompanionError, message: String? = nil) -> CompanionResponse {
        CompanionResponse(id: id, ok: false, error: error, message: message)
    }
}

/// What the phone is told about a session that matters now. Titles and excerpts are cut: the phone is not a log viewer.
struct SessionDigest: Codable, Equatable, Identifiable, Sendable {
    /// What waits on you in this session.
    struct Item: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case approval, question }
        var id: String
        var kind: Kind
        var title: String
        var detail: String
        /// The phone may allow this one. When false it can only deny it or leave it to the Mac.
        var canAllow: Bool
        var options: [String]
    }

    var id: String
    var title: String
    var agent: String
    /// `AgentAttention` raw value: approval, input, failed, limited, working, ready, idle, finished.
    var attention: String
    var folder: String
    var branch: String?
    var updated: Double
    var excerpt: String
    var items: [Item]
}

// MARK: Framing

/// Messages travel as a 4-byte big-endian length followed by that many bytes. A frame over the limit closes the connection.
struct CompanionFrameReader: Sendable {
    private(set) var buffer = Data()
    private(set) var overflowed = false

    mutating func feed(_ data: Data) -> [Data] {
        guard !overflowed else { return [] }
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            if length > CompanionConstants.maxFrame { overflowed = true; buffer.removeAll(); return frames }
            guard buffer.count >= 4 + length else { break }
            frames.append(buffer.subdata(in: buffer.startIndex.advanced(by: 4)..<buffer.startIndex.advanced(by: 4 + length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }

    static func frame(_ payload: Data) -> Data? {
        guard payload.count <= CompanionConstants.maxFrame else { return nil }
        let n = payload.count
        return Data([UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]) + payload
    }
}

// MARK: Rules

/// What the Mac checks before it looks at what a request asks for.
struct RequestGuard: Sendable {
    private var seen = DeliveryLog(capacity: 200)
    private var rate = RateWindow(limit: 120, window: 60)

    /// nil when the request may go on.
    mutating func admit(_ request: CompanionRequest, now: Date) -> CompanionError? {
        if abs(now.timeIntervalSince1970 - request.sent) > CompanionConstants.freshness { return .stale }
        if case .limited = rate.admit(now: now) { return .rateLimited }
        if !seen.record(request.id) { return .replay }
        return nil
    }
}

enum CompanionPolicy {
    /// Whether an approval may be allowed from the phone. A command only when it was judged safe; edits and reads of files
    /// in the session's folder, yes; anything else (dangerous or unjudgeable commands, web, MCP tools, unknown tools) no.
    static func canAllow(tool: String, commandIsSafe: Bool?) -> Bool {
        switch tool {
        case "Bash", "bash", "shell", "command", "Shell": return commandIsSafe == true
        case "Read", "Glob", "Grep", "LS", "Edit", "MultiEdit", "Write", "NotebookEdit", "fileChange": return true
        default: return false
        }
    }

    static func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > CompanionConstants.excerptLimit else { return flat }
        return String(flat.prefix(CompanionConstants.excerptLimit)) + "…"
    }

    /// A message from the phone is capped like a draft; control characters other than newline and tab are removed.
    static func cleanMessage(_ text: String) -> String? {
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 8_000 else { return nil }
        return clean
    }
}

/// A paired device as the Mac stores it (without the key, which lives in the Keychain).
struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    /// A public identifier of the key (first 8 bytes of its SHA-256 as hex); the phone sends it so the Mac knows which key to try.
    var id: String
    var name: String
    var pairedAt: Date
    var lastSeen: Date?
    /// Where pushes go; nil until the phone allowed notifications. Environment matters: a development build has sandbox tokens.
    var pushToken: String?
    var pushProduction: Bool?

    init(id: String, name: String, pairedAt: Date, lastSeen: Date? = nil, pushToken: String? = nil, pushProduction: Bool? = nil) {
        self.id = id; self.name = name; self.pairedAt = pairedAt; self.lastSeen = lastSeen
        self.pushToken = pushToken; self.pushProduction = pushProduction
    }

    static func identifier(forKey key: Data) -> String {
        PureSHA256.hash(key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension Array where Element == SessionDigest {
    /// Sessions that wait on you (an approval or a question), for the app badge.
    var needingYou: Int { filter { !$0.items.isEmpty }.count }
}
