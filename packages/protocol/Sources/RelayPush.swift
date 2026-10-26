import Foundation

// Push through the relay (docs/COMPANION.md, "Push through Nook's relay"): for a Mac without an Apple developer account
// of its own. The Mac seals what a notification says with a key derived from the phone's pairing key and posts it with
// the device token to the relay's /v1/push (apps/relay/worker/push.js); the relay signs an APNs request with Nook's key
// and passes the blob on. Apple and the relay only see "Nook needs you"; the phone's Notification Service Extension opens
// the blob and shows the real text. Foundation only (sealing itself is in RelayPushSeal.swift, with CryptoKit).

/// What a notification says, sealed for the phone.
struct RelayPushContent: Codable, Equatable, Sendable {
    var title: String
    var body: String
    /// The notification's category (`PushCategory`): its buttons.
    var category: String
    /// Groups a session's notifications.
    var thread: String
    var session: String
    var item: String?
    var badge: Int

    /// Longest title and text sent: the sealed blob must stay well inside Apple's 4 KB.
    static let maxTitle = 120
    static let maxBody = 240

    init(title: String, body: String, category: String, thread: String, session: String, item: String?, badge: Int) {
        self.title = String(title.prefix(Self.maxTitle))
        self.body = String(body.prefix(Self.maxBody))
        self.category = category
        self.thread = String(thread.prefix(64))
        self.session = session
        self.item = item
        self.badge = max(0, badge)
    }

    /// The custom data the app reads on a tap or a button, as a direct push carries it under "nook".
    var userInfo: [String: Any] {
        var nook: [String: Any] = ["session": session]
        if let item { nook["item"] = item }
        return ["nook": nook]
    }
}

/// The body the Mac posts to the relay's /v1/push.
struct RelayPushRequest: Codable, Equatable, Sendable {
    /// A CompanionSeal envelope: the claimed device id and the sealed bytes.
    struct Sealed: Codable, Equatable, Sendable {
        var d: String
        var s: String
    }

    /// The phone's room (`CompanionRelay.room(forKey:)`): the relay limits pushes per room.
    var room: String
    var token: String
    var production: Bool
    var sealed: Sealed
    /// Opaque (`RelayPush.collapseID`), so neither the relay nor Apple learns session ids.
    var collapse: String?
    var urgent: Bool
}

enum RelayPush {
    /// The key a push is sealed with: derived from the pairing key, so the extension (which must read it while the
    /// phone is locked) holds this one and never the pairing key itself, and a push can never pass as a reply.
    static func pushKey(pairingKey: Data) -> Data {
        PureHMAC.sha256(key: pairingKey, message: Data("nook-companion-push-v1".utf8))
    }

    /// The collapse id Apple sees: a keyed hash of the real one (`APNsPayload.collapseID`).
    static func collapseID(_ key: String, pushKey: Data) -> String {
        WebhookHex.encode(PureHMAC.sha256(key: pushKey, message: Data(key.utf8)).prefix(16))
    }

    /// `https://relay/v1/push`, or nil for an address that is not a relay.
    static func endpoint(relay: String) -> URL? {
        guard let base = CompanionRelay.normalize(relay), var parts = URLComponents(string: base) else { return nil }
        parts.path = "/v1/push"
        return parts.url
    }

    /// The request for one phone, around an envelope `CompanionSeal` made. Nil when something does not fit.
    static func request(envelope: Data, room: String, token: String, production: Bool, collapse: String?, urgent: Bool) -> RelayPushRequest? {
        guard CompanionRelay.isRoom(room), APNsJWT.validToken(token),
              let sealed = try? JSONDecoder().decode(RelayPushRequest.Sealed.self, from: envelope) else { return nil }
        return RelayPushRequest(room: room, token: token.lowercased(), production: production, sealed: sealed,
                                collapse: collapse, urgent: urgent)
    }

    /// What the relay's answer means for the token, as for a direct push. `reason` is Apple's, or the relay's own.
    static func outcome(status: Int, body: Data) -> (outcome: APNsJWT.Outcome, apns: Int, reason: String?) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch status {
        case 200:
            let apns = object?["apns"] as? Int ?? 0
            let reason = object?["reason"] as? String
            return (APNsJWT.outcome(status: apns, reason: reason), apns, reason)
        case 429, 502, 503: return (.retryLater, 0, object?["error"] as? String)
        default: return (.configuration, 0, object?["error"] as? String ?? "HTTP \(status)")
        }
    }

    /// The envelope as the phone receives it under "nook-sealed", back into bytes `CompanionSeal.open` reads.
    static func envelope(fromUserInfo value: Any?) -> Data? {
        guard let dictionary = value as? [String: Any], let d = dictionary["d"] as? String, let s = dictionary["s"] as? String
        else { return nil }
        return try? JSONEncoder().encode(RelayPushRequest.Sealed(d: d, s: s))
    }
}
