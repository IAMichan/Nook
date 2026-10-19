import Foundation

// Push notifications for the companion, as decisions and payloads only (Foundation, tested on Linux). Nook sends them
// itself: the Mac signs a request with the user's own APNs key and posts it to Apple, so no server of ours is involved.
//
// What a notification says is kept short on purpose. Apple relays it, so by default it names the agent and what is needed
// and not the session title, and never a command, file or answer.

enum PushCategory {
    static let approvalDeny = "NOOK_APPROVAL_DENY"
    static let approvalAllow = "NOOK_APPROVAL_ALLOW"
    static let question = "NOOK_QUESTION"
    static let info = "NOOK_INFO"
    static let actionAllow = "NOOK_ACTION_ALLOW"
    static let actionDeny = "NOOK_ACTION_DENY"
}

struct PushEvent: Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case approval, question, failed, finished, limited }

    var kind: Kind
    var session: String
    /// The approval or question the actions apply to.
    var item: String?
    var agent: String
    var title: String
    /// The phone may allow this approval from the notification.
    var canAllow = false
}

struct PushSettings: Codable, Equatable, Sendable {
    var enabled = false
    var kinds: Set<PushEvent.Kind> = [.approval, .question, .failed, .finished]
    /// Only while you are away from the Mac (idle or the screen locked): at the desk the Mac's own cards are enough.
    var onlyWhenAway = true
    /// Put the session title in the notification. Off by default: Apple relays the text.
    var includeTitle = false
    /// Quiet hours as hours of the day (0...23); both nil = none. Approvals and questions still come through when `quietAllowsUrgent`.
    var quietFrom: Int?
    var quietTo: Int?
    var quietAllowsUrgent = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = PushSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? base.enabled
        kinds = Set(((try? c.decode([String].self, forKey: .kinds)) ?? base.kinds.map(\.rawValue)).compactMap(PushEvent.Kind.init(rawValue:)))
        onlyWhenAway = (try? c.decode(Bool.self, forKey: .onlyWhenAway)) ?? base.onlyWhenAway
        includeTitle = (try? c.decode(Bool.self, forKey: .includeTitle)) ?? base.includeTitle
        quietFrom = (try? c.decodeIfPresent(Int.self, forKey: .quietFrom)).flatMap { $0 }.flatMap { (0...23).contains($0) ? $0 : nil }
        quietTo = (try? c.decodeIfPresent(Int.self, forKey: .quietTo)).flatMap { $0 }.flatMap { (0...23).contains($0) ? $0 : nil }
        quietAllowsUrgent = (try? c.decode(Bool.self, forKey: .quietAllowsUrgent)) ?? base.quietAllowsUrgent
    }

    private enum CodingKeys: String, CodingKey { case enabled, kinds, onlyWhenAway, includeTitle, quietFrom, quietTo, quietAllowsUrgent }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(kinds.map(\.rawValue).sorted(), forKey: .kinds)
        try c.encode(onlyWhenAway, forKey: .onlyWhenAway)
        try c.encode(includeTitle, forKey: .includeTitle)
        try c.encodeIfPresent(quietFrom, forKey: .quietFrom)
        try c.encodeIfPresent(quietTo, forKey: .quietTo)
        try c.encode(quietAllowsUrgent, forKey: .quietAllowsUrgent)
    }

    func inQuietHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let from = quietFrom, let to = quietTo, from != to else { return false }
        let hour = calendar.component(.hour, from: date)
        return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }
}

enum PushSkip: String, Equatable, Sendable { case disabled, kindOff, atTheMac, quietHours, duplicate, noDevices }

enum PushPolicy {
    static func isUrgent(_ kind: PushEvent.Kind) -> Bool { kind == .approval || kind == .question }

