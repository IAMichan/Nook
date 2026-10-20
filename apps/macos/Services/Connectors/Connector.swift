import SwiftUI

/// Status of an integration, for the Integrations tab and settings.
enum ConnectorState: Equatable {
    /// Not configured or disabled.
    case off
    /// Fetching initial data.
    case loading
    case ok
    /// An error occurred; the text is presented to the user.
    case error(String)
}

/// A single item in the Integrations tab, e.g. a pull request or payment.
struct ConnectorItem: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    /// Dot color: mint = good, amber = awaiting user, coral = error, iris = neutral.
    var tone: ConnectorTone = .neutral
    /// Optional https link opened on click.
    var url: URL?
    /// Domain for the service icon (optional).
    var iconDomain: String?
}

enum ConnectorTone: Equatable {
    case good, attention, bad, neutral

    var color: Color {
        switch self {
        case .good: return NookTheme.mint
        case .attention: return NookTheme.amber
        case .bad: return NookTheme.coral
        case .neutral: return NookTheme.iris
        }
    }
}

/// What an integration displays: a headline ("3 open PRs"), detail text, and items.
struct ConnectorStatus: Equatable {
    var state: ConnectorState = .off
    /// Short summary, e.g. "$1,240 today" or "2 reviews for you".
    var headline: String = ""
    var detail: String = ""
    var items: [ConnectorItem] = []
    var updated: Date?
    /// Something requires attention (failing CI, requested review): shows amber badge in tab.
    var needsAttention: Bool = false
    /// Why the last refresh failed (only meaningful while `state` is `.error`).
    var errorKind: ConnectorErrorKind?
}

/// A source supplying context to Nook: calendar, mail, GitHub, Stripe, etc.
///
/// Invariants for each source:
/// - `contextLines()` must return immediately (from the cache of the latest `refresh()`); never block on network
///   during user queries. This keeps Nook fast.
/// - Data returned by sources is third-party data provided to the brain as untrusted context, never instructions.
/// - Keys are stored in Keychain (`Keychain`), never plaintext on disk.
/// - Network calls are restricted to the endpoint configured by the user.
@MainActor
protocol ContextSource: AnyObject {
    /// Stable lowercase identifier used in UserDefaults and Keychain keys, e.g. "github".
    var id: String { get }
    var title: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    /// Optional: domain of the service for brand icon instead of system symbol (defaults to `SourceBrand`).
    var iconDomain: String? { get }
    var accent: Color { get }
    /// Configured (credentials present / permission granted) and enabled.
    var isActive: Bool { get }
    var status: ConnectorStatus { get }
    /// Minimum interval between `refresh()` executions while active.
    var refreshInterval: TimeInterval { get }
    /// Fetches fresh data and updates `status` and cache. May perform network requests.
    func refresh() async
    /// Short context lines for the brain from cache. Empty if nothing to report.
    func contextLines() -> [String]
    /// Read tools available to the brain for deeper lookups (e.g. search mail).
    var tools: [ToolSpec] { get }
    /// The model may use the read tools even when the source is not active right now (Mail still closed: the tool opens it).
    var canLookUp: Bool { get }
}

extension ContextSource {
    var canLookUp: Bool { isActive }
    var iconDomain: String? { SourceBrand.domain(for: id) }
    var refreshInterval: TimeInterval { 300 }
    var tools: [ToolSpec] { [] }
}

/// Toggle state per integration, separate from configuration. Enabled by default once configured.
enum ConnectorToggle {
    static func isOn(_ id: String, default fallback: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: "connector.\(id).on") as? Bool ?? fallback
    }

    static func set(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "connector.\(id).on")
    }
}

/// Helper for JSON APIs of integrations: centralized timeouts and error messages.
enum ConnectorHTTP {
    static let session: URLSession = {
        let configuration = uncached()
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// For requests GitHub can take a while to answer (a search over many pull requests with their checks).
    static let patientSession: URLSession = {
        let configuration = uncached()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Ephemeral still keeps an in-memory cache, and GitHub marks its answers `max-age=60`: a pull request merged a
    /// moment ago then read back as open for up to a minute. Every refresh here wants what the service says now.
    private static func uncached() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Fetches JSON. `headers` typically includes Authorization header.
    static func json(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            switch status {
            case 401, 403: throw NookError("The credentials were rejected (\(status)). Check them in Settings › Integrations.", kind: .auth)
            case 404: throw NookError("Not found (404). Is the URL correct?", kind: .config)
            case 429: throw NookError("Too many requests. Nook will retry shortly.", kind: .rateLimited)
            default: throw NookError("The service returned an error (\(status)).", kind: ConnectorErrorKind.forHTTP(status: status))
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
