import SwiftUI

// Andere agenda's: elke agenda met een ICS-adres (Google Agenda, Outlook, iCloud, Fastmail, Proton, werkagenda's…).
// Het adres is geheim (iedereen die het kent kan je agenda lezen) en staat dus in de Keychain. Alleen lezen, alleen https.

@MainActor
final class CalendarFeedsConnector: CloudConnectorConfig, AgendaSource {
    let id = "icalfeeds"
    var title: String { tr("connect.feeds.title") }
    let symbol = "calendar.badge.plus"
    let accent = Color(hex: 0x7BD88F)
    let refreshInterval: TimeInterval = 600
    @Published private(set) var status = ConnectorStatus()

    static let keyAccount = "connector.icalfeeds.urls"
    static var fields: [ConnectorField] {
        [ConnectorField(account: CalendarFeedsConnector.keyAccount, label: tr("connect.feeds.field"), placeholder: "https://…/basic.ics", secret: true)]
    }
    static var helpText: String { tr("connect.feeds.help") }
    static let signupURL: URL? = nil

    private struct Feed {
        let name: String
        let calendar: ICSCalendar
    }

    /// Per adres de laatst gelezen agenda.
    private var cache: [URL: Feed] = [:]
    private var loaded = false

    var isConfigured: Bool { !urls().isEmpty }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    // MARK: Adressen

    /// Meerdere adressen mogen achter elkaar, gescheiden door een spatie, komma of regeleinde.
    private func urls() -> [URL] {
        guard let raw = CloudHelp.secret(CalendarFeedsConnector.keyAccount) else { return [] }
        let spaced = raw.replacingOccurrences(of: #"(?<=\S)(?=(?:https?|webcals?)://)"#, with: " ", options: .regularExpression)
        var seen: Set<URL> = []
        return spaced.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .compactMap { Self.normalized($0) }
            .filter { seen.insert($0).inserted }
    }

    /// webcal:// is gewoon https; onversleutelde http-adressen weigeren we.
    private static func normalized(_ text: String) -> URL? {
        var value = ConnectorField.clean(text)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("webcals://") { value = "https://" + String(value.dropFirst("webcals://".count)) }
        else if lower.hasPrefix("webcal://") { value = "https://" + String(value.dropFirst("webcal://".count)) }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    // MARK: Ophalen

    private func download(_ url: URL) async throws -> ICSCalendar {
        var request = URLRequest(url: url)
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        request.setValue("text/calendar, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401, 403, 404: throw NookError(tr("connect.feeds.rejected", code))
            case 429: throw NookError("Te veel verzoeken. Nook probeert het straks opnieuw.")
            default: throw NookError("De agenda gaf een fout (\(code)).")
            }
        }
        guard data.count <= 12_000_000 else { throw NookError(tr("connect.feeds.tooBig")) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("BEGIN:VCALENDAR") else {
            throw NookError(tr("connect.feeds.notICS"))
        }
        return ICSCalendar.parse(text)
    }

    private func feedName(_ calendar: ICSCalendar, _ url: URL) -> String {
        if let name = calendar.name, !name.isEmpty { return name }
        return url.host ?? "Agenda"
    }

    /// Haalt alle adressen op. Geeft per adres de agenda of de foutmelding.
    private func fetchAll() async -> (ok: [URL: Feed], errors: [String]) {
        var ok: [URL: Feed] = [:]
        var errors: [String] = []
        for url in urls() {
            do {
                let calendar = try await download(url)
                ok[url] = Feed(name: feedName(calendar, url), calendar: calendar)
            } catch {
                // Het adres zelf noemen we nooit: het is geheim.
                let label = cache[url]?.name ?? url.host ?? "Agenda"
                errors.append("\(label): \(CloudHelp.errorText(error, service: label))")
                if let old = cache[url] { ok[url] = old }
            }
        }
        return (ok, errors)
    }

    func refresh() async {
        guard ConnectorToggle.isOn(id), isConfigured else {
            cache = [:]
            loaded = false
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        let result = await fetchAll()
        cache = result.ok
        loaded = true
        apply(errors: result.errors)
    }

    private func upcoming(days: Int) -> [AgendaEntry] {
        let now = Date()
        let end = now.addingTimeInterval(Double(days) * 86_400)
        let start = Calendar.current.startOfDay(for: now)
        return cache.values
            .flatMap { $0.calendar.entries(from: start, to: end, label: $0.name) }
            .sorted { $0.start < $1.start }
    }

    private func apply(errors: [String]) {
        let now = Date()
        let list = upcoming(days: 7).filter { $0.end > now }
        let today = list.filter { Calendar.current.isDateInToday($0.start) }
        if cache.isEmpty, !errors.isEmpty {
            status = ConnectorStatus(state: .error(errors.joined(separator: " · ")))
            return
        }
        var detail = tr("connect.feeds.count", cache.count)
        if !errors.isEmpty { detail += " · " + errors.joined(separator: " · ") }
        status = ConnectorStatus(
            state: .ok,
            headline: today.isEmpty ? tr("connect.local.calendarEmpty") : tr("connect.local.calendarToday", today.count),
            detail: detail,
            items: list.prefix(5).map {
                ConnectorItem(id: "\($0.calendar)-\($0.start.timeIntervalSince1970)-\($0.title)", title: $0.title,
                              subtitle: NookDates.short($0.start) + " · " + $0.calendar, tone: .neutral)
            },
            updated: now
        )
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded else { return [] }
        let now = Date()
        let list = upcoming(days: 7).filter { $0.end > now }
        var lines = ["Andere agenda's (\(cache.values.map { $0.name }.sorted().joined(separator: ", "))), de komende zeven dagen:"]
        if list.isEmpty { lines.append("- geen afspraken") }
        for entry in list.prefix(25) {
            let place = entry.location.isEmpty ? "" : " | \(entry.location)"
            lines.append("- \(entry.title) | \(NookDates.iso(entry.start)) – \(NookDates.iso(entry.end)) | \(entry.calendar)\(place)")
        }
        return lines
    }

    // MARK: Beschikbaarheid

    func agendaNames() -> [String] {
        cache.values.map { "\($0.name) (ICS)" }.sorted()
    }

    func agendaEntries(from: Date, to: Date) async throws -> AgendaResult {
        guard isActive else { throw CloudHelp.notSetUp(title) }
        let result = await fetchAll()
        if result.ok.isEmpty, !result.errors.isEmpty { throw NookError(result.errors.joined(separator: " · ")) }
        cache = result.ok
        loaded = true
        apply(errors: result.errors)
        let entries = result.ok.values.flatMap { $0.calendar.entries(from: from, to: to, label: $0.name) }
        return AgendaResult(entries: entries.sorted { $0.start < $1.start }, problems: result.errors)
    }
}