    /// nil = send.
    static func skipReason(_ event: PushEvent, settings: PushSettings, away: Bool, now: Date, calendar: Calendar = .current) -> PushSkip? {
        guard settings.enabled else { return .disabled }
        guard settings.kinds.contains(event.kind) else { return .kindOff }
        if settings.onlyWhenAway, !away { return .atTheMac }
        if settings.inQuietHours(now, calendar: calendar), !(settings.quietAllowsUrgent && isUrgent(event.kind)) { return .quietHours }
        return nil
    }

    /// The category of the notification, which decides its buttons: Deny (and Allow when it is low risk) for an approval.
    static func category(_ event: PushEvent) -> String {
        switch event.kind {
        case .approval: return event.canAllow ? PushCategory.approvalAllow : PushCategory.approvalDeny
        case .question: return PushCategory.question
        default: return PushCategory.info
        }
    }
}

/// Remembers what was sent, so the same approval or the same finished turn does not buzz twice.
struct PushLedger: Sendable {
    private var log = DeliveryLog(capacity: 300)

    static func key(_ event: PushEvent, turn: Int = 0) -> String {
        "\(event.kind.rawValue):\(event.session):\(event.item ?? String(turn))"
    }

    /// True when the event is new.
    mutating func admit(_ event: PushEvent, turn: Int = 0) -> Bool { log.record(Self.key(event, turn: turn)) }
}

enum APNsPayload {
    /// The JSON body of a push: `title` and `body` are already in the Mac user's language. `badge` is how many sessions need
    /// the user. Custom data sits under "nook" and carries ids only.
    static func make(_ event: PushEvent, title: String, body: String, badge: Int) -> [String: Any] {
        var nook: [String: Any] = ["session": event.session]
        if let item = event.item { nook["item"] = item }
        return [
            "aps": ["alert": ["title": title, "body": body], "sound": PushPolicy.isUrgent(event.kind) ? "default" : "default",
                    "category": PushPolicy.category(event), "thread-id": event.session, "badge": max(0, badge),
                    "interruption-level": PushPolicy.isUrgent(event.kind) ? "time-sensitive" : "active",
                    "content-available": 1] as [String: Any],
            "nook": nook
        ]
    }

    /// One notification per approval or question (so it can be replaced when it is answered elsewhere), one per session turn otherwise.
    static func collapseID(_ event: PushEvent, turn: Int = 0) -> String {
        String(PushLedger.key(event, turn: turn).prefix(64))
    }
}

/// The JWT Apple wants for token-based authentication: ES256 over `header.claims`. The signature is made by the caller
/// (CryptoKit on the Mac); the unsigned part is built here so it can be tested.
enum APNsJWT {
    /// APNs refuses tokens older than an hour and refreshes of the same token more often than every 20 minutes.
    static let lifetime: TimeInterval = 50 * 60

    static func signingInput(keyID: String, teamID: String, issuedAt: Date) -> String? {
        guard validIdentifier(keyID), validIdentifier(teamID) else { return nil }
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        return Base64URL.encode(Data(header.utf8)) + "." + Base64URL.encode(Data(claims.utf8))
    }

    /// Key and team ids are ten letters and digits.
    static func validIdentifier(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func endpoint(production: Bool, deviceToken: String) -> URL? {
        guard validToken(deviceToken) else { return nil }
        return URL(string: "https://\(production ? "api.push.apple.com" : "api.sandbox.push.apple.com")/3/device/\(deviceToken.lowercased())")
    }

    /// A device token is hex (32 bytes today, more allowed).
    static func validToken(_ text: String) -> Bool {
        text.count >= 32 && text.count <= 200 && text.allSatisfy { $0.isHexDigit }
    }

    static func tokenHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// What a response status means for the stored token.
    enum Outcome: Equatable, Sendable { case delivered, dropToken, retryLater, configuration }

    static func outcome(status: Int, reason: String?) -> Outcome {
        switch status {
        case 200: return .delivered
        case 410: return .dropToken
        case 400 where reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic": return .dropToken
        case 403: return .configuration
        case 429, 500, 503: return .retryLater
        default: return .configuration
        }
    }
}
