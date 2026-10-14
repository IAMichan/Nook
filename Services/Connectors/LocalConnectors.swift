import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// Bronnen op je eigen Mac. Niets hiervan gaat over het netwerk; pas als je iets vraagt, gaat een korte samenvatting naar het brein.

/// Hulp voor AppleScript-tekst: aanhalingstekens en backslashes onschadelijk maken.
enum ScriptText {
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Draait AppleScript buiten de hoofdthread en geeft tekst plus foutnummer terug.
    static func run(_ source: String) async -> (text: String?, errorNumber: Int?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SystemControl.appleScriptResult(source))
            }
        }
    }
}

// MARK: Agenda

@MainActor
final class CalendarConnector: ContextSource {
    let id = "calendar"
    let title = "Agenda"
    let symbol = "calendar"
    let accent = NookTheme.iris
    private(set) var status = ConnectorStatus()
    private let calendar: CalendarService
    private var events: [CalEvent] = []

    init(calendar: CalendarService) { self.calendar = calendar }

    var isActive: Bool { calendar.hasEventAccess && ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 120 }

    func refresh() async {
        guard calendar.hasEventAccess else {
            status = ConnectorStatus(state: .off, detail: "Geef toegang bij Instellingen › Machtigingen")
            return
        }
        let now = Date()
        events = calendar.events(from: Calendar.current.startOfDay(for: now), to: now.addingTimeInterval(7 * 86_400))
        let upcoming = events.filter { $0.end > now }
        let today = upcoming.filter { Calendar.current.isDateInToday($0.start) }
        var next = ""
        if let first = upcoming.first {
            next = first.start <= now ? tr("connect.local.calendarNow", first.title) : tr("connect.local.calendarNext", first.title, NookDates.time(first.start))
        }
        status = ConnectorStatus(
            state: .ok,
            headline: today.isEmpty ? tr("connect.local.calendarEmpty") : tr("connect.local.calendarToday", today.count),
            detail: next,
            items: upcoming.prefix(5).map {
                ConnectorItem(
                    id: $0.id,
                    title: $0.title,
                    subtitle: NookDates.short($0.start) + ($0.location.isEmpty ? "" : " · \($0.location)"),
                    tone: $0.start <= now ? .good : .neutral
                )
            },
            updated: now
        )
    }

    func contextLines() -> [String] {
        guard calendar.hasEventAccess else { return ["Agenda: geen toegang."] }
        if events.isEmpty { Task { await refresh() } }
        var lines = ["Agenda (Nook heeft toegang), vandaag en de komende zeven dagen:"]
        if events.isEmpty { lines.append("- geen afspraken") }
        for event in events.prefix(40) {
            let place = event.location.isEmpty ? "" : " | \(event.location)"
            lines.append("- \(event.title) | \(NookDates.iso(event.start)) – \(NookDates.iso(event.end))\(place)")
        }
        return lines
    }
}

extension CalendarConnector: AgendaSource {
    func agendaNames() -> [String] {
        let names = calendar.calendarNames()
        return names.isEmpty ? ["Apple Agenda"] : ["Apple Agenda: " + names.joined(separator: ", ")]
    }

    func agendaEntries(from: Date, to: Date) async throws -> AgendaResult {
        AgendaResult(entries: calendar.agendaEntries(from: from, to: to))
    }
}

// MARK: Herinneringen

@MainActor
final class RemindersConnector: ContextSource {
    let id = "reminders"
    let title = "Herinneringen"
    let symbol = "checklist"
    let accent = NookTheme.amber
    private(set) var status = ConnectorStatus()
    private let calendar: CalendarService
    private var reminders: [ReminderItem] = []

    init(calendar: CalendarService) { self.calendar = calendar }

    var isActive: Bool { calendar.hasReminderAccess && ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 180 }

    func refresh() async {
        guard calendar.hasReminderAccess else {
            status = ConnectorStatus(state: .off, detail: "Geef toegang bij Instellingen › Machtigingen")
            return
        }
        reminders = await calendar.incompleteReminders()
        let now = Date()
        let overdue = reminders.filter { ($0.due ?? .distantFuture) < now }
        status = ConnectorStatus(
            state: .ok,
            headline: reminders.isEmpty ? tr("connect.local.remindersEmpty") : tr("connect.local.remindersOpen", reminders.count),
            detail: overdue.isEmpty ? "" : tr("connect.local.remindersOverdue", overdue.count),
            items: reminders.prefix(5).map {
                ConnectorItem(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.due.map { tr("connect.local.remindersDue", NookDates.short($0)) } ?? $0.list,
                    tone: ($0.due ?? .distantFuture) < now ? .attention : .neutral
                )
            },
            updated: now,
            needsAttention: !overdue.isEmpty
        )
    }

