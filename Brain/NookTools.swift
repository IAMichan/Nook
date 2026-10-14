import Foundation
import AppKit

/// Eén ding dat Nook kan. Lees-tools draaien meteen tijdens het nadenken; actie-tools worden eerst als plan aan jou getoond.
struct ToolSpec {
    enum Kind { case read, action }

    let name: String
    let description: String
    let schema: [String: Any]
    let kind: Kind
    /// Eén regel voor in het plan, bijvoorbeeld "Agenda: Koffie met Lisa · vr 16 okt 14:00".
    let summarize: ([String: Any]) -> String
    /// Korte aanduiding achter de regel (leeg = niets bijzonders).
    let tag: ([String: Any]) -> (String, StepTone)
    let run: @MainActor ([String: Any]) async throws -> String
}

@MainActor
final class NookTools {
    private let calendar: CalendarService
    private let store: NookStore
    private let screen: ScreenReader
    private let onLoopsChanged: () -> Void

    private(set) var specs: [ToolSpec] = []

    init(calendar: CalendarService, store: NookStore, screen: ScreenReader, onLoopsChanged: @escaping () -> Void) {
        self.calendar = calendar
        self.store = store
        self.screen = screen
        self.onLoopsChanged = onLoopsChanged
        self.specs = buildSpecs()
    }

    func spec(named name: String) -> ToolSpec? {
        specs.first { $0.name == name }
    }

    // MARK: Schema-hulpjes

