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
        default: return .other
        }
    }

    /// The kind that belongs to any error thrown while talking to a service.
    static func classify(_ error: Error) -> ConnectorErrorKind {
        if let nook = error as? NookError { return nook.kind }
        if error is URLError { return .network }
        return .other
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
