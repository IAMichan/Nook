import Foundation

/// What the agent's result said about a turn that did not go well.
struct FailureEvidence: Equatable, Sendable {
    var resultSubtype: String?
    var terminalReason: String?
    var apiErrorStatus: Int?
    var isError: Bool
    /// A streamed `rate_limit_event` was rejected without extra usage to fall back on.
    var rateLimitRejected: Bool
    /// Blocked windows and when each resets (nil: the CLI did not say).
    var rateLimitResets: [String: Date?]
    var messageText: String?
    var now: Date
    /// `/compact` stopped by a limit reports success, but the context was not compacted: still a failure.
    var isCompaction: Bool

    init(resultSubtype: String? = nil, terminalReason: String? = nil, apiErrorStatus: Int? = nil, isError: Bool = false,
         rateLimitRejected: Bool = false, rateLimitResets: [String: Date?] = [:], messageText: String? = nil,
         now: Date = Date(), isCompaction: Bool = false) {
        self.resultSubtype = resultSubtype
        self.terminalReason = terminalReason
        self.apiErrorStatus = apiErrorStatus
        self.isError = isError
        self.rateLimitRejected = rateLimitRejected
        self.rateLimitResets = rateLimitResets
        self.messageText = messageText
        self.now = now
        self.isCompaction = isCompaction
    }
}

enum FailureClass: Equatable, Sendable {
    case usageLimit(resetAt: Date?)
    case authentication
    /// 403: the CLI's own text is shown, it says why.
    case forbidden
    /// The user's own stop (terminal_reason aborted_*): not a failure.
    case interrupted
    case network
    case generic
}

/// Layered like ClaudeAdapterV2.ts (terminalStatusFromResult / providerFailureFromResult): the explicit terminal
/// reason first, then the API status, then streamed rate-limit events, and only then the message text.
enum FailureClassifier {
    static func classify(_ e: FailureEvidence) -> FailureClass {
        // The CLI can label an abort as success with is_error false; its terminal reason wins.
        if e.terminalReason == "aborted_tools" || e.terminalReason == "aborted_streaming" { return .interrupted }
        if e.terminalReason == "blocking_limit" { return .usageLimit(resetAt: reset(e)) }

        switch e.apiErrorStatus {
        case 429?, 529?:
            // 529 (overloaded) is retryable but has no reset; it must not look like a usage limit.
            return e.apiErrorStatus == 429 ? .usageLimit(resetAt: reset(e)) : .network
        case 401?: return .authentication
        case 403?: return .forbidden
        default: break
        }

        if e.rateLimitRejected { return .usageLimit(resetAt: latestStreamedReset(e)) }

        // Plain assistant text may mention "network"; only a failing result is read.
        guard isFailing(e), let text = e.messageText, !text.isEmpty else { return .generic }
        if let seconds = gatewayResetSeconds(text) {
            return .usageLimit(resetAt: seconds > 0 ? e.now.addingTimeInterval(seconds) : nil)
        }
        let lower = text.lowercased()
        if lower.contains("[429]") || lower.contains("rate_limit_error") { return .usageLimit(resetAt: latestStreamedReset(e)) }
        if lower.contains("authentication_failed") || lower.contains("invalid api key") || lower.contains("/login")
            || lower.contains("api error: 401") { return .authentication }
        if lower.contains("api error: 403") { return .forbidden }
        if ["econnreset", "enotfound", "etimedout", "econnrefused", "fetch failed", "socket hang up",
            "network error", "network connection", "offline"].contains(where: lower.contains) { return .network }
        return .generic
    }

    /// Whether the turn failed. An interrupt is a stop, not a failure; a limit during `/compact` is one even though
    /// the result looks like a success.
    static func isFailure(_ e: FailureEvidence) -> Bool {
        switch classify(e) {
        case .interrupted: return false
        case .usageLimit, .authentication, .forbidden, .network: return true
        case .generic: return isFailing(e)
        }
    }

    private static func isFailing(_ e: FailureEvidence) -> Bool {
        e.isError || e.isCompaction || (e.resultSubtype.map { $0 != "success" } ?? false)
    }

    private static func latestStreamedReset(_ e: FailureEvidence) -> Date? {
        UsageLimits.latestReset(e.rateLimitResets)
    }

    private static func reset(_ e: FailureEvidence) -> Date? {
        if let seconds = e.messageText.flatMap(gatewayResetSeconds), seconds > 0 { return e.now.addingTimeInterval(seconds) }
        return latestStreamedReset(e)
    }

    private static let gatewayResetPattern = try? NSRegularExpression(pattern: #"\(reset after (?:(\d+)h ?)?(?:(\d+)m ?)?(?:(\d+)s)?\)"#)

    /// "(reset after 1h2m3s)" in a gateway's 429 text.
    static func gatewayResetSeconds(_ text: String) -> TimeInterval? {
        guard let regex = gatewayResetPattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ i: Int) -> Double {
            guard let range = Range(match.range(at: i), in: text) else { return 0 }
            return Double(text[range]) ?? 0
        }
        return part(1) * 3600 + part(2) * 60 + part(3)
    }
}
