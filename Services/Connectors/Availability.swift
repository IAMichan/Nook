import Foundation

// Eén blik over alle agenda's: Apple Agenda (met alles wat daarin zit, ook Google en Outlook-accounts uit macOS),
// agenda's via een ICS-adres en Cal.com. Zo kan Nook antwoorden op "ben ik 13 oktober beschikbaar?" zonder dat
// de gebruiker zelf hoeft te zeggen in welke agenda hij moet kijken.

struct AgendaEntry: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool = false
    /// False als de afspraak als "beschikbaar" staat gemarkeerd.
    var busy: Bool = true
    var location: String = ""
    /// Naam van de agenda waar het uit komt.
    var calendar: String
}

struct AgendaResult {
    var entries: [AgendaEntry]
    /// Dingen die niet lukten maar de rest niet in de weg zaten, voor de gebruiker.
    var problems: [String] = []
}

/// Een bron die afspraken kan geven voor de beschikbaarheidscheck.
@MainActor
protocol AgendaSource: ContextSource {
    /// Wat er gecontroleerd wordt, bijvoorbeeld "Werk (Google)".
    func agendaNames() -> [String]
    /// Vers opgehaalde afspraken die de periode raken.
    func agendaEntries(from: Date, to: Date) async throws -> AgendaResult
}

extension ConnectorHub {
    var agendaSources: [AgendaSource] { sources.compactMap { $0 as? AgendaSource } }

