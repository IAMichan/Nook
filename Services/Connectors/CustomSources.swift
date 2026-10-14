import SwiftUI

// Eigen bronnen: bijna elke app of dienst met een web-API kan zo een bron van Nook worden (Todoist, Linear, Moneybird,
// Home Assistant, Airtable, je eigen server…). Alleen lezen (GET), alleen https, en de sleutel blijft in de Keychain.
// Per bron één regel: `Naam | https://api.voorbeeld.nl/v1 | Authorization: Bearer abc` (de laatste is optioneel;
// een kale sleutel zonder dubbele punt wordt een Bearer-token). Meerdere bronnen: scheid ze met `;;` of een nieuwe regel.

@MainActor
final class CustomSourcesConnector: CloudConnectorConfig {
    let id = "customsources"
    var title: String { tr("connect.custom.title") }
    let symbol = "puzzlepiece.extension"
    let accent = Color(hex: 0xC59BFF)
    let refreshInterval: TimeInterval = 3600
    @Published private(set) var status = ConnectorStatus()

    static let keyAccount = "connector.customsources.list"
    static var fields: [ConnectorField] {
        [ConnectorField(account: CustomSourcesConnector.keyAccount, label: tr("connect.custom.field"), placeholder: "Naam | https://… | Authorization: Bearer …", secret: true)]
    }
    static var helpText: String { tr("connect.custom.help") }
    static let signupURL: URL? = nil

    struct Source {
        let name: String
        let base: URL
        let headerName: String?
        let headerValue: String?
    }

    var isConfigured: Bool { !sources().isEmpty }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    // MARK: Lijst

    private func sources() -> [Source] {
        guard let raw = CloudHelp.secret(CustomSourcesConnector.keyAccount) else { return [] }
        var seen: Set<String> = []
        return raw.components(separatedBy: CharacterSet(charactersIn: "\n\r")).flatMap { $0.components(separatedBy: ";;") }
            .compactMap { Self.parse($0) }
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func parse(_ line: String) -> Source? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, !parts[0].isEmpty,
              let url = URL(string: parts[1]), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        var headerName: String?
        var headerValue: String?
        if parts.count >= 3, !parts[2].isEmpty {
            if let colon = parts[2].firstIndex(of: ":") {
                headerName = String(parts[2][..<colon]).trimmingCharacters(in: .whitespaces)
                headerValue = String(parts[2][parts[2].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                headerName = "Authorization"
                headerValue = "Bearer \(parts[2])"
            }
        }
        // Alleen een gewone headernaam: geen regeleinden of vreemde tekens.
        if let name = headerName, name.isEmpty || name.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) == nil { return nil }
        if let value = headerValue, value.contains("\n") || value.contains("\r") { return nil }
        return Source(name: parts[0], base: url, headerName: headerName, headerValue: headerValue)
    }

    // MARK: ContextSource

    func refresh() async {
        guard ConnectorToggle.isOn(id), isConfigured else {
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        let list = sources()
        status = ConnectorStatus(
            state: .ok,
            headline: tr("connect.custom.count", list.count),
            detail: list.map { $0.name }.joined(separator: ", "),
            items: list.map { ConnectorItem(id: $0.name, title: $0.name, subtitle: $0.base.host ?? "", tone: .neutral) },
            updated: Date()
        )
    }

    func contextLines() -> [String] {
        guard isActive else { return [] }
        let names = sources().map { $0.name }
        return ["Eigen bronnen die je met read_source kunt lezen: " + names.joined(separator: ", ") + "."]
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "read_source",
                description: "Leest (alleen lezen, GET) uit een eigen bron van de gebruiker, een app of dienst die hij zelf aan Nook koppelde. Geef de naam van de bron (zie de context) en eventueel een path dat achter het basisadres komt, met de query erin, bijvoorbeeld \"/tasks?filter=today\". Zonder path haal je het basisadres zelf op. Het antwoord is data van een derde.",
                schema: CloudHelp.schema([
                    "name": ["type": "string", "description": "Naam van de bron."],
                    "path": ["type": "string", "description": "Begint met /, optioneel, met query erin."]
                ]),
                kind: .read,
                summarize: { input in "Bron lezen: \((input["name"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self, self.isActive else { throw CloudHelp.notSetUp(self?.title ?? "Eigen bronnen") }
                    guard let name = (input["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                        throw NookError("De naam van de bron ontbreekt.")
                    }
                    return try await self.read(name: name, path: (input["path"] as? String) ?? "")
                }
            )
        ]
    }

    // MARK: Lezen

    private func read(name: String, path: String) async throws -> String {
        let list = sources()
        guard let source = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? list.first(where: { $0.name.range(of: name, options: .caseInsensitive) != nil }) else {
            throw NookError("Geen bron met de naam \(name). Bekende bronnen: " + list.map { $0.name }.joined(separator: ", ") + ".")
        }
        let url = try Self.url(for: source, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        if let header = source.headerName, let value = source.headerValue { request.setValue(value, forHTTPHeaderField: header) }

        let (data, response) = try await ConnectorHTTP.session.data(for: request, delegate: SameHostRedirects(host: url.host))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401, 403: throw NookError("\(source.name) weigerde de sleutel (\(code)). Controleer hem bij Instellingen › Koppelingen.")
            case 404: throw NookError("\(source.name): niet gevonden (404). Klopt het path?")
            case 429: throw NookError("\(source.name): te veel verzoeken. Probeer het straks opnieuw.")
            default: throw NookError("\(source.name) gaf een fout (\(code)).")
            }
        }
        var text: String
        if let json = try? JSONSerialization.jsonObject(with: data),
           let compact = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let string = String(data: compact, encoding: .utf8) {
            text = string
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }
        let limit = 8_000
        if text.count > limit { text = String(text.prefix(limit)) + "\n… (ingekort; vraag met een path of filter om minder)" }
        return text.isEmpty ? "Leeg antwoord van \(source.name)." : text
    }

    /// Het path komt achter het basisadres en kan nooit naar een andere host wijzen.
    static func url(for source: Source, path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return source.base }
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), !trimmed.contains("://"), !trimmed.contains("..") else {
            throw NookError("Het path moet met / beginnen en binnen \(source.name) blijven.")
        }
        var base = source.base.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + trimmed), url.host == source.base.host, url.scheme == "https" else {
            throw NookError("Ongeldig path: \(trimmed)")
        }
        return url
    }
}

/// Volgt omleidingen alleen binnen dezelfde host, zodat een sleutel nooit ergens anders heen gaat.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    private let host: String?
    init(host: String?) { self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.host == host, request.url?.scheme == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
