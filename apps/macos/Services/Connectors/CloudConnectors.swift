import SwiftUI
import os

// Integrations with online services: GitHub, Vercel, Stripe, Notion, Cal.com, n8n, and Resend.
// Connectors are read-only, except GitHub: Nook can review and merge pull requests there, always subject to your approval.
// Keys are stored in the Keychain under "connector.<id>.<field>".

// MARK: - Settings Fields

/// A single input field for a connector in settings (token, address…). Value is saved in the Keychain under `account`.
struct ConnectorField {
    let account: String
    let label: String
    let placeholder: String
    let secret: Bool

    /// Pasting often introduces extraneous spaces, newlines, or quotes. A line break or an invisible character (a
    /// zero-width space) inside a token makes URLSession drop the whole Authorization header without a word, so the
    /// request goes out signed out: those never belong in a one-line field.
    static func clean(_ raw: String) -> String {
        let invisible = CharacterSet.controlCharacters.union(.newlines)
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !invisible.contains($0) }))
        return visible.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
    }
}

/// What online connector settings require: fields, instructions, and signup URL.
@MainActor
protocol CloudConnectorConfig: ContextSource, ObservableObject {
    static var fields: [ConnectorField] { get }
    static var helpText: String { get }
    static var signupURL: URL? { get }
    /// All required keys are present in the Keychain (regardless of enabled toggle).
    var isConfigured: Bool { get }
    var configFields: [ConnectorField] { get }
    var helpText: String { get }
    var signupURL: URL? { get }
}

extension CloudConnectorConfig {
    var configFields: [ConnectorField] { Self.fields }
    var helpText: String { Self.helpText }
    var signupURL: URL? { Self.signupURL }
}

/// A connector that reads a service with keys you paste (Vercel, Stripe, Notion, Cal.com, n8n, Resend). They share how
/// they refresh: nothing while switched off or not set up, a loading state only before the first answer, and a failure
/// recorded for the "Reconnect" / "Try again" action (`CloudHelp.fail`). Each one only says how to read its service.
@MainActor
protocol TokenCloudConnector: CloudConnectorConfig {
    /// The Keychain accounts it needs, all of them: a token or key, or n8n's address and key.
    static var secretAccounts: [String] { get }
    var status: ConnectorStatus { get set }
    /// Reads the service with the secrets (in `secretAccounts` order) and shows what came back; throws when that failed,
    /// leaving what it showed before.
    func fetchSnapshot(secrets: [String]) async throws
    /// Forgets what it showed: switched off, or no longer set up.
    func clearSnapshot()
}

extension TokenCloudConnector {
    var isConfigured: Bool { Self.secretAccounts.allSatisfy { CloudHelp.secret($0) != nil } }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        // The toggle first: a connector switched off does not read the Keychain.
        let secrets = ConnectorToggle.isOn(id) ? Self.secretAccounts.compactMap { CloudHelp.secret($0) } : []
        guard !secrets.isEmpty, secrets.count == Self.secretAccounts.count else {
            clearSnapshot()
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            try await fetchSnapshot(secrets: secrets)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }
}

enum CloudConnectors {
    /// Single instance of each cloud connector, in settings display order.
    @MainActor
    static func makeAll() -> [ContextSource] {
        [
            GitHubConnector(),
            VercelConnector(),
            StripeConnector(),
            NotionConnector(),
            CalcomConnector(),
            N8nConnector(),
            ResendConnector(),
            CalendarFeedsConnector(),
            CustomSourcesConnector()
        ]
    }
}

// MARK: - Helpers

enum CloudHelp {
    /// A sanitized value from the Keychain, or nil if empty.
    static func secret(_ account: String) -> String? {
        guard let value = Keychain.read(account) else { return nil }
        let cleaned = ConnectorField.clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw NookError("Invalid address: \(string)") }
        return url
    }

    static func url(_ base: String, _ path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: base + path) else { throw NookError("Invalid address: \(base)") }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw NookError("Invalid address: \(base)") }
        return url
    }

    /// Fetches JSON, returning nil on any error; used for optional metadata.
    static func optionalObject(_ url: URL?, headers: [String: String]) async -> [String: Any]? {
        guard let url = url else { return nil }
        guard let raw = try? await ConnectorHTTP.json(url, headers: headers) else { return nil }
        return raw as? [String: Any]
    }

    static func object(_ value: Any?) -> [String: Any] {
        (value as? [String: Any]) ?? [:]
    }

    static func list(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]]) ?? []
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// IDs can be either strings or numbers.
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return NookDates.parse(text)
    }

    /// Only HTTPS URLs become clickable.
    static func link(_ string: String?) -> URL? {
        guard let string = string, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Records a failed refresh: the text for the user and the kind of failure for the "Reconnect" / "Try again" action.
    static func fail(_ status: inout ConnectorStatus, _ error: Error, service: String) {
        status.state = .error(errorText(error, service: service))
        status.errorKind = ConnectorErrorKind.classify(error)
    }

    static func errorText(_ error: Error, service: String) -> String {
        if let nook = error as? NookError { return nook.message }
        if error is URLError { return "No connection to \(service). Nook will try again later." }
        return "\(service) returned an unexpected response."
    }

    static func short(_ text: String, _ max: Int = 60) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TextKit.clip(flat, to: max)
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// Zero-decimal currencies in Stripe.
    static let zeroDecimal: Set<String> = [
        "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"
    ]

    /// Amount in smallest unit (cents) as "€ 1,240.50".
    static func money(_ minor: Int, currency: String) -> String {
        let code = currency.lowercased()
        let amount = zeroDecimal.contains(code) ? Double(minor) : Double(minor) / 100
        let formatter = NookDates.cached("money|\(code)") { () -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = Locale(identifier: "nl_NL")
            formatter.currencyCode = code.uppercased()
            return formatter
        }
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(code.uppercased())"
    }

    /// JSON schema for a read tool.
    static func schema(_ properties: [String: [String: Any]] = [:]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": [String]()]
    }

    static func notSetUp(_ service: String) -> NookError {
        NookError("\(service) is not configured yet or is disabled (Settings › Connectors).")
    }
}
