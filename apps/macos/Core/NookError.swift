import Foundation

/// What kind of failure a connection ran into, so the UI can offer the right way out
/// ("Reconnect" for rejected credentials, "Try again" for a network problem).
enum ConnectorErrorKind: String, Equatable, Codable, Sendable {
    /// The credentials were rejected or have expired.
    case auth
    /// The service could not be reached.
    case network
    /// The service asked Nook to slow down.
    case rateLimited
    /// Something about the setup is wrong (address, missing field, missing permission).
    case config
    case other

    /// Reconnecting (opening the account in Settings) is the fix.
    var needsReconnect: Bool { self == .auth || self == .config }
    /// Trying again later is the fix.
    var canRetry: Bool { self == .network || self == .rateLimited || self == .other }

    /// The kind that belongs to an HTTP status.
    static func forHTTP(status: Int) -> ConnectorErrorKind {
        switch status {
        case 401, 403: return .auth
        case 404: return .config
        case 429: return .rateLimited
        // A gateway that gave up or a service that is briefly down: the next try usually works.
        case 502, 503, 504: return .network
        default: return .other
        }
    }

    /// The kind that belongs to a refused answer, headers and body included: GitHub (and others) answer a used-up rate
    /// limit with 403, which is not a rejected sign-in, so signing in again would never fix it.
    static func forHTTP(_ response: HTTPURLResponse, body: Data?) -> ConnectorErrorKind {
        isRateLimit(response, body: body) ? .rateLimited : forHTTP(status: response.statusCode)
    }

    /// A 403 or 429 that says the limit is used up: no requests left, a wait asked for, or a message naming the limit.
    static func isRateLimit(_ response: HTTPURLResponse, body: Data?) -> Bool {
        guard [403, 429].contains(response.statusCode) else { return false }
        if response.statusCode == 429 { return true }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" { return true }
        if response.value(forHTTPHeaderField: "Retry-After") != nil { return true }
        let text = body.flatMap { String(data: $0.prefix(4096), encoding: .utf8) } ?? ""
        return text.localizedCaseInsensitiveContains("rate limit")
            || text.localizedCaseInsensitiveContains("abuse detection mechanism")
    }

    /// The kind that belongs to any error thrown while talking to a service.
    static func classify(_ error: Error) -> ConnectorErrorKind {
        if let nook = error as? NookError { return nook.kind }
        if error is URLError { return .network }
        return .other
    }
}

/// Asks again when a request failed on something that passes by itself (a dropped connection, a timeout, a gateway
/// error), so a short hiccup does not show up as an error. Rejected credentials or a wrong address fail at once.
enum ConnectorRetry {
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let url = error as? URLError { return url.code != .cancelled }
        return ConnectorErrorKind.classify(error) == .network
    }

    /// Runs `body` up to `attempts` times, waiting `delay` seconds before the second try and twice as long each time after.
    static func run<T>(attempts: Int = 3, delay: TimeInterval = 1, _ body: () async throws -> T) async throws -> T {
        var wait = delay
        for _ in 1..<max(attempts, 1) {
            do {
                return try await body()
            } catch where isTransient(error) && !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                wait *= 2
            }
        }
        return try await body()
    }
}

/// Asks a brain again when one round failed on something that passes by itself: a dropped connection, a timeout, an
/// overloaded service (Anthropic's 529, a 5xx) or a rate limit. A rejected key, an unknown model or a refused request
/// fail at once, and so does a stop by the user. One hiccup then never ends an answer with an error.
enum BrainRetry {
    /// Seconds to wait before each next try: two more tries after the first.
    static let delays: [TimeInterval] = [1.5, 4]

    static func isTransient(_ error: Error) -> Bool {
        if ConnectorRetry.isTransient(error) { return true }
        return ConnectorErrorKind.classify(error) == .rateLimited
    }

    /// Runs `body`, and again after each of `delays` while it fails on something transient. `onRetry` hears each new try
    /// (1 for the second) with the error that caused it.
    static func run<T>(delays: [TimeInterval] = delays, onRetry: ((Int, Error) -> Void)? = nil,
                       _ body: () async throws -> T) async throws -> T {
        for (index, delay) in delays.enumerated() {
            do {
                return try await body()
            } catch where isTransient(error) && !Task.isCancelled {
                onRetry?(index + 1, error)
                try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            }
        }
        return try await body()
    }
}

/// An error with a message that can be shown to the user as is.
struct NookError: LocalizedError {
    let message: String
    let kind: ConnectorErrorKind
    init(_ message: String, kind: ConnectorErrorKind = .other) {
        self.message = message
        self.kind = kind
    }
    var errorDescription: String? { message }
}
