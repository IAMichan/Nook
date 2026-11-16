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
    /// The API refused the agent's version for this model (`AgentVersionRejection`): an update, or a custom endpoint
    /// that rewrote the version.
    case versionRejected(reported: String?, required: String?)
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

        if e.rateLimitRejected { return .usageLimit(resetAt: latestStreamedReset(e) ?? textReset(e)) }

        // Plain assistant text may mention "network"; only a failing result is read.
        guard isFailing(e), let text = e.messageText, !text.isEmpty else { return .generic }
        if let seconds = gatewayResetSeconds(text) {
            return .usageLimit(resetAt: seconds > 0 ? e.now.addingTimeInterval(seconds) : nil)
        }
        if let rejection = AgentVersionRejection.parse(text) {
            return .versionRejected(reported: rejection.reported, required: rejection.required)
        }
        let lower = text.lowercased()
        if lower.contains("[429]") || lower.contains("rate_limit_error") || saysUsageLimit(lower) {
            return .usageLimit(resetAt: latestStreamedReset(e) ?? textReset(e))
        }
        if saysSignIn(lower) { return .authentication }
        if lower.contains("api error: 403") { return .forbidden }
        if ["econnreset", "enotfound", "etimedout", "econnrefused", "fetch failed", "socket hang up",
            "network error", "network connection", "offline"].contains(where: lower.contains) { return .network }
        return .generic
    }

    /// How the other agents say a limit stopped them: Gemini's `RESOURCE_EXHAUSTED` and quota errors, Codex's "usage
    /// limit", an HTTP 429 in any wording. Lowercased text; a bare number only as a status ("429 Too Many Requests",
    /// "status 429"), never inside another number.
    static func saysUsageLimit(_ lower: String) -> Bool {
        let phrases = ["resource_exhausted", "resource exhausted", "quota exceeded", "exceeded your current quota",
                       "usage limit", "rate limit exceeded", "rate limited", "too many requests", "hit your limit"]
        if phrases.contains(where: lower.contains) { return true }
        return lower.range(of: #"(^|[^0-9.])429([^0-9]|$)"#, options: .regularExpression) != nil
    }

    /// What agents say when their login no longer works, lowercased: Claude Code, Codex, Gemini CLI, the ACP agents
    /// ("Authentication required", -32000) and the rest. Kept narrow: a word like "token" alone also appears in
    /// context-window errors. The one list behind `.authentication`, `AgentSignInFailure` and `AgentErrorText`.
    static let signInPhrases = [
        "failed to authenticate", "authentication failed", "authentication_failed", "authentication_error",
        "authentication required", "requires authentication", "please authenticate", "auth required", "auth_required",
        "not authenticated", "not logged in", "not signed in", "please log in", "please login", "please sign in",
        "/login", "login required", "log in again", "sign in again", "oauth session expired", "oauth token",
        "token has expired", "token expired", "refresh token", "invalid_grant", "invalid api key", "invalid x-api-key",
        "api error: 401", "unauthorized", "unauthenticated", "credentials have expired", "no credentials",
    ]

    /// Whether lowercased text says the agent needs you to sign in again.
    static func saysSignIn(_ lower: String) -> Bool {
        signInPhrases.contains(where: lower.contains)
    }

    /// What a session from a terminal shows when its agent's hook says the turn failed (`StopFailure`): a usage limit
    /// and when it resets, or that the login ran out, the same way a session Nook runs says it; else the agent's own
    /// words. For every agent whose hook passes its error.
    static func hookFailure(_ error: String, now: Date = Date()) -> (kind: FailureClass, line: String) {
        let kind = classify(FailureEvidence(isError: true, messageText: error, now: now))
        switch kind {
        case .usageLimit(let resetAt):
            return (kind, resetAt.map { tr("agents.notice.limitUntil", $0.formatted(date: .omitted, time: .shortened)) }
                ?? tr("agents.notice.limit"))
        case .authentication:
            return (kind, tr("agents.notice.signIn"))
        case .interrupted, .forbidden, .network, .versionRejected, .generic:
            return (kind, error)
        }
    }

    /// Whether the turn failed. An interrupt is a stop, not a failure; a limit during `/compact` is one even though
    /// the result looks like a success.
    static func isFailure(_ e: FailureEvidence) -> Bool {
        switch classify(e) {
        case .interrupted: return false
        case .usageLimit, .authentication, .forbidden, .network, .versionRejected: return true
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
        return latestStreamedReset(e) ?? textReset(e)
    }

    /// The reset the message itself names, when nothing streamed one ("resets 3pm", "|1736010000", "retry in 41s").
    private static func textReset(_ e: FailureEvidence) -> Date? {
        e.messageText.flatMap { UsageLimits.textReset($0, now: e.now) }
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
