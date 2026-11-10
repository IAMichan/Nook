import Foundation

// The relay's side of the address for Nook in another app (apps/relay/worker/mcp.js): the Mac's token makes a room name, so
// whoever has the address can call Nook but never listen on it. Foundation only, tested on its own.
enum RemoteMCPTunnel {
    private static let label = "nook-mcp-room"

    static func room(token: String) -> String {
        String(WebhookHex.encode(PureHMAC.sha256(key: Data(token.utf8), message: Data(label.utf8))).prefix(32))
    }

    static func listenURL(relay: String, token: String) -> URL? {
        guard var parts = URLComponents(string: relay + "/v1/mcp/" + room(token: token) + "/listen") else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        return parts.url
    }
}