    func contextLines() -> [String] {
        guard !reminders.isEmpty else { return [] }
        var lines = ["Herinneringen die openstaan:"]
        for reminder in reminders.prefix(15) {
            let due = reminder.due.map { " | uiterlijk \(NookDates.iso($0))" } ?? ""
            lines.append("- \(reminder.title)\(due)" + (reminder.list.isEmpty ? "" : " | lijst \(reminder.list)"))
        }
        return lines
    }
}

// MARK: Mail

/// Ongelezen mail uit de app Mail. Alleen als Mail al draait: Nook start Mail nooit zelf.
@MainActor
final class MailConnector: ContextSource {
    struct Message: Equatable {
        var subject: String
        var sender: String
        var date: String
    }

    let id = "mail"
    let title = "Mail"
    let symbol = "envelope"
    let accent = Color(hex: 0x4DA3FF)
    private(set) var status = ConnectorStatus()
    private var unread: [Message] = []
    private var unreadCount = 0

    var isActive: Bool { ConnectorToggle.isOn(id) && ScriptText.isRunning("com.apple.mail") }
    /// Op de achtergrond kijkt Nook alleen als Mail al open is; vraag je iets over je mail, dan opent de tool Mail zelf (verborgen).
    var canLookUp: Bool { ConnectorToggle.isOn(id) }

