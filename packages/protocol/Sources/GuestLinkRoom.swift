import Foundation

/// A guest link's room and address, portable (no CryptoKit).
enum GuestLinkRoom {
    private static let label = "nook-guest-room-v1"

    /// The relay room: the first 16 bytes of HMAC-SHA256(key, label), as 32 hex characters.
    static func room(key: Data) -> String {
        WebhookHex.encode(PureHMAC.sha256(key: key, message: Data(label.utf8)).prefix(16))
    }

    /// `https://relay/v1/guest#<key, base64url without padding>`: the key stays in the fragment.
    static func url(relay: String, key: Data) -> String? {
        guard let base = CompanionRelay.normalize(relay) else { return nil }
        return base + "/v1/guest#" + base64url(key)
    }

    /// The key in a link's fragment; nil when it is not one.
    static func key(fromLink link: String) -> Data? {
        guard let fragment = link.split(separator: "#", maxSplits: 1).dropFirst().first else { return nil }
        var text = fragment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let key = Data(base64Encoded: text), key.count == 32 else { return nil }
        return key
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