    private func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private func object(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private func text(_ input: [String: Any], _ key: String) -> String? {
        let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private func date(_ input: [String: Any], _ key: String) -> Date? {
        text(input, key).flatMap { NookDates.parse($0) }
    }

    // MARK: De tools

    private func buildSpecs() -> [ToolSpec] {
        [
            ToolSpec(
                name: "list_events",
                description: "Leest afspraken uit de agenda van de gebruiker tussen twee momenten. Gebruik dit om vrije momenten te vinden of conflicten te checken.",
                schema: object([
                    "from": string("Begin, ISO 8601 met tijdzone."),
                    "to": string("Einde, ISO 8601 met tijdzone.")
                ], required: ["from", "to"]),
                kind: .read,
                summarize: { _ in "Agenda lezen" },
                tag: { _ in ("", .neutral) },
                run: { [calendar = self.calendar] input in
                    guard let from = NookTools.parseDate(input, "from"), let to = NookTools.parseDate(input, "to") else {
                        throw NookError("from en to moeten ISO 8601 zijn.")
                    }
                    await calendar.requestEvents()
                    let events = calendar.events(from: from, to: to)
                    if events.isEmpty { return "Geen afspraken in deze periode (of geen toegang tot de agenda)." }
                    return events.prefix(40).map {
                        "\($0.title) | \(NookDates.iso($0.start)) – \(NookDates.iso($0.end))" + ($0.location.isEmpty ? "" : " | \($0.location)")
                    }.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "read_screen",
                description: "Leest de tekst van het voorste venster op de Mac van de gebruiker (OCR, lokaal). Gebruik dit METEEN, zonder eerst te vragen wat er staat, zodra de gebruiker verwijst naar iets dat hij ziet of net las: 'hier', 'dit', 'daar', 'die mail', 'maak er een afspraak voor', 'zet dat in mijn agenda'. Haal daarna titel, datum, tijd, plaats en deelnemers uit die tekst.",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Scherm lezen" },
                tag: { _ in ("", .neutral) },
                run: { [screen = self.screen] _ in
                    let snapshot = try await screen.capture()
                    let title = snapshot.windowTitle.isEmpty ? "" : " — \(snapshot.windowTitle)"
                    return "Voorste venster: \(snapshot.appName)\(title)\n\(snapshot.text)"
                }
            ),
            ToolSpec(
                name: "list_open_loops",
                description: "Geeft de open punten die Nook voor de gebruiker bijhoudt (dingen die nog gedaan moeten worden).",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Open punten lezen" },
                tag: { _ in ("", .neutral) },
                run: { [store = self.store] _ in
                    let loops = store.openLoops()
                    if loops.isEmpty { return "Geen open punten." }
                    return loops.map { "- \($0.title) (sinds \(NookDates.short($0.created)))" }.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "create_event",
                description: "Maakt een afspraak in de agenda. Alleen aanroepen als titel en begintijd duidelijk zijn.",
                schema: object([
                    "title": string("Titel van de afspraak."),
                    "start": string("Begin, ISO 8601 met tijdzone."),
                    "end": string("Einde, ISO 8601 met tijdzone. Standaard een uur na het begin."),
                    "location": string("Plaats, optioneel."),
                    "notes": string("Notities, optioneel.")
                ], required: ["title", "start"]),
                kind: .action,
                summarize: { input in
                    let title = (input["title"] as? String) ?? "Afspraak"
                    let start = NookTools.parseDate(input, "start").map(NookDates.short) ?? "?"
                    return "Agenda: \(title) · \(start)"
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let title = self.text(input, "title"), let start = self.date(input, "start") else {
                        throw NookError("Titel of begintijd ontbreekt.")
                    }
                    let end = self.date(input, "end") ?? start.addingTimeInterval(3600)
                    try await self.calendar.createEvent(
                        title: title, start: start, end: end,
                        location: self.text(input, "location"), notes: self.text(input, "notes")
                    )
                    return "Afspraak gemaakt: \(title)"
                }
            ),
            ToolSpec(
                name: "create_reminder",
                description: "Maakt een herinnering in de app Herinneringen, optioneel met een tijdstip.",
                schema: object([
                    "title": string("Wat moet de gebruiker onthouden?"),
                    "due": string("Wanneer, ISO 8601 met tijdzone. Optioneel.")
                ], required: ["title"]),
                kind: .action,
                summarize: { input in
                    let title = (input["title"] as? String) ?? "Herinnering"
                    if let due = NookTools.parseDate(input, "due") { return "Herinnering: \(title) · \(NookDates.short(due))" }
                    return "Herinnering: \(title)"
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let title = self.text(input, "title") else { throw NookError("De titel ontbreekt.") }
                    try await self.calendar.createReminder(title: title, due: self.date(input, "due"))
                    return "Herinnering gemaakt: \(title)"
                }
            ),
            ToolSpec(
                name: "add_open_loop",
                description: "Zet iets op de lijst met open punten van de gebruiker, bijvoorbeeld een belofte of iets wat nog moet gebeuren zonder vast tijdstip.",
                schema: object([
                    "title": string("Het open punt, kort en concreet."),
                    "due": string("Uiterlijk wanneer, ISO 8601. Optioneel.")
                ], required: ["title"]),
                kind: .action,
                summarize: { input in "Onthouden: \((input["title"] as? String) ?? "open punt")" },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let title = self.text(input, "title") else { throw NookError("De titel ontbreekt.") }
                    self.store.addLoop(title: title, source: "Nook", due: self.date(input, "due"))
                    self.onLoopsChanged()
                    return "Open punt toegevoegd: \(title)"
                }
            ),
            ToolSpec(
                name: "draft_mail",
                description: "Opent een conceptmail in Mail. De gebruiker leest het na en verstuurt zelf; Nook verstuurt nooit mail.",
                schema: object([
                    "to": string("E-mailadres van de ontvanger, optioneel."),
                    "subject": string("Onderwerp."),
                    "body": string("Inhoud van de mail.")
                ], required: ["subject", "body"]),
                kind: .action,
                summarize: { input in
                    let to = (input["to"] as? String) ?? ""
                    return "Concept in Mail" + (to.isEmpty ? "" : " aan \(to)")
                },
                tag: { _ in ("jij verstuurt", .caution) },
                run: { [weak self] input in
                    guard let self, let subject = self.text(input, "subject"), let body = self.text(input, "body") else {
                        throw NookError("Onderwerp of inhoud ontbreekt.")
                    }
                    var components = URLComponents()
                    components.scheme = "mailto"
                    components.path = self.text(input, "to") ?? ""
                    components.queryItems = [
                        URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body", value: body)
                    ]
                    guard let url = components.url else { throw NookError("Kon de mail niet voorbereiden.") }
                    NSWorkspace.shared.open(url)
                    return "Conceptmail geopend"
                }
            ),
            ToolSpec(
                name: "open_app",
                description: "Opent een app op de Mac, bijvoorbeeld \"Safari\" of \"Notities\".",
                schema: object(["name": string("Naam van de app.")], required: ["name"]),
                kind: .action,
                summarize: { input in "Open \((input["name"] as? String) ?? "app")" },
                tag: { _ in ("", .good) },
                run: { input in
                    guard let name = input["name"] as? String else { throw NookError("De appnaam ontbreekt.") }
                    try SystemControl.openApp(name)
                    return "\(name) geopend"
                }
            ),
            ToolSpec(
                name: "open_url",
                description: "Opent een webadres (https) in de standaardbrowser.",
                schema: object(["url": string("Het webadres, beginnend met https://")], required: ["url"]),
                kind: .action,
                summarize: { input in "Open \((input["url"] as? String) ?? "link")" },
                tag: { _ in ("opent in browser", .neutral) },
                run: { input in
                    guard let url = input["url"] as? String else { throw NookError("Het webadres ontbreekt.") }
                    try SystemControl.openURL(url)
                    return "Link geopend"
                }
            ),
            ToolSpec(
                name: "media_control",
                description: "Bedient de muziek in Spotify of Muziek: play_pause, next of previous.",
                schema: object([
                    "action": ["type": "string", "enum": ["play_pause", "next", "previous"], "description": "Wat er moet gebeuren."]
                ], required: ["action"]),
                kind: .action,
                summarize: { input in
                    switch input["action"] as? String {
                    case "next": return "Volgend nummer"
                    case "previous": return "Vorig nummer"
                    default: return "Muziek pauzeren of hervatten"
                    }
                },
                tag: { _ in ("", .good) },
                run: { input in
                    let command: String
                    switch input["action"] as? String {
                    case "next": command = "next track"
                    case "previous": command = "previous track"
                    default: command = "playpause"
                    }
                    let target = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty ? "Spotify" : "Music"
                    _ = SystemControl.appleScript("tell application \"\(target)\" to \(command)")
                    return "Gedaan"
                }
            ),
            ToolSpec(
                name: "set_volume",
                description: "Zet het geluidsvolume van de Mac op een niveau van 0 tot 100.",
                schema: object(["level": ["type": "integer", "description": "Volume 0–100."]], required: ["level"]),
                kind: .action,
                summarize: { input in "Volume op \((input["level"] as? Int) ?? 0)%" },
                tag: { _ in ("", .good) },
                run: { input in
                    guard let level = input["level"] as? Int else { throw NookError("Het niveau ontbreekt.") }
                    SystemControl.setVolume(level)
                    return "Volume staat op \(max(0, min(100, level)))%"
                }
            ),
            ToolSpec(
                name: "run_shortcut",
                description: "Draait een bestaande opdracht uit de app Opdrachten (Shortcuts) van de gebruiker, op naam.",
                schema: object(["name": string("Exacte naam van de opdracht.")], required: ["name"]),
                kind: .action,
                summarize: { input in "Opdracht: \((input["name"] as? String) ?? "?")" },
                tag: { _ in ("opdracht", .caution) },
                run: { input in
                    guard let name = input["name"] as? String else { throw NookError("De naam ontbreekt.") }
                    _ = try await Task.detached { try SystemControl.runShortcut(name) }.value
                    return "Opdracht \(name) gedraaid"
                }
            )
        ]
    }

    nonisolated static func parseDate(_ input: [String: Any], _ key: String) -> Date? {
        (input[key] as? String).flatMap { NookDates.parse($0) }
    }
}