    /// Start Mail op de achtergrond als hij nog dicht is, en wacht tot hij antwoordt.
    static func ensureRunning() async throws {
        guard !ScriptText.isRunning("com.apple.mail") else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
            throw NookError("Mail staat niet op deze Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 where !ScriptText.isRunning("com.apple.mail") {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard ScriptText.isRunning("com.apple.mail") else { throw NookError("Mail wilde niet starten.") }
        // Even de tijd om de inbox te laden.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
    var refreshInterval: TimeInterval { 120 }

    func refresh() async {
        guard ScriptText.isRunning("com.apple.mail") else {
            status = ConnectorStatus(state: .off, detail: "Open Mail, dan kijkt Nook mee")
            return
        }
        let script = """
        tell application "Mail"
            set msgs to (messages of inbox whose read status is false)
            set total to count of msgs
            set n to total
            if n > 15 then set n to 15
            set out to (total as string) & linefeed
            repeat with i from 1 to n
                set m to item i of msgs
                set out to out & (subject of m) & "|||" & (sender of m) & "|||" & ((date received of m) as «class isot» as string) & linefeed
            end repeat
            return out
        end tell
        """
        let result = await ScriptText.run(script)
        if result.errorNumber == -1743 {
            status = ConnectorStatus(state: .error("Geef Nook toestemming om Mail te lezen: Systeeminstellingen › Privacy › Automatisering."))
            return
        }
        guard let text = result.text else {
            status = ConnectorStatus(state: .error("Mail gaf geen antwoord."))
            return
        }
        var lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        unreadCount = Int(lines.first ?? "") ?? 0
        if !lines.isEmpty { lines.removeFirst() }
        unread = lines.compactMap { line in
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 3 else { return nil }
            return Message(subject: parts[0], sender: parts[1], date: parts[2])
        }
        status = ConnectorStatus(
            state: .ok,
            headline: unreadCount == 0 ? tr("connect.local.mailAllRead") : tr("connect.local.mailUnread", unreadCount),
            detail: unread.first.map { tr("connect.local.mailLast", Self.name($0.sender)) } ?? "",
            items: unread.prefix(5).enumerated().map { index, message in
                ConnectorItem(id: "mail-\(index)", title: message.subject, subtitle: Self.name(message.sender), tone: .neutral)
            },
            updated: Date()
        )
    }

    nonisolated static func name(_ sender: String) -> String {
        // "Lisa de Vries <lisa@…>" → "Lisa de Vries"
        if let range = sender.range(of: " <") { return String(sender[..<range.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return sender
    }

    func contextLines() -> [String] {
        guard status.state == .ok else { return [] }
        // Ook "niets ongelezen" is een antwoord: zonder deze regel weet het brein niet dat het Mail al zag.
        guard unreadCount > 0 else { return ["Mail: geen ongelezen mail in de inbox."] }
        var lines = ["Mail: \(unreadCount) ongelezen in de inbox (per dag, account of afzender: mail_unread). Nieuwste:"]
        for message in unread.prefix(10) {
            lines.append("- \(message.subject) | van \(message.sender) | \(message.date)")
        }
        return lines
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "mail_unread",
                description: "Telt de ongelezen mail in de inbox van de app Mail, vers opgehaald: het totaal, per account, per dag van ontvangst (de laatste 14 dagen) en de afzenders met de meeste ongelezen mail. Gebruik dit voor vragen als 'hoeveel mail heb ik nog niet gelezen' en voor een grafiek van ongelezen mail.",
                schema: ["type": "object", "properties": [String: Any]()],
                kind: .read,
                summarize: { _ in "Ongelezen mail tellen" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    try await MailConnector.ensureRunning()
                    let result = await ScriptText.run(MailStats.unreadScript)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming om Mail te lezen: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    guard let raw = result.text else { throw NookError("Mail gaf geen antwoord.") }
                    return MailStats.unread(raw, now: Date())
                }
            ),
            ToolSpec(
                name: "search_mail",
                description: "Zoekt in de app Mail op onderwerp of afzender (inbox) of op onderwerp of ontvanger (verzonden) en geeft de nieuwste treffers met het begin van de tekst en een link naar het bericht. Gebruik dit voor vragen als 'wat schreef Lisa over de offerte'. Zoek met mailbox sent naar wat de gebruiker zelf schreef of beloofde.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Woord uit het onderwerp, of (deel van) de afzender of ontvanger."],
                    "mailbox": ["type": "string", "enum": ["inbox", "sent"], "description": "inbox (standaard) of sent (verzonden)."] as [String: Any]
                ], "required": ["query"]],
                kind: .read,
                summarize: { _ in "Mail doorzoeken" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    try await MailConnector.ensureRunning()
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let sent = (input["mailbox"] as? String)?.lowercased() == "sent"
                    let q = ScriptText.quote(query)
                    let box = sent ? "sent mailbox" : "inbox"
                    let filter = sent ? "subject contains \(q)" : "subject contains \(q) or sender contains \(q)"
                    let script = """
                    tell application "Mail"
                        set found to (messages of \(box) whose \(filter))
                        set n to count of found
                        if n > 8 then set n to 8
                        set out to ""
                        repeat with i from 1 to n
                            set m to item i of found
                            set body to ""
                            try
                                set body to content of m
                            end try
                            if (length of body) > 700 then set body to text 1 thru 700 of body
                            set mid to ""
                            try
                                set mid to message id of m
                            end try
                            set rcpt to ""
                            try
                                set rcpt to address of item 1 of to recipients of m
                            end try
                            set out to out & "<<<MSG>>>" & (subject of m) & "|||" & (sender of m) & "|||" & rcpt & "|||" & ((date received of m) as «class isot» as string) & "|||" & mid & linefeed & body & linefeed
                        end repeat
                        return out
                    end tell
                    """
                    let result = await ScriptText.run(script)
                    if result.errorNumber == -1743 {
                        throw NookError("Geef Nook toestemming om Mail te lezen: Systeeminstellingen › Privacy › Automatisering.")
                    }
                    let raw = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return "Geen mail gevonden voor \"\(query)\"" + (sent ? " in verzonden." : ".") }
                    return MailConnector.format(raw, sent: sent)
                }
            )
        ]
    }

    /// Maakt de treffers leesbaar voor het brein, met een verwijzing per bericht (een message:-link opent hem in Mail).
    nonisolated static func format(_ raw: String, sent: Bool) -> String {
        var blocks: [String] = []
        var refs: [String] = []
        for chunk in raw.components(separatedBy: "<<<MSG>>>") where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let header = String(lines.first ?? "").components(separatedBy: "|||")
            guard header.count >= 5 else { continue }
            let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let who = sent ? "aan \(header[2])" : "van \(header[1])"
            blocks.append("### \(header[0]) | \(who) | \(header[3])\n\(body)")
            refs.append(ReferenceParser.line(title: header[0].isEmpty ? "(geen onderwerp)" : header[0], url: messageLink(header[4]),
                                             detail: "\(sent ? header[2] : name(header[1])) · \(String(header[3].prefix(10)))"))
        }
        return (blocks + refs).joined(separator: "\n\n")
    }

    /// message:%3C…%3E opent het bericht in Mail. Alleen met een echt message-id, anders geen link.
    nonisolated static func messageLink(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n"))
        guard !trimmed.isEmpty, trimmed.contains("@"),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) else { return nil }
        return "message:%3C\(encoded)%3E"
    }
}

// MARK: Browser

