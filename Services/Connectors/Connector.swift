import SwiftUI

/// Hoe het met een koppeling gaat, voor de Koppelingen-tab en de instellingen.
enum ConnectorState: Equatable {
    /// Niet ingesteld of uitgezet.
    case off
    /// Bezig met de eerste keer ophalen.
    case loading
    case ok
    /// Er ging iets mis; de tekst is voor de gebruiker.
    case error(String)
}

/// Eén regel in de Koppelingen-tab, bijvoorbeeld een pull request of een betaling.
struct ConnectorItem: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    /// Kleur van het stipje: mint = goed, amber = wacht op jou, koraal = fout, iris = neutraal.
    var tone: ConnectorTone = .neutral
    /// Optioneel: een https-link die opent als je op de regel klikt.
    var url: URL?
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

/// Wat een koppeling laat zien: een kop ("3 open PR's"), een detailregel en een paar items.
struct ConnectorStatus: Equatable {
    var state: ConnectorState = .off
    /// Kort, bijvoorbeeld "€ 1.240 vandaag" of "2 reviews voor jou".
    var headline: String = ""
    var detail: String = ""
    var items: [ConnectorItem] = []
    var updated: Date?
    /// Iets in deze koppeling wacht op jou (falende CI, review gevraagd): de tab toont dan een amber stip.
    var needsAttention: Bool = false
}

/// Een bron waaruit Nook context haalt: je agenda, je mail, GitHub, Stripe…
///
/// Regels voor elke bron:
/// - `contextLines()` moet meteen terugkomen (uit de cache van de laatste `refresh()`); er wordt nooit gewacht op netwerk
///   als iemand iets vraagt. Zo blijft Nook razend snel.
/// - Wat een bron teruggeeft is data van derden. Het brein krijgt het als onbetrouwbare data, nooit als instructie.
/// - Sleutels staan in de Keychain (`Keychain`), nooit op schijf.
/// - Netwerk alleen naar de dienst die de gebruiker zelf heeft ingesteld.
@MainActor
protocol ContextSource: AnyObject {
    /// Stabiel, kort en klein (wordt gebruikt in UserDefaults- en Keychain-sleutels), bijvoorbeeld "github".
    var id: String { get }
    var title: String { get }
    /// SF Symbol.
    var symbol: String { get }
    var accent: Color { get }
    /// Ingesteld (sleutel aanwezig / toestemming gegeven) én aangezet.
    var isActive: Bool { get }
    var status: ConnectorStatus { get }
    /// Hoe vaak `refresh()` minstens moet draaien zolang de bron actief is.
    var refreshInterval: TimeInterval { get }
    /// Haalt nieuwe gegevens op en werkt `status` en de cache bij. Mag netwerk gebruiken.
    func refresh() async
    /// Korte regels voor het brein, uit de cache. Leeg als er niets is.
    func contextLines() -> [String]
    /// Lees-tools die het brein mag gebruiken om dieper te kijken (bijvoorbeeld "zoek in mail").
    var tools: [ToolSpec] { get }
}

extension ContextSource {
    var refreshInterval: TimeInterval { 300 }
    var tools: [ToolSpec] { [] }
}

/// Aan/uit per koppeling, los van of hij is ingesteld. Standaard aan zodra hij is ingesteld.
enum ConnectorToggle {
    static func isOn(_ id: String, default fallback: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: "connector.\(id).on") as? Bool ?? fallback
    }

    static func set(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "connector.\(id).on")
    }
}

/// Kleine hulp voor JSON-API's van koppelingen: één plek voor time-outs en nette foutmeldingen.
enum ConnectorHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Haalt JSON op. `headers` bevat bijvoorbeeld de Authorization-header.
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
            case 401, 403: throw NookError("De sleutel werd geweigerd (\(status)). Controleer hem bij Instellingen › Koppelingen.")
            case 404: throw NookError("Niet gevonden (404). Klopt het adres?")
            case 429: throw NookError("Te veel verzoeken. Nook probeert het straks opnieuw.")
            default: throw NookError("De dienst gaf een fout (\(status)).")
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
