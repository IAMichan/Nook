import Foundation

// Webhooks from the internet through the relay (apps/relay/worker/hooks.js). The Mac connects out with a token; the public
// address names only a room made from it, so whoever has the address can send but never listen. Every request still goes
// through `WebhookListener.handle`: signature, duplicates and rate are checked here. Foundation only, tested on its own.
enum WebhookRelay {
    private static let label = "nook-webhook-room"

    static func room(token: String) -> String {
        String(WebhookHex.encode(PureHMAC.sha256(key: Data(token.utf8), message: Data(label.utf8))).prefix(32))
    }

    /// The address to give a sender.
    static func publicURL(relay: String, token: String, task: UUID) -> String {
        relay + "/v1/hooks/" + room(token: token) + "/" + task.uuidString
    }

    static func listenURL(relay: String, token: String) -> URL? {
        guard var parts = URLComponents(string: relay + "/v1/hooks/" + room(token: token) + "/listen") else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        return parts.url
    }

    struct Incoming: Equatable, Sendable {
        var id: String
        var request: WebhookHTTP.Request
    }

    /// A request as the relay passes it. Header names come in lower case, as `WebhookHTTP.Request` wants them.
    static func incoming(_ text: String) -> Incoming? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["id"] as? String, let path = object["path"] as? String,
              let encoded = object["body"] as? String, let body = Data(base64Encoded: encoded),
              body.count <= WebhookHTTP.maxBodyBytes else { return nil }
        let headers = (object["headers"] as? [String: String]) ?? [:]
        return Incoming(id: id, request: WebhookHTTP.Request(
            method: "POST", path: path,
            headers: Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first }), body: body))
    }

    static func answer(id: String, status: Int, message: String) -> String {
        let object: [String: Any] = ["id": id, "status": status, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