    /// Tools van de hub zelf: die kijken over alle bronnen heen.
    var hubTools: [ToolSpec] {
        [
            ToolSpec(
                name: "check_availability",
                description: "Controleert ALLE agenda's van de gebruiker tegelijk (Apple Agenda en alles wat daarin zit, agenda's via een ICS-adres zoals Google of Outlook, Cal.com) en geeft per dag wat bezet is en wanneer hij vrij is. Gebruik dit METEEN bij elke vraag als \"ben ik op 13 oktober beschikbaar?\", \"wanneer heb ik tijd?\" of \"past dinsdag 14:00?\", ook als de periode in de context staat. Geef from en to (ISO 8601); voor één hele dag volstaat from als datum (bijvoorbeeld 2027-10-13). Meld in je antwoord in welke agenda's je keek.",
                schema: [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string", "description": "Begin, ISO 8601. Alleen een datum (2027-10-13) betekent die hele dag."],
                        "to": ["type": "string", "description": "Einde, ISO 8601. Weglaten voor één hele dag. Hooguit 14 dagen na from."]
                    ],
                    "required": ["from"]
                ],
                kind: .read,
                summarize: { _ in "Alle agenda's controleren" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("De koppelingen zijn niet beschikbaar.") }
                    guard let fromText = (input["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let from = NookDates.parse(fromText) else {
                        throw NookError("from moet een datum of ISO 8601 zijn.")
                    }
                    let calendar = Calendar.current
                    var to = (input["to"] as? String).flatMap { NookDates.parse($0) }
                    if let end = to, (input["to"] as? String)?.count == 10 {
                        // "to" als alleen een datum: die dag telt nog mee.
                        to = calendar.date(byAdding: .day, value: 1, to: end)
                    }
                    let end = to ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)) ?? from.addingTimeInterval(86_400)
                    guard end > from else { throw NookError("to moet na from liggen.") }
                    return try await self.availability(from: from, to: min(end, from.addingTimeInterval(14 * 86_400)))
                }
            ),
            ToolSpec(
                name: "list_sources",
                description: "Laat zien welke bronnen Nook nu kent (agenda's, mail, diensten, eigen bronnen), welke aan staan en welke nog niet gekoppeld zijn. Gebruik dit als de gebruiker vraagt over een app of dienst waarvan je geen gegevens ziet, zodat je kunt vragen welke app hij gebruikt en kunt uitleggen hoe die te koppelen is.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in "Bronnen bekijken" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self else { throw NookError("De koppelingen zijn niet beschikbaar.") }
                    return self.sourceOverview()
                }
            )
        ]
    }

    /// Regel voor de context: in welke agenda's Nook bij een beschikbaarheidsvraag kijkt.
    var agendaCoverageLine: String? {
        let names = agendaSources.filter { $0.isActive }.flatMap { $0.agendaNames() }
        guard !names.isEmpty else { return nil }
        return "Agenda's waar check_availability in kijkt: " + names.joined(separator: "; ") + "."
    }

    func sourceOverview() -> String {
        var lines: [String] = []
        let on = sources.filter { $0.isActive }
        let off = sources.filter { !$0.isActive }
        if !on.isEmpty {
            lines.append("Aan:")
            for source in on {
                let headline = source.status.headline
                lines.append("- \(source.title)" + (headline.isEmpty ? "" : ": \(headline)"))
            }
        }
        if !off.isEmpty {
            lines.append("Nog niet gekoppeld of uit: " + off.map { $0.title }.joined(separator: ", ") + ".")
        }
        lines.append("Koppelen kan bij Instellingen › Koppelingen: een agenda via zijn ICS-adres (Google Agenda, Outlook, iCloud…) onder Andere agenda's; bijna elke andere app of dienst met een web-API onder Eigen bronnen (alleen lezen). Een app zonder API kan via een opdracht uit Opdrachten (run_shortcut).")
        lines.append("Vraag de gebruiker welke app hij bedoelt als je hem hier niet in ziet staan, en zeg wat de makkelijkste manier is om hem te koppelen.")
        return lines.joined(separator: "\n")
    }

    // MARK: Beschikbaarheid

    /// Gewone werktijden voor de vrije momenten, tenzij de gebruiker zelf een korter stuk vroeg.
    private static let dayStartHour = 8
    private static let dayEndHour = 19

    func availability(from: Date, to: Date) async throws -> String {
        let calendar = Calendar.current
        var checked: [String] = []
        var entries: [AgendaEntry] = []
        var problems: [String] = []

        for source in agendaSources where source.isActive {
            do {
                let result = try await source.agendaEntries(from: from, to: to)
                checked.append(contentsOf: source.agendaNames())
                entries.append(contentsOf: result.entries)
                problems.append(contentsOf: result.problems)
            } catch {
                problems.append("\(source.title): \(CloudHelp.errorText(error, service: source.title))")
            }
        }
        let skipped = agendaSources.filter { !$0.isActive }.map { $0.title }
        let hasFeeds = agendaSources.contains { $0.id == "icalfeeds" && $0.isActive }

        var lines: [String] = []
        lines.append("Periode: \(NookDates.long(from)) tot \(NookDates.long(to))")
        lines.append(checked.isEmpty ? "Gecontroleerd: niets (geen agenda gekoppeld of geen toegang)." : "Gecontroleerd: " + checked.joined(separator: "; ") + ".")
        if !problems.isEmpty { lines.append("Kon niet lezen: " + problems.joined(separator: "; ") + ".") }
        if !skipped.isEmpty { lines.append("Niet gecontroleerd (uit of geen toegang): " + skipped.joined(separator: ", ") + ".") }

        let wholeDays = to.timeIntervalSince(from) >= 20 * 3600
        var day = calendar.startOfDay(for: from)
        var shown = 0
        while day < to, shown < 14 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            shown += 1
            let today = entries.filter { $0.start < next && max($0.end, $0.start.addingTimeInterval(1)) > day }
            let timed = today.filter { !$0.allDay && $0.busy }.sorted { $0.start < $1.start }
            let allDay = today.filter { $0.allDay }
            let marked = today.filter { !$0.allDay && !$0.busy }

            lines.append("")
            lines.append(NookDates.day(day) + ":")
            if today.isEmpty { lines.append("- geen afspraken in de gecontroleerde agenda's") }
            for entry in timed.prefix(30) {
                let place = entry.location.isEmpty ? "" : " | \(CloudHelp.short(entry.location, 40))"
                lines.append("- bezet \(NookDates.time(max(entry.start, day)))–\(NookDates.time(min(entry.end, next))) \(CloudHelp.short(entry.title)) [\(entry.calendar)]\(place)")
            }
            for entry in allDay.prefix(10) {
                lines.append("- hele dag: \(CloudHelp.short(entry.title)) [\(entry.calendar)] (blokkeert niet vanzelf, oordeel zelf)")
            }
            for entry in marked.prefix(10) {
                lines.append("- staat als beschikbaar: \(NookDates.time(entry.start)) \(CloudHelp.short(entry.title)) [\(entry.calendar)]")
            }

            let windowStart = wholeDays
                ? max(calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: day) ?? day, from)
                : max(from, day)
            let windowEnd = wholeDays
                ? min(calendar.date(bySettingHour: Self.dayEndHour, minute: 0, second: 0, of: day) ?? next, to)
                : min(to, next)
            if windowEnd > windowStart {
                let free = Self.freeSlots(busy: timed, from: windowStart, to: windowEnd)
                let label = wholeDays ? "vrij (\(NookDates.time(windowStart))–\(NookDates.time(windowEnd)))" : "vrij"
                lines.append("- \(label): " + (free.isEmpty ? "geen" : free.map { "\(NookDates.time($0.0))–\(NookDates.time($0.1))" }.joined(separator: ", ")))
            }
            day = next
        }

        lines.append("")
        lines.append(hasFeeds
            ? "Staat er nog een agenda of app niet bij? Vraag de gebruiker welke hij nog gebruikt."
            : "Let op: dit is alles waar Nook in kan kijken. Gebruikt de gebruiker ook een andere agenda (Google Agenda, Outlook, een werkagenda) die niet in de lijst hierboven staat? Vraag dan welke, en leg uit dat hij die kan koppelen bij Instellingen › Koppelingen › Andere agenda's met het ICS-adres van die agenda.")
        return lines.joined(separator: "\n")
    }

    /// De gaten tussen afspraken binnen het venster, vanaf een kwartier.
    private static func freeSlots(busy: [AgendaEntry], from: Date, to: Date) -> [(Date, Date)] {
        var cursor = from
        var slots: [(Date, Date)] = []
        for entry in busy.sorted(by: { $0.start < $1.start }) {
            if entry.end <= cursor { continue }
            if entry.start >= to { break }
            if entry.start.timeIntervalSince(cursor) >= 15 * 60 { slots.append((cursor, entry.start)) }
            cursor = max(cursor, entry.end)
        }
        if to.timeIntervalSince(cursor) >= 15 * 60 { slots.append((cursor, to)) }
        return slots
    }
}
