import Foundation
import AppKit
import Contacts

/// A single capability of Nook. Read tools execute immediately during reasoning; action tools are presented to you as a plan first.
struct ToolSpec {
    enum Kind { case read, action }

    let name: String
    let description: String
    let schema: [String: Any]
    let kind: Kind
    /// A single summary line for the plan, e.g. "Calendar: Coffee with Lisa · Fri Oct 16 14:00".
    let summarize: ([String: Any]) -> String
    /// Short tag badge following the line (empty = standard).
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
    /// Controls the music player ("play_pause", "next", "previous"); set by the app to the now-playing service.
    var mediaControl: ((String) -> Void)?
    /// Supplies screen text from the live cache (fast). Without this, read_screen captures fresh OCR.
    var screenSnapshot: (() async throws -> ScreenSnapshot)?

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

    // MARK: Schema helpers

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

    // MARK: Tool definitions

    private func buildSpecs() -> [ToolSpec] {
        [
            ToolSpec(
                name: "list_events",
                description: "Reads calendar events between two timestamps. Use this to discover free time slots or check for schedule conflicts.",
                schema: object([
                    "from": string("Start, ISO 8601 with timezone."),
                    "to": string("End, ISO 8601 with timezone.")
                ], required: ["from", "to"]),
                kind: .read,
                summarize: { _ in "Read calendar" },
                tag: { _ in ("", .neutral) },
                run: { [calendar = self.calendar] input in
                    guard let from = NookTools.parseDate(input, "from"), let to = NookTools.parseDate(input, "to") else {
                        throw NookError("from and to must be ISO 8601 dates.")
                    }
                    await calendar.requestEvents()
                    let events = calendar.events(from: from, to: to)
                    if events.isEmpty { return "No events in this time range (or no calendar access granted)." }
                    // Includes ID (for update_event) and formatted as reference citations.
                    let lines = events.prefix(40).map {
                        "\($0.title) | \(NookDates.iso($0.start)) – \(NookDates.iso($0.end))" + ($0.location.isEmpty ? "" : " | \($0.location)")
                            + ($0.calendar.isEmpty ? "" : " | calendar \($0.calendar)") + " | id \($0.id)"
                    }
                    let refs = events.prefix(10).map {
                        ReferenceParser.line(title: $0.title, url: nil, detail: NookDates.short($0.start) + ($0.calendar.isEmpty ? "" : " · \($0.calendar)"))
                    }
                    return (lines + refs).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "read_screen",
                description: "Reads visible text across all windows on all displays of the user's Mac, frontmost window first (local OCR). Determine yourself which window holds the relevant context. Use this IMMEDIATELY, without asking first what is on screen, whenever the user refers to something visible or recently read: 'here', 'this', 'that', 'that email', 'schedule this', 'put that on my calendar'. Extract title, date, time, location, and attendees from the text.",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Read screen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self, screen = self.screen] _ in
                    if let live = self?.screenSnapshot { return try await live().text }
                    let snapshot = try await screen.captureAll()
                    return snapshot.text
                }
            ),
            ToolSpec(
                name: "read_app",
                description: "Reads what is in an app (locally, through the macOS accessibility layer), even if that app is behind other windows, hidden or closed. Everything happens invisibly in the background: a closed app is launched hidden, read and quit again. Use this for questions about an app without its own connector (Notes, Messages, WhatsApp, Slack, Teams, Things, Spotify, Excel, Figma…) or to look inside a specific app. Open apps are listed in the context under \"Open apps\"; other installed apps may be named too.",
                schema: object(["app": string("Name of the app, for example \"Notes\" or \"Slack\".")], required: ["app"]),
                kind: .read,
                summarize: { input in "Read \((input["app"] as? String) ?? "app")" },
                tag: { _ in ("", .neutral) },
                run: { [screen = self.screen] input in
                    guard let app = input["app"] as? String else { throw NookError("De appnaam ontbreekt.") }
                    return try await screen.captureApp(app).text
                }
            ),
            ToolSpec(
                name: "list_open_loops",
                description: "Lists open todos/commitments tracked by Nook for the user (pending items requiring follow-up).",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Read open todos" },
                tag: { _ in ("", .neutral) },
                run: { [store = self.store] _ in
                    let loops = store.openLoops()
                    if loops.isEmpty { return "No open todos." }
                    return loops.map {
                        "- \($0.title) (since \(NookDates.short($0.created))" + ($0.due.map { ", due \(NookDates.short($0))" } ?? "") + ") [id \($0.id.prefix(8))]"
                    }.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "create_event",
                description: "Creates a new calendar event. Only invoke when title and start time are clearly established.",
                schema: object([
                    "title": string("Title of the event."),
                    "start": string("Start time, ISO 8601 with timezone."),
                    "end": string("End time, ISO 8601 with timezone. Defaults to one hour after start."),
                    "location": string("Location, optional."),
                    "notes": string("Notes, optional."),
                    "calendar": string("Name of target calendar, optional. Defaults to default calendar.")
                ], required: ["title", "start"]),
                kind: .action,
                summarize: { input in
                    let title = (input["title"] as? String) ?? "Event"
                    let start = NookTools.parseDate(input, "start").map { NookDates.short($0) } ?? "?"
                    let target = ((input["calendar"] as? String).map { " · \($0)" }) ?? ""
                    return "Calendar: \(title) · \(start)\(target)"
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let title = self.text(input, "title"), let start = self.date(input, "start") else {
                        throw NookError("Title or start time missing.")
                    }
                    let end = self.date(input, "end") ?? start.addingTimeInterval(3600)
                    guard end > start else { throw NookError("End time must be after start time.") }
                    let id = try await self.calendar.createEvent(
                        title: title, start: start, end: end,
                        location: self.text(input, "location"), notes: self.text(input, "notes"),
                        calendarName: self.text(input, "calendar")
                    )
                    return "Event created: \(title) at \(NookDates.short(start))" + (id.isEmpty ? "" : " (id \(id))")
                }
            ),
            ToolSpec(
                name: "update_event",
                description: "Updates an existing event: title, time, location, or notes. Use the ID from list_events or create_event output. Only supplied fields are updated; omitting end shifts the event preserving duration. Nook cannot invite attendees directly (macOS restriction): propose an email draft instead.",
                schema: object([
                    "id": string("ID of the event."),
                    "title": string("New title, optional."),
                    "start": string("New start time, ISO 8601 with timezone. Optional."),
                    "end": string("New end time, ISO 8601 with timezone. Optional."),
                    "location": string("New location, optional."),
                    "notes": string("New notes, optional.")
                ], required: ["id"]),
                kind: .action,
                summarize: { input in
                    var parts: [String] = []
                    if let title = input["title"] as? String { parts.append("title \"\(title)\"") }
                    if let start = NookTools.parseDate(input, "start") { parts.append("to \(NookDates.short(start))") }
                    if let location = input["location"] as? String { parts.append("location \(location)") }
                    return "Update calendar: " + (parts.isEmpty ? "event" : parts.joined(separator: ", "))
                },
                tag: { _ in ("modifies", .caution) },
                run: { [weak self] input in
                    guard let self, let id = self.text(input, "id") else { throw NookError("Event ID is missing.") }
                    let changed = try await self.calendar.updateEvent(
                        id: id, title: self.text(input, "title"), start: self.date(input, "start"), end: self.date(input, "end"),
                        location: self.text(input, "location"), notes: self.text(input, "notes")
                    )
                    return "Event updated (\(changed))"
                }
            ),
            ToolSpec(
                name: "create_reminder",
                description: "Creates a reminder in the Reminders app, optionally with a due date.",
                schema: object([
                    "title": string("What should the user be reminded of?"),
                    "due": string("Due date/time, ISO 8601 with timezone. Optional.")
                ], required: ["title"]),
                kind: .action,
                summarize: { input in
                    let title = (input["title"] as? String) ?? "Reminder"
                    if let due = NookTools.parseDate(input, "due") { return "Reminder: \(title) · \(NookDates.short(due))" }
                    return "Reminder: \(title)"
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let title = self.text(input, "title") else { throw NookError("Title is missing.") }
                    let id = try await self.calendar.createReminder(title: title, due: self.date(input, "due"))
                    return "Reminder created: \(title) (id \(id))"
                }
            ),
            ToolSpec(
                name: "delete_event",
                description: "Removes a calendar event, by the ID from create_event or list_events. Use to undo an event Nook just made or when the user asks to remove one.",
                schema: object(["id": string("ID of the event."), "title": string("Title of the event, shown in the plan. Optional.")], required: ["id"]),
                kind: .action,
                summarize: { input in "Remove from calendar: \((input["title"] as? String) ?? (input["id"] as? String) ?? "event")" },
                tag: { _ in ("removes", .caution) },
                run: { [weak self] input in
                    guard let self, let id = self.text(input, "id") else { throw NookError("Event ID is missing.") }
                    let title = try await self.calendar.deleteEvent(id: id)
                    return "Event removed: \(title)"
                }
            ),
            ToolSpec(
                name: "delete_reminder",
                description: "Removes a reminder, by the ID from create_reminder. Use to undo a reminder Nook just made.",
                schema: object(["id": string("ID of the reminder."), "title": string("Title of the reminder, shown in the plan. Optional.")], required: ["id"]),
                kind: .action,
                summarize: { input in "Remove reminder: \((input["title"] as? String) ?? (input["id"] as? String) ?? "reminder")" },
                tag: { _ in ("removes", .caution) },
                run: { [weak self] input in
                    guard let self, let id = self.text(input, "id") else { throw NookError("Reminder ID is missing.") }
                    let title = try await self.calendar.deleteReminder(id: id)
                    return "Reminder removed: \(title)"
                }
            ),
            ToolSpec(
                name: "complete_reminder",
                description: "Marks an active reminder as completed in Reminders. Supply the ID (from create_reminder output) or exact title from context.",
                schema: object(["reminder": string("ID or exact title of the reminder.")], required: ["reminder"]),
                kind: .action,
                summarize: { input in "Complete reminder: \((input["reminder"] as? String) ?? "?")" },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let target = self.text(input, "reminder") else { throw NookError("Which reminder?") }
                    let title = try await self.calendar.completeReminder(target)
                    return "Completed: \(title)"
                }
            ),
            ToolSpec(
                name: "add_open_loop",
                description: "Adds an item to the user's open todos list, e.g. a commitment or pending task without a scheduled time.",
                schema: object([
                    "title": string("The todo item, concise and actionable."),
                    "due": string("Due date, ISO 8601. Optional.")
                ], required: ["title"]),
                kind: .action,
                summarize: { input in "Remember: \((input["title"] as? String) ?? "todo")" },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let title = self.text(input, "title") else { throw NookError("Title is missing.") }
                    let loop = self.store.addLoop(title: title, source: "Nook", due: self.date(input, "due"))
                    self.onLoopsChanged()
                    return "Todo added: \(title) [id \(loop.id.prefix(8))]"
                }
            ),
            ToolSpec(
                name: "complete_open_loop",
                description: "Marks an open todo in Nook as completed. Supply the bracketed ID from context or list_open_loops, or exact title.",
                schema: object(["loop": string("ID (first eight characters sufficient) or exact title.")], required: ["loop"]),
                kind: .action,
                summarize: { input in "Complete todo: \((input["loop"] as? String) ?? "?")" },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self, let target = self.text(input, "loop") else { throw NookError("Which todo?") }
                    guard let loop = self.store.completeLoop(matching: target) else {
                        throw NookError("No todo found matching \(target).")
                    }
                    self.onLoopsChanged()
                    return "Completed: \(loop.title)"
                }
            ),
            ToolSpec(
                name: "open_app",
                description: "Opens an application on the Mac, e.g. \"Safari\" or \"Notes\".",
                schema: object(["name": string("Name of the app.")], required: ["name"]),
                kind: .action,
                summarize: { input in "Open \((input["name"] as? String) ?? "app")" },
                tag: { _ in ("", .good) },
                run: { input in
                    guard let name = input["name"] as? String else { throw NookError("App name is missing.") }
                    try SystemControl.openApp(name)
                    return "Opened \(name)"
                }
            ),
            ToolSpec(
                name: "open_url",
                description: "Opens a web URL (https) in the default browser.",
                schema: object(["url": string("The web URL, starting with https://")], required: ["url"]),
                kind: .action,
                summarize: { input in "Open \((input["url"] as? String) ?? "link")" },
                tag: { _ in ("opens in browser", .neutral) },
                run: { input in
                    guard let url = input["url"] as? String else { throw NookError("Web URL is missing.") }
                    try SystemControl.openURL(url)
                    return "Link opened"
                }
            ),
            ToolSpec(
                name: "media_control",
                description: "Controls playback in Spotify or Apple Music: play_pause, next, or previous.",
                schema: object([
                    "action": ["type": "string", "enum": ["play_pause", "next", "previous"], "description": "Action to perform."]
                ], required: ["action"]),
                kind: .action,
                summarize: { input in
                    switch input["action"] as? String {
                    case "next": return "Next track"
                    case "previous": return "Previous track"
                    default: return "Pause or resume music"
                    }
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    // One implementation of music control: the now-playing service (it knows which player is active).
                    guard let control = self?.mediaControl else { throw NookError(tr("app.unavailable")) }
                    control((input["action"] as? String) ?? "play_pause")
                    return "Done"
                }
            ),
            ToolSpec(
                name: "set_volume",
                description: "Sets system output volume on the Mac to a level between 0 and 100.",
                schema: object(["level": ["type": "integer", "description": "Volume 0–100."]], required: ["level"]),
                kind: .action,
                summarize: { input in "Volume at \((input["level"] as? Int) ?? 0)%" },
                tag: { _ in ("", .good) },
                run: { input in
                    guard let level = input["level"] as? Int else { throw NookError("Volume level is missing.") }
                    SystemControl.setVolume(level)
                    return "Volume set to \(max(0, min(100, level)))%"
                }
            ),
            ToolSpec(
                name: "run_shortcut",
                description: "Runs an existing shortcut from the Shortcuts app by name.",
                schema: object(["name": string("Exact name of the shortcut.")], required: ["name"]),
                kind: .action,
                summarize: { input in "Shortcut: \((input["name"] as? String) ?? "?")" },
                tag: { _ in ("shortcut", .caution) },
                run: { input in
                    guard let name = input["name"] as? String else { throw NookError("Shortcut name is missing.") }
                    _ = try await Task.detached { try SystemControl.runShortcut(name) }.value
                    return "Shortcut \(name) executed"
                }
            ),
            ToolSpec(
                name: "list_running_apps",
                description: "Geeft een overzicht van alle apps die momenteel draaien op de Mac van de gebruiker, inclusief welke app nu voorop staat. Gebruik dit voor vragen als 'welke apps staan er open', 'wat draait er nu', of om te bepalen welke app de gebruiker gebruikt.",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Geopende apps bekijken" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let apps = ScreenReader.openApps()
                    if apps.isEmpty { return "Geen geopende Dock-apps gevonden." }
                    let lines = apps.map { app -> String in
                        let name = app.localizedName ?? "Onbekende app"
                        let isFront = app.processIdentifier == frontPID ? " (actief venster)" : ""
                        let bundle = app.bundleIdentifier.map { " [\($0)]" } ?? ""
                        return "- \(name)\(isFront)\(bundle)"
                    }
                    return "Geopende applicaties op deze Mac:\n" + lines.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "get_active_app",
                description: "Geeft de app en het venster dat de gebruiker op dit moment voor zich heeft.",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Actieve app bekijken" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    guard let front = NSWorkspace.shared.frontmostApplication else { return "Geen actieve app gevonden." }
                    let name = front.localizedName ?? "Onbekend"
                    let bundle = front.bundleIdentifier ?? ""
                    return "Voorste app: \(name) (\(bundle))"
                }
            ),
            ToolSpec(
                name: "read_clipboard",
                description: "Leest de huidige tekst die de gebruiker op het klembord heeft gekopieerd. Slaat wachtwoorden en verborgen klembordinhoud over.",
                schema: object([:], required: []),
                kind: .read,
                summarize: { _ in "Klembord lezen" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    // Follows the Clipboard switch in Settings, like the clipboard context does.
                    guard ConnectorToggle.isOn("clipboard", default: false) else {
                        throw NookError("Het klembord staat uit. Zet het aan bij Instellingen › Koppelingen › Klembord.")
                    }
                    let board = NSPasteboard.general
                    let types = board.types ?? []
                    let secret = types.contains { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue) }
                    guard !secret, let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return "Het klembord is leeg of bevat geen leesbare tekst."
                    }
                    let truncated = String(text.prefix(4000))
                    return "Inhoud klembord:\n\(truncated)" + (text.count > 4000 ? "\n… (ingekort)" : "")
                }
            ),
            ToolSpec(
                name: "search_contacts",
                description: "Zoekt in het adresboek / de Contacten van de gebruiker op naam, bedrijf of email, en geeft telefoonnummers en emailadressen terug. Gebruik dit voor vragen als 'wat is het nummer van Lisa', 'zoek contactgegevens van...'.",
                schema: object(["query": string("Naam, bedrijf of zoekterm van het contact.")], required: ["query"]),
                kind: .read,
                summarize: { input in "Contact zoeken: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    guard let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                        throw NookError("Zoekterm ontbreekt.")
                    }
                    let store = CNContactStore()
                    let auth = CNContactStore.authorizationStatus(for: .contacts)
                    if auth == .notDetermined {
                        _ = try? await store.requestAccess(for: .contacts)
                    }
                    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                        throw NookError("Nook heeft geen toegang tot Contacten. Geef toegang in Systeeminstellingen › Privacy en beveiliging › Contacten.")
                    }
                    let keys: [CNKeyDescriptor] = [
                        CNContactGivenNameKey as CNKeyDescriptor,
                        CNContactFamilyNameKey as CNKeyDescriptor,
                        CNContactOrganizationNameKey as CNKeyDescriptor,
                        CNContactPhoneNumbersKey as CNKeyDescriptor,
                        CNContactEmailAddressesKey as CNKeyDescriptor,
                        CNContactJobTitleKey as CNKeyDescriptor
                    ]
                    let predicate = CNContact.predicateForContacts(matchingName: query)
                    guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys), !contacts.isEmpty else {
                        return "Geen contacten gevonden voor \"\(query)\"."
                    }
                    var lines: [String] = []
                    var refs: [String] = []
                    for contact in contacts.prefix(10) {
                        let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                        var parts: [String] = []
                        if !contact.organizationName.isEmpty { parts.append(contact.organizationName) }
                        if !contact.jobTitle.isEmpty { parts.append(contact.jobTitle) }
                        let phones = contact.phoneNumbers.map { "\($0.label ?? "tel"): \($0.value.stringValue)" }
                        let emails = contact.emailAddresses.map { String($0.value) }
                        var details = parts.joined(separator: ", ")
                        if !phones.isEmpty { details += (details.isEmpty ? "" : " | ") + phones.joined(separator: ", ") }
                        if !emails.isEmpty { details += (details.isEmpty ? "" : " | ") + emails.joined(separator: ", ") }
                        lines.append("- **\(name)**" + (details.isEmpty ? "" : ": \(details)"))
                        refs.append(ReferenceParser.line(title: name, url: nil, detail: details))
                    }
                    return (lines + refs).joined(separator: "\n")
                }
            )
        ]
    }

    nonisolated static func parseDate(_ input: [String: Any], _ key: String) -> Date? {
        (input[key] as? String).flatMap { NookDates.parse($0) }
    }
}