/// Open tabbladen in Safari en Chromium-browsers (Chrome, Arc, Brave, Edge). Alleen browsers die al draaien.
@MainActor
final class BrowserConnector: ContextSource {
    struct Tab: Equatable {
        var browser: String
        var title: String
        var url: String
        var active: Bool
    }

    let id = "browser"
    let title = "Browser"
    let symbol = "safari"
    let accent = Color(hex: 0x5AC8FA)
    private(set) var status = ConnectorStatus()
    private var tabs: [Tab] = []

    private static let browsers: [(name: String, bundle: String, safari: Bool)] = [
        ("Safari", "com.apple.Safari", true),
        ("Google Chrome", "com.google.Chrome", false),
        ("Arc", "company.thebrowser.Browser", false),
        ("Brave Browser", "com.brave.Browser", false),
        ("Microsoft Edge", "com.microsoft.edgemac", false)
    ]

    var isActive: Bool { ConnectorToggle.isOn(id) && Self.browsers.contains { ScriptText.isRunning($0.bundle) } }
    var refreshInterval: TimeInterval { 45 }

    func refresh() async {
        var collected: [Tab] = []
        var denied = false
        for browser in Self.browsers where ScriptText.isRunning(browser.bundle) {
            let titleKey = browser.safari ? "name" : "title"
            let activeKey = browser.safari ? "current tab" : "active tab"
            let script = """
            tell application "\(browser.name)"
                set out to ""
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    if wi > 4 then exit repeat
                    set act to ""
                    try
                        set act to URL of \(activeKey) of w
                    end try
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        if ti > 15 then exit repeat
                        set u to URL of t
                        set mark to "0"
                        if u is act then set mark to "1"
                        set out to out & mark & "|||" & (\(titleKey) of t) & "|||" & u & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
            let result = await ScriptText.run(script)
            if result.errorNumber == -1743 { denied = true }
            for line in (result.text ?? "").components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 3, parts[2].hasPrefix("http") else { continue }
                collected.append(Tab(browser: browser.name, title: parts[1], url: parts[2], active: parts[0] == "1"))
            }
        }
        tabs = collected
        if collected.isEmpty && denied {
            status = ConnectorStatus(state: .error("Geef Nook toestemming voor je browser: Systeeminstellingen › Privacy › Automatisering."))
            return
        }
        let active = collected.filter(\.active)
        status = ConnectorStatus(
            state: .ok,
            headline: tr("connect.local.browserTabsOpen", collected.count),
            detail: active.first.map { tr("connect.local.browserNow", $0.title) } ?? "",
            items: (active + collected.filter { !$0.active }).prefix(5).enumerated().map { index, tab in
                ConnectorItem(id: "tab-\(index)", title: tab.title, subtitle: URL(string: tab.url)?.host ?? tab.browser,
                              tone: tab.active ? .good : .neutral, url: URL(string: tab.url))
            },
            updated: Date()
        )
    }

    func contextLines() -> [String] {
        guard !tabs.isEmpty else { return [] }
        var lines = ["Open browsertabbladen (* = actief tabblad van een venster):"]
        for tab in tabs.sorted(by: { $0.active && !$1.active }).prefix(20) {
            lines.append("- \(tab.active ? "* " : "")\(tab.title) | \(tab.url)")
        }
        return lines
    }
}

// MARK: Bestanden

/// Leest tekst uit gewone documenten. Gedeeld door de Shelf en de bestanden-tools.
enum FileText {
    static func read(_ url: URL, limit: Int = 5_000_000) throws -> String {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        var text: String?
        if type.conforms(to: .pdf) {
            text = PDFDocument(url: url)?.string
        } else if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || ["doc", "docx", "odt", "html", "htm", "pages"].contains(url.pathExtension.lowercased()) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size < limit { text = try? String(contentsOf: url, encoding: .utf8) }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NookError("Ik kan in \(url.lastPathComponent) geen tekst lezen. Tekst, pdf, Word en rtf lukken wel.")
        }
        return text
    }

    /// Alleen bestanden in je eigen map, niet in verborgen mappen of Bibliotheek (sleutels, wachtwoorden, instellingen).
    static func isAllowed(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        let parts = relative.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts.first == "Library" { return false }
        return true
    }
}

/// Recent gebruikte bestanden (Spotlight) en zoeken in je bestanden.
@MainActor
final class FilesConnector: ContextSource {
    let id = "files"
    let title = "Bestanden"
    let symbol = "doc.on.doc"
    let accent = Color(hex: 0xB0A8FF)
    private(set) var status = ConnectorStatus()
    private var recent: [URL] = []

    var isActive: Bool { ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 600 }

    private nonisolated static func spotlight(_ arguments: [String]) async -> [URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let output = (try? SystemControl.runProcess("/usr/bin/mdfind", ["-onlyin", home] + arguments)) ?? ""
                let urls = output.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
                continuation.resume(returning: urls)
            }
        }
    }

    func refresh() async {
        let found = await Self.spotlight(["kMDItemLastUsedDate >= $time.today(-3) && kMDItemContentTypeTree == \"public.content\""])
        let allowed = found.filter { FileText.isAllowed($0) && !$0.hasDirectoryPath }
        let dated = allowed.prefix(300).map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        recent = dated.sorted { $0.1 > $1.1 }.prefix(15).map { $0.0 }
        status = ConnectorStatus(
            state: .ok,
            headline: tr("connect.local.filesRecent", recent.count),
            detail: recent.first.map { tr("connect.local.filesLast", $0.lastPathComponent) } ?? "",
            items: recent.prefix(5).enumerated().map { index, url in
                ConnectorItem(id: "file-\(index)", title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().lastPathComponent)
            },
            updated: Date()
        )
    }

    func contextLines() -> [String] {
        guard !recent.isEmpty else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Recent gebruikte bestanden:"] + recent.prefix(10).map { "- " + $0.path.replacingOccurrences(of: home, with: "~") }
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_files",
                description: "Zoekt met Spotlight in de bestanden van de gebruiker (naam en inhoud) en geeft de paden van de beste treffers.",
                schema: ["type": "object", "properties": ["query": ["type": "string", "description": "Zoekwoorden."]], "required": ["query"]],
                kind: .read,
                summarize: { _ in "Bestanden zoeken" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let byName = await FilesConnector.spotlight(["-name", query])
                    let byContent = await FilesConnector.spotlight([query])
                    var seen = Set<String>()
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    let hits = (byName + byContent).filter { FileText.isAllowed($0) && seen.insert($0.path).inserted }.prefix(20)
                    if hits.isEmpty { return "Niets gevonden voor \"\(query)\"." }
                    let paths = hits.map { $0.path.replacingOccurrences(of: home, with: "~") }
                    let refs = hits.prefix(8).map {
                        ReferenceParser.line(title: $0.lastPathComponent, url: $0.absoluteString, detail: $0.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"))
                    }
                    return (paths + refs).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "read_file",
                description: "Leest de tekst van een document van de gebruiker (tekst, pdf, Word, rtf). Geef een pad uit search_files of uit de lijst met recente bestanden.",
                schema: ["type": "object", "properties": ["path": ["type": "string", "description": "Pad, mag met ~ beginnen."]], "required": ["path"]],
                kind: .read,
                summarize: { _ in "Bestand lezen" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let raw = ((input["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                    guard FileText.isAllowed(url) else { throw NookError("Dat bestand mag Nook niet lezen.") }
                    let text = try FileText.read(url)
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { "bewerkt \(NookDates.short($0))" } ?? ""
                    var output = String(text.prefix(15_000))
                    if text.count > 15_000 { output += "\n… (ingekort: de eerste 15.000 tekens van \(text.count))" }
                    return output + "\n" + ReferenceParser.line(title: url.lastPathComponent, url: url.absoluteString, detail: modified)
                }
            )
        ]
    }
}

// MARK: Klembord

/// Wat je net kopieerde. Standaard uit: een klembord kan gevoelig zijn. Wachtwoorden (gemarkeerd als verborgen) slaat Nook altijd over.
@MainActor
final class ClipboardConnector: ContextSource {
    let id = "clipboard"
    let title = "Klembord"
    let symbol = "doc.on.clipboard"
    let accent = Color(hex: 0x9C9AA8)
    private(set) var status = ConnectorStatus()

    var isActive: Bool { ConnectorToggle.isOn(id, default: false) }
    var refreshInterval: TimeInterval { 30 }

    private var current: String? {
        let board = NSPasteboard.general
        let types = board.types ?? []
        let secret = types.contains { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue) }
        guard !secret, let text = board.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func refresh() async {
        guard isActive else {
            status = ConnectorStatus(state: .off, detail: tr("connect.local.clipboardOff"))
            return
        }
        let text = current
        status = ConnectorStatus(state: .ok, headline: text == nil ? tr("connect.local.clipboardEmpty") : tr("connect.local.clipboardCopied"),
                                 detail: text.map { String($0.prefix(80)) } ?? "", updated: Date())
    }

    func contextLines() -> [String] {
        guard isActive, let text = current else { return [] }
        return ["Klembord (net gekopieerd):", String(text.prefix(1500))]
    }
}
