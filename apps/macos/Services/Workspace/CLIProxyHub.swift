import Foundation

/// A CLIProxyAPI hub: one server that pools the sign-ins of several accounts (Claude, Codex, Antigravity, …) behind one
/// address. Nook only reads what the hub reports about its own accounts (`GET /v0/management/auth-files`): who is in the
/// pool, whether they can take requests right now, when a cooldown ends and the rate limit headers the hub saw on its
/// last requests.
///
/// Nook never asks the hub to call a provider with an account's token (the management API's `api-call`): that would use a
/// subscription login outside the agent's own app. Limits therefore show up as soon as the hub has seen them go by.
/// Foundation only, so the parser is tested without the app (`CLIProxyHubTests`).
struct CLIProxyHub: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// What the user calls it; empty shows the host.
    var label: String
    /// The hub's address, with or without a trailing slash or `/management.html`.
    var url: String

    var name: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: url)?.host ?? url
    }

    /// The Keychain account of this hub's management key.
    var secretAccount: String { Self.secretAccount(id) }
    static func secretAccount(_ id: String) -> String { "cliproxy.hub." + id }

    // MARK: Address

    enum AddressProblem: Error, Equatable, Sendable {
        /// Not a web address.
        case invalid
        /// `http` to a machine that is not on this Mac or the local network: the management key would travel in the clear.
        case insecure
    }

    /// The hub's address as a base URL, or why it cannot be used. The management key goes to this address, so plain `http`
    /// is allowed only for this Mac and the local network.
    static func base(_ text: String) -> Result<URL, AddressProblem> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://"), !trimmed.isEmpty { trimmed = "http://" + trimmed }
        guard var parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return .failure(.invalid) }
        if scheme == "http", !isLocalHost(host) { return .failure(.insecure) }
        // The hub's control panel lives at /management.html; the API is next to it.
        var path = parts.path
        if path.lowercased().hasSuffix("/management.html") { path = String(path.dropLast("/management.html".count)) }
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path + "/"
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// `v0/management/<path>` under the hub's base address.
    static func managementURL(_ base: URL, path: String) -> URL? {
        URL(string: "v0/management/" + path, relativeTo: base)?.absoluteURL
    }

    /// This Mac or the local network: loopback, `.local` names, and the private IPv4 ranges.
    static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "::1" || name == "[::1]" || name.hasSuffix(".local") || name.hasSuffix(".localhost") { return true }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, name.split(separator: ".").count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        default: return false
        }
    }
}

/// One account in a hub's pool, as `auth-files` lists it.
struct CLIProxyAccount: Identifiable, Equatable, Sendable {
    var id: String
    /// The hub's name for the provider: "claude", "codex", "antigravity", "xai", …
    var provider: String
    var email: String?
    var label: String
    var disabled: Bool
    /// "active", "error", "pending", … as the hub reports it.
    var status: String
    var statusMessage: String?
    /// The hub holds requests back from this account for now.
    var unavailable: Bool
    /// When the hub tries this account again; nil when it is not held back.
    var retryAt: Date?
    var succeeded: Int
    var failed: Int
    /// The rate limit headers the hub saw last, as it reports them (empty before any request went through).
    var signals: [String: String]
    var signalsObservedAt: Date?

    /// The name to show: the account's email, else the hub's label.
    var name: String { email ?? label }

    /// Whether requests can go to this account now.
    func isAvailable(now: Date = Date()) -> Bool {
        if disabled { return false }
        if unavailable { return retryAt.map { $0 <= now } ?? false }
        return true
    }

    /// One window the hub saw reported: how much is used and when it resets.
    struct Window: Equatable, Sendable {
        /// "five_hour", "seven_day" or "other".
        var key: String
        var usedPercent: Double
        var resetsAt: Date?
        var duration: TimeInterval?
    }

    /// The windows the signals carry. Claude sends `anthropic-ratelimit-unified-5h-utilization` (a fraction) with a reset
    /// in epoch seconds, and the same for `7d`; Codex sends `x-codex-primary-used-percent` with the window's length and
    /// the seconds until it resets, and the same for `secondary`. Anything else is not read.
    func windows(now: Date = Date()) -> [Window] {
        func number(_ key: String) -> Double? { signals[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        var result: [Window] = []
        let base = signalsObservedAt ?? now
        for (key, token, duration) in [("five_hour", "5h", 5 * 3600.0), ("seven_day", "7d", 7 * 24 * 3600.0)] {
            guard let utilization = number("anthropic-ratelimit-unified-\(token)-utilization") else { continue }
            let reset = number("anthropic-ratelimit-unified-\(token)-reset").map { Date(timeIntervalSince1970: $0) }
            result.append(Window(key: key, usedPercent: Self.percent(utilization <= 1 ? utilization * 100 : utilization),
                                 resetsAt: reset, duration: duration))
        }
        for name in ["primary", "secondary"] {
            guard let used = number("x-codex-\(name)-used-percent") else { continue }
            let minutes = number("x-codex-\(name)-window-minutes")
            let duration = minutes.map { $0 * 60 }
            let reset = number("x-codex-\(name)-reset-after-seconds").map { base.addingTimeInterval($0) }
            let key: String
            switch duration {
            case let value? where value <= 6 * 3600: key = "five_hour"
            case let value? where value >= 6 * 24 * 3600: key = "seven_day"
            default: key = "other"
            }
            result.append(Window(key: key, usedPercent: Self.percent(used), resetsAt: reset, duration: duration))
        }
        return result
    }

    private static func percent(_ value: Double) -> Double { min(100, max(0, value)) }
}

/// `GET /v0/management/auth-files`.
enum CLIProxyReply {
    /// The accounts in the reply, nil when it is not an `auth-files` reply. Accounts of a kind this version does not know
    /// are kept; fields that are missing fall back to quiet defaults.
    static func accounts(_ data: Data) -> [CLIProxyAccount]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { return nil }
        return files.compactMap { file in
            guard let id = string(file["id"]) ?? string(file["name"]) else { return nil }
            let quota = file["quota"] as? [String: Any]
            let signals = (quota?["signals"] as? [String: Any])?.reduce(into: [String: String]()) { result, pair in
                if let text = string(pair.value) { result[pair.key.lowercased()] = text }
            } ?? [:]
            var retry = date(file["next_retry_after"])
            // A cooldown of one model is reported on its own; the account is back when the last one ends.
            let cooldowns = (file["cooldowns"] as? [[String: Any]])?.compactMap { date($0["retry_at"]) } ?? []
            if let latest = cooldowns.max() { retry = max(retry ?? latest, latest) }
            let unavailable = (file["unavailable"] as? Bool) ?? false
            return CLIProxyAccount(
                id: id,
                provider: (string(file["provider"]) ?? string(file["type"]) ?? "").lowercased(),
                email: string(file["email"]) ?? string(file["account"]).flatMap { $0.contains("@") ? $0 : nil },
                label: string(file["label"]) ?? string(file["name"]) ?? id,
                disabled: (file["disabled"] as? Bool) ?? false,
                status: string(file["status"]) ?? "active",
                statusMessage: string(file["status_message"]),
                unavailable: unavailable,
                retryAt: unavailable || !cooldowns.isEmpty ? retry : nil,
                succeeded: int(file["success"]),
                failed: int(file["failed"]),
                signals: signals,
                signalsObservedAt: date(quota?["observed_at"]))
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        guard let parsed = NookDates.isoFractional.date(from: text) ?? NookDates.isoPlain.date(from: text) else { return nil }
        // Go writes a zero time for "never".
        return parsed.timeIntervalSince1970 < 86_400 ? nil : parsed
    }
}
