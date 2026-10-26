import Foundation

// The relay: a way to reach the Mac from anywhere (a café, a train) without Tailscale and without opening a port on the
// router (docs/COMPANION.md, "Away from home"). The Mac keeps one outgoing WebSocket to a relay the user deploys
// (apps/relay, a Cloudflare Worker); a phone that cannot reach the Mac directly opens its own WebSocket to the same
// relay, and the relay passes bytes between them. Everything that passes is already sealed with the pairing key, so the
// relay reads nothing and can forge nothing: it only sees which room talks and how much.

enum CompanionRelay {
    /// The room of one paired phone: derived from its pairing key, so only the Mac and that phone know it, and nothing
    /// about the key can be learned from it.
    static func room(forKey key: Data) -> String {
        WebhookHex.encode(PureHMAC.sha256(key: key, message: Data("nook-companion-relay-room-v1".utf8)).prefix(16))
    }

    static func isRoom(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A relay address as the user typed it, as `https://host[:port]`; nil unless it is HTTPS (the relay is reached
    /// over the internet) without credentials. Plain HTTP is only accepted for this machine (a relay in development).
    static func normalize(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
              PairingLink.validHost(host) else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        var result = URLComponents()
        result.scheme = scheme
        result.host = host
        result.port = parts.port
        return result.string
    }

    /// The WebSocket a side opens: `wss://host/v1/rooms/<room>?role=mac|phone`.
    static func socketURL(relay: String, room: String, role: Role) -> URL? {
        guard let base = normalize(relay), var parts = URLComponents(string: base), isRoom(room) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/v1/rooms/" + room
        parts.queryItems = [URLQueryItem(name: "role", value: role.rawValue)]
        return parts.url
    }

    enum Role: String, Sendable { case mac, phone }
}

/// How the relay and the Mac share the Mac's one WebSocket among the phone's connections: every message is
/// `[kind: 1 byte][connection: 4 bytes, big-endian][payload]`. A phone's own WebSocket carries the payload alone.
/// The relay (apps/relay/src/mux.js) speaks the same.
enum RelayMux {
    enum Kind: UInt8, Sendable {
        /// A phone connected (relay to Mac).
        case open = 1
        /// Bytes for or from that connection.
        case data = 2
        /// The connection ended (either way).
        case close = 3
    }

    struct Message: Equatable, Sendable {
        var kind: Kind
        var connection: UInt32
        var payload: Data
    }

    static func encode(_ kind: Kind, connection: UInt32, payload: Data = Data()) -> Data {
        var data = Data([kind.rawValue, UInt8(connection >> 24 & 0xff), UInt8(connection >> 16 & 0xff),
                         UInt8(connection >> 8 & 0xff), UInt8(connection & 0xff)])
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> Message? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, let kind = Kind(rawValue: bytes[0]) else { return nil }
        let connection = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        return Message(kind: kind, connection: connection, payload: Data(bytes[5...]))
    }
}
