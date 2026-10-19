import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// Sources on your own Mac. None of this goes over the network; only when you ask something does a short summary go to the brain.

/// Helper for AppleScript text: escaping quotes and backslashes.
enum ScriptText {
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Runs AppleScript off the main thread with a timeout and returns text plus error number.
    static func run(_ source: String, timeout: TimeInterval = 4.0) async -> (text: String?, errorNumber: Int?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SystemControl.appleScriptResult(source, timeout: timeout))
            }
        }
    }
}

// MARK: - Calendar

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
            status = ConnectorStatus(state: .off, detail: "Grant access in Settings › Permissions")
            return
        }
        let now = Date()
        events = await calendar.loadEvents(from: Calendar.current.startOfDay(for: now), to: now.addingTimeInterval(7 * 86_400))
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
        guard calendar.hasEventAccess else { return ["Calendar: no access."] }
        if events.isEmpty { Task { await refresh() } }
        var lines = ["Calendar (Nook has access), today and the next seven days:"]
        if events.isEmpty { lines.append("- no events") }
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

// MARK: - Reminders

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
            status = ConnectorStatus(state: .off, detail: "Grant access in Settings › Permissions")
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

    var canLookUp: Bool { ConnectorToggle.isOn(id) }

    func contextLines() -> [String] {
        guard !reminders.isEmpty else { return [] }
        var lines = ["Reminders that are open:"]
        for reminder in reminders.prefix(15) {
            let due = reminder.due.map { " | due \(NookDates.iso($0)) (\(NookDates.distance($0)))" } ?? ""
            lines.append("- \(reminder.title)\(due)" + (reminder.list.isEmpty ? "" : " | list \(reminder.list)"))
        }
        return lines
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "list_reminders",
                description: "Geeft de openstaande herinneringen uit de app Herinneringen, gesorteerd op vervaldatum. Gebruik dit wanneer de gebruiker vraagt om herinneringen te tonen of welke taken er openstaan.",
                schema: ["type": "object", "properties": [
                    "include_completed": ["type": "boolean", "description": "Optioneel ook afgeronde herinneringen tonen (standaard false)."] as [String: Any]
                ]],
                kind: .read,
                summarize: { _ in "Herinneringen bekijken" },
                tag: { _ in ("", .neutral) },
                run: { [calendar = self.calendar] input in
                    let completed = (input["include_completed"] as? Bool) ?? false
                    let items = await calendar.allReminders(includeCompleted: completed)
                    if items.isEmpty { return "Geen herinneringen gevonden in de app Herinneringen." }
                    let lines = items.prefix(30).map {
                        let due = $0.due.map { " (uiterlijk: \(NookDates.short($0)))" } ?? ""
                        let list = $0.list.isEmpty ? "" : " [lijst: \($0.list)]"
                        return "- \($0.title)\(due)\(list) [id: \($0.id)]"
                    }
                    let refs = items.prefix(8).map {
                        ReferenceParser.line(title: $0.title, url: nil, detail: $0.list.isEmpty ? "Herinneringen" : $0.list)
                    }
                    return (lines + refs).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "search_reminders",
                description: "Zoekt in de app Herinneringen op trefwoord in de titel of lijst van de herinnering.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Zoekterm voor de herinnering."]
                ], "required": ["query"]],
                kind: .read,
                summarize: { input in "Herinnering zoeken: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [calendar = self.calendar] input in
                    let q = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !q.isEmpty else { throw NookError("Zoekterm ontbreekt.") }
                    let items = await calendar.searchReminders(query: q)
                    if items.isEmpty { return "Geen herinneringen gevonden voor \"\(q)\"." }
                    let lines = items.prefix(15).map {
                        let due = $0.due.map { " (uiterlijk: \(NookDates.short($0)))" } ?? ""
                        let list = $0.list.isEmpty ? "" : " [lijst: \($0.list)]"
                        return "- \($0.title)\(due)\(list) [id: \($0.id)]"
                    }
                    let refs = items.prefix(6).map {
                        ReferenceParser.line(title: $0.title, url: nil, detail: $0.list.isEmpty ? "Herinneringen" : $0.list)
                    }
                    return (lines + refs).joined(separator: "\n")
                }
            )
        ]
    }
}

// MARK: - Mail

/// Mail from the Mail app, kept ready in the background so a question about mail is answered instantly from memory:
/// the newest messages of every inbox (with read and replied state) and the start of the text of the ones still waiting
/// for a reply. Only while Mail is already running: in the background Nook never starts Mail itself.
@MainActor
final class MailConnector: ContextSource {
    let id = "mail"
    let title = "Mail"
    let symbol = "envelope"
    let accent = Color(hex: 0x4DA3FF)
    private(set) var status = ConnectorStatus()
    private var unreadCount = 0
    struct CachedMail: Sendable {
        var subject: String
        var sender: String
        var recipients: String
        var date: String
        var body: String
        var cachedAt: Date
    }

    private var recent: [MailStats.InboxRow] = []
    /// Bodies already read, by message key, so each refresh only reads new mail.
    private var bodies: [String: String] = [:]
    private static var messageCache: [String: CachedMail] = [:] {
        didSet { if messageCache.count > cacheLimit { trimMessageCache() } }
    }
    /// Bodies are reused for two minutes (`readMessage`); beyond this many, the old ones go, so full mail bodies do not
    /// pile up in memory for as long as Nook runs.
    private static let cacheLimit = 300

    private static func trimMessageCache() {
        let cutoff = Date().addingTimeInterval(-600)
        var kept = messageCache.filter { $0.value.cachedAt > cutoff }
        if kept.count > cacheLimit { kept = [:] }
        messageCache = kept
    }
    private var loadedAt: Date?
    private var loading: Task<Void, Never>?

    var isActive: Bool { ConnectorToggle.isOn(id) && ScriptText.isRunning("com.apple.mail") }
    /// In the background Nook only looks when Mail is already open; when asked about mail, the tool opens Mail itself (hidden).
    var canLookUp: Bool { ConnectorToggle.isOn(id) }

    /// Starts Mail in the background if it is closed, and waits until it responds.
    static func ensureRunning() async throws {
        guard !ScriptText.isRunning("com.apple.mail") else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
            throw NookError("Mail is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<60 where !ScriptText.isRunning("com.apple.mail") {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard ScriptText.isRunning("com.apple.mail") else { throw NookError("Mail failed to launch.") }
        // Brief pause for Mail's scripting bridge to initialize.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    var refreshInterval: TimeInterval { 60 }

    /// Fresh enough to answer from memory.
    var isFresh: Bool { loadedAt.map { Date().timeIntervalSince($0) < 90 } ?? false }

    func refresh() async {
        guard ScriptText.isRunning("com.apple.mail") else {
            status = ConnectorStatus(state: .off, detail: "Open Mail, and Nook will follow along")
            return
        }
        // One load at a time: a question that arrives during a background refresh waits for that one.
        if let loading { await loading.value; return }
        let task = Task { await self.load() }
        loading = task
        await task.value
        loading = nil
    }

    private func load() async {
        let result = await ScriptText.run(MailStats.recentScript())
        if result.errorNumber == -1743 {
            status = ConnectorStatus(state: .error("Grant Nook permission to read Mail: System Settings › Privacy & Security › Automation."))
            return
        }
        guard let text = result.text else {
            status = ConnectorStatus(state: .error("Mail did not respond."))
            return
        }
        let parsed = MailStats.recent(text)
        unreadCount = parsed.unread
        var rows = parsed.rows
        // Read the start of the text of mail that still waits for a reply, newest first, only what is not read yet.
        let waiting = MailStats.select(rows, now: Date(), days: 14, unansweredOnly: true, limit: 10)
        let missing = waiting.filter { bodies[$0.key] == nil }
        if !missing.isEmpty {
            let texts = MailStats.bodies((await ScriptText.run(MailStats.bodiesScript(missing))).text ?? "")
            for (n, row) in missing.enumerated() { bodies[row.key] = texts[n] ?? "" }
        }
        let keys = Set(rows.map(\.key))
        bodies = bodies.filter { keys.contains($0.key) }
        for index in rows.indices { rows[index].body = bodies[rows[index].key] ?? "" }
        recent = rows
        loadedAt = Date()

        let unread = rows.filter { !$0.read }
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

    /// Recent inbox mail from memory, refreshed first only when it is stale.
    func inbox(days: Int, unansweredOnly: Bool) async throws -> String {
        try await Self.ensureRunning()
        if !isFresh { await refresh() }
        if case .error(let message) = status.state { throw NookError(message) }
        let rows = MailStats.select(recent, now: Date(), days: days, unansweredOnly: unansweredOnly)
        guard !rows.isEmpty else {
            return "Geen mail in de inbox van de laatste \(days) dagen" + (unansweredOnly ? " waarop je nog niet antwoordde." : ".")
        }
        return MailStats.describe(rows, date: NookDates.iso)
    }

    nonisolated static func name(_ sender: String) -> String {
        // "Lisa de Vries <lisa@…>" → "Lisa de Vries"
        if let range = sender.range(of: " <") { return String(sender[..<range.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return sender
    }

    func contextLines() -> [String] {
        guard status.state == .ok else { return [] }
        var lines = [unreadCount == 0 ? "Mail: geen ongelezen mail in de inbox."
                     : "Mail: \(unreadCount) ongelezen in de inbox (per dag, account of afzender: mail_unread)."]
        // What still needs a reply goes along in full, so "which mail do I need to answer" needs no lookup at all.
        let waiting = MailStats.select(recent, now: Date(), days: 14, unansweredOnly: true, limit: 10)
        if !waiting.isEmpty {
            lines.append("Mail die nog een antwoord kan gebruiken (laatste 14 dagen, nog niet beantwoord, geen automatische mail):")
            for row in waiting {
                let snippet = row.body.replacingOccurrences(of: "\n", with: " ").prefix(160)
                lines.append("- \(row.subject) | van \(row.sender) | \(NookDates.iso(row.date)) | \(row.read ? "gelezen" : "ongelezen")"
                             + (snippet.isEmpty ? "" : " | \"\(snippet)\""))
            }
        }
        let unread = recent.filter { !$0.read && !waiting.contains($0) }.prefix(8)
        if !unread.isEmpty {
            lines.append("Andere nieuwste ongelezen:")
            for row in unread { lines.append("- \(row.subject) | van \(row.sender) | \(NookDates.iso(row.date))") }
        }
        return lines
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "mail_unread",
                description: "Counts unread mail in the inbox of the Mail app, freshly fetched: total, per account, per day received (the last 14 days) and senders with the most unread mail. Use this for questions like 'how many unread emails do I have' and for an unread mail chart.",
                schema: ["type": "object", "properties": [String: Any]()],
                kind: .read,
                summarize: { _ in "Count unread mail" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    try await MailConnector.ensureRunning()
                    let result = await ScriptText.run(MailStats.unreadScript)
                    if result.errorNumber == -1743 {
                        throw NookError("Grant Nook permission to read Mail: System Settings › Privacy & Security › Automation.")
                    }
                    guard let raw = result.text else { throw NookError("Mail did not respond.") }
                    return MailStats.unread(raw, now: Date())
                }
            ),
            ToolSpec(
                name: "inbox_mail",
                description: "Returns recent mail in the inbox of the Mail app (newest first): subject, sender, date, whether it is read, whether the user already replied, and the start of the body text, with a link per message. Use this for questions like 'which emails do I still need to reply to', 'what arrived today', or 'did I miss anything important'. Judge for yourself which emails need a reply: real people with a question or request, not yet replied to; newsletters, notifications, and spam do not.",
                schema: ["type": "object", "properties": [
                    "days": ["type": "integer", "description": "How many days back (default 7, at most 30)."],
                    "unanswered_only": ["type": "boolean", "description": "Only mail to which the user has not replied yet (default false)."] as [String: Any]
                ]],
                kind: .read,
                summarize: { _ in "Read inbox" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Mail is niet beschikbaar.") }
                    let days = min(30, max(1, (input["days"] as? Int) ?? Int((input["days"] as? Double) ?? 7)))
                    let unanswered = (input["unanswered_only"] as? Bool) ?? false
                    return try await self.inbox(days: days, unansweredOnly: unanswered)
                }
            ),
            ToolSpec(
                name: "search_mail",
                description: "Searches the Mail app by subject or sender (inbox) or by subject or recipient (sent) and returns the best matches with the start of the text, an id and a link to the message. Give one or more separate keywords (a name, a topic), not a sentence: messages matching the most keywords come first. Use this for questions like 'what did Lisa write about the proposal'. Use mailbox sent to find what the user wrote or promised. To read a whole message, call read_mail with its id.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "One or more keywords, separated by spaces: words in the subject, or (part of) the sender or recipient."],
                    "mailbox": ["type": "string", "enum": ["inbox", "sent"], "description": "inbox (default) or sent."] as [String: Any]
                ], "required": ["query"]],
                kind: .read,
                summarize: { _ in "Search mail" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    try await MailConnector.ensureRunning()
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Search query is missing.") }
                    let sent = (input["mailbox"] as? String)?.lowercased() == "sent"
                    // Every word on its own ("lisa offerte" finds Lisa's mail about the offerte), ranked by how many match.
                    let words = Research.words(of: query).isEmpty ? [query] : Research.words(of: query)
                    let scriptWords = Array(words.sorted { $0.count > $1.count }.prefix(4))
                    let filter = scriptWords.map { word -> String in
                        let q = ScriptText.quote(word)
                        return sent ? "subject contains \(q)" : "subject contains \(q) or sender contains \(q)"
                    }.joined(separator: " or ")

                    // Searching the unified `inbox` with `whose` on large accounts can take >20s in Apple Mail.
                    // Searching each account's INBOX mailbox directly (bounded to recent 600 messages per mailbox) is ~10x faster.
                    let script: String
                    if sent {
                        script = """
                        tell application "Mail"
                            set total to count of messages of sent mailbox
                            if total is 0 then return ""
                            if total > 600 then
                                set found to (messages 1 thru 600 of sent mailbox whose \(filter))
                            else
                                set found to (messages of sent mailbox whose \(filter))
                            end if
                            set n to count of found
                            if n > 18 then set n to 18
                            set out to ""
                            repeat with i from 1 to n
                                set m to item i of found
                                set body to ""
                                try
                                    set body to content of m
                                end try
                                if (length of body) > 12000 then set body to text 1 thru 12000 of body
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
                    } else {
                        script = """
                        tell application "Mail"
                            set found to {}
                            repeat with acc in accounts
                                repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                                    set total to count of messages of box
                                    if total > 0 then
                                        if total > 600 then
                                            set hits to (messages 1 thru 600 of box whose \(filter))
                                        else
                                            set hits to (messages of box whose \(filter))
                                        end if
                                        repeat with h in hits
                                            if (count of found) >= 20 then exit repeat
                                            set end of found to contents of h
                                        end repeat
                                    end if
                                end repeat
                            end repeat
                            set n to count of found
                            if n > 18 then set n to 18
                            set out to ""
                            repeat with i from 1 to n
                                set m to item i of found
                                set body to ""
                                try
                                    set body to content of m
                                end try
                                if (length of body) > 12000 then set body to text 1 thru 12000 of body
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
                    }
                    let result = await ScriptText.run(script, timeout: 8)
                    if result.errorNumber == -1743 {
                        throw NookError("Grant Nook permission to read Mail: System Settings › Privacy & Security › Automation.")
                    }
                    if result.errorNumber == -1712 { throw NookError("Searching Mail took too long. Try a more specific keyword.") }
                    let raw = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return "No mail found for \"\(query)\"" + (sent ? " in sent." : ".") }
                    let now = Date()
                    var snippetChunks: [String] = []
                    for chunk in raw.components(separatedBy: "<<<MSG>>>") where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                        let headerLine = String(lines.first ?? "")
                        let header = headerLine.components(separatedBy: "|||")
                        let fullBody = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                        if header.count >= 5 {
                            let mid = header[4].trimmingCharacters(in: CharacterSet(charactersIn: "<> \n"))
                            if !mid.isEmpty {
                                MailConnector.messageCache[mid] = CachedMail(
                                    subject: header[0], sender: header[1], recipients: header[2],
                                    date: header[3], body: fullBody, cachedAt: now
                                )
                            }
                        }
                        let shortBody = fullBody.count > 700 ? String(fullBody.prefix(700)) : fullBody
                        snippetChunks.append(headerLine + "\n" + shortBody + "\n")
                    }
                    let ranked = Research.best(snippetChunks, terms: Research.Terms(words: words), keep: 8,
                                               title: { chunk in String(chunk.prefix { $0 != "\n" }) }, text: { $0 })
                    return MailConnector.format(ranked.map { "<<<MSG>>>" + $0 }.joined(), sent: sent)
                }
            ),
            ToolSpec(
                name: "read_mail",
                description: "Reads one whole message from the Mail app (inbox or sent): subject, sender, recipients, date and the full text. Give the id from search_mail. Use this when the start of a message is not enough to answer.",
                schema: ["type": "object", "properties": [
                    "id": ["type": "string", "description": "The message id from search_mail (the part after \"id:\")."]
                ], "required": ["id"]],
                kind: .read,
                summarize: { _ in "Read mail" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let id = ((input["id"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> \n"))
                    guard !id.isEmpty else { throw NookError("The message id is missing.") }

                    // Fast path: 0ms in-memory hit if already fetched during search_mail (<120s old).
                    if let cached = MailConnector.messageCache[id], Date().timeIntervalSince(cached.cachedAt) < 120 {
                        var body = cached.body
                        if body.count > 12_000 { body = String(body.prefix(12_000)) + "\n… (truncated: the first 12,000 characters)" }
                        let to = cached.recipients.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                        return "## \(cached.subject)\nFrom: \(cached.sender)\nTo: \(to)\nDate: \(cached.date)\n\n\(body)\n"
                            + ReferenceParser.line(title: cached.subject.isEmpty ? "(no subject)" : cached.subject, url: MailConnector.messageLink(id),
                                                   detail: "\(MailConnector.name(cached.sender)) · \(String(cached.date.prefix(10)))")
                    }

                    try await MailConnector.ensureRunning()
                    let q = ScriptText.quote(id)
                    let script = """
                    tell application "Mail"
                        set m to missing value
                        repeat with acc in accounts
                            repeat with box in (mailboxes of acc whose name is "INBOX" or name is "Inbox")
                                try
                                    set m to first message of box whose message id is \(q)
                                    if m is not missing value then exit repeat
                                end try
                            end repeat
                            if m is not missing value then exit repeat
                        end repeat
                        if m is missing value then
                            try
                                set m to first message of inbox whose message id is \(q)
                            end try
                        end if
                        if m is missing value then
                            try
                                set m to first message of sent mailbox whose message id is \(q)
                            end try
                        end if
                        if m is missing value then return "NOT_FOUND"
                        set rcpts to ""
                        try
                            repeat with r in to recipients of m
                                set rcpts to rcpts & (address of r) & ", "
                            end repeat
                        end try
                        set body to ""
                        try
                            set body to content of m
                        end try
                        return (subject of m) & "|||" & (sender of m) & "|||" & rcpts & "|||" & ((date received of m) as «class isot» as string) & linefeed & body
                    end tell
                    """
                    let result = await ScriptText.run(script, timeout: 8)
                    if result.errorNumber == -1743 {
                        throw NookError("Grant Nook permission to read Mail: System Settings › Privacy & Security › Automation.")
                    }
                    guard let raw = result.text, raw != "NOT_FOUND" else { throw NookError("Message not found in Mail.") }
                    let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let header = String(parts.first ?? "").components(separatedBy: "|||")
                    guard header.count >= 4 else { throw NookError("Mail gave no readable message.") }
                    var body = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if body.count > 12_000 { body = String(body.prefix(12_000)) + "\n… (truncated: the first 12,000 characters)" }
                    let to = header[2].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                    MailConnector.messageCache[id] = CachedMail(
                        subject: header[0], sender: header[1], recipients: to, date: header[3], body: body, cachedAt: Date()
                    )
                    return "## \(header[0])\nFrom: \(header[1])\nTo: \(to)\nDate: \(header[3])\n\n\(body)\n"
                        + ReferenceParser.line(title: header[0].isEmpty ? "(no subject)" : header[0], url: MailConnector.messageLink(id),
                                               detail: "\(MailConnector.name(header[1])) · \(String(header[3].prefix(10)))")
                }
            )
        ]
    }

    /// Formats matches to be readable for the brain, with a reference per message (a message: link opens it in Mail).
    /// `status`: the recipient slot holds the status (read, replied) instead, for inbox_mail.
    nonisolated static func format(_ raw: String, sent: Bool, status: Bool = false) -> String {
        var blocks: [String] = []
        var refs: [String] = []
        for chunk in raw.components(separatedBy: "<<<MSG>>>") where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let header = String(lines.first ?? "").components(separatedBy: "|||")
            guard header.count >= 5 else { continue }
            let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let who = sent ? "to \(header[2])" : "from \(header[1])"
            let state = status && !header[2].isEmpty ? " | \(header[2])" : ""
            let id = header[4].trimmingCharacters(in: CharacterSet(charactersIn: "<> \n"))
            blocks.append("### \(header[0]) | \(who) | \(header[3])\(state)\(id.isEmpty ? "" : " [id: \(id)]")\n\(body)")
            refs.append(ReferenceParser.line(title: header[0].isEmpty ? "(no subject)" : header[0], url: messageLink(header[4]),
                                             detail: "\(sent ? header[2] : name(header[1])) · \(String(header[3].prefix(10)))"))
        }
        return (blocks + refs).joined(separator: "\n\n")
    }

    /// message:%3C…%3E opens the message in Mail. Only with a valid message id, otherwise no link.
    nonisolated static func messageLink(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n"))
        guard !trimmed.isEmpty, trimmed.contains("@"),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) else { return nil }
        return "message:%3C\(encoded)%3E"
    }
}

// MARK: - Browser

/// Open tabs in Safari and Chromium browsers (Chrome, Arc, Brave, Edge). Only browsers that are already running.
@MainActor
final class BrowserConnector: ContextSource {
    struct Tab: Equatable, Sendable {
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
        let runningBrowsers = Self.browsers.filter { ScriptText.isRunning($0.bundle) }
        guard !runningBrowsers.isEmpty else {
            tabs = []
            return
        }

        let results = await withTaskGroup(of: (Int, [Tab], Bool).self) { group in
            for (index, browser) in runningBrowsers.enumerated() {
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
                let browserName = browser.name
                group.addTask {
                    let result = await ScriptText.run(script, timeout: 3.0)
                    let isDenied = result.errorNumber == -1743
                    var found: [Tab] = []
                    for line in (result.text ?? "").components(separatedBy: .newlines) {
                        let parts = line.components(separatedBy: "|||")
                        guard parts.count >= 3, parts[2].hasPrefix("http") else { continue }
                        found.append(Tab(browser: browserName, title: parts[1], url: parts[2], active: parts[0] == "1"))
                    }
                    return (index, found, isDenied)
                }
            }
            var gathered: [(Int, [Tab], Bool)] = []
            for await item in group { gathered.append(item) }
            return gathered.sorted { $0.0 < $1.0 }
        }

        let collected = results.flatMap(\.1)
        let denied = results.contains { $0.2 }
        tabs = collected
        if collected.isEmpty && denied {
            status = ConnectorStatus(state: .error("Grant Nook permission for your browser: System Settings › Privacy & Security › Automation."))
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

    var canLookUp: Bool { ConnectorToggle.isOn(id) }

    func contextLines() -> [String] {
        guard !tabs.isEmpty else { return [] }
        var lines = ["Open browser tabs (* = active tab of a window):"]
        for tab in tabs.sorted(by: { $0.active && !$1.active }).prefix(20) {
            lines.append("- \(tab.active ? "* " : "")\(tab.title) | \(tab.url)")
        }
        return lines
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "read_browser_tab",
                description: "Leest de tekst van het huidige actieve tabblad (of een specifiek tabblad) in Safari, Google Chrome, Microsoft Edge of Arc. Gebruik dit wanneer de gebruiker vraagt wat er op het scherm/tabblad in de browser staat, of om een webpagina die open staat samen te vatten.",
                schema: ["type": "object", "properties": [
                    "browser": ["type": "string", "description": "Optionele browsernaam (Safari, Google Chrome, Microsoft Edge, Arc). Indien leeg, pakt hij de actieve browser."] as [String: Any]
                ]],
                kind: .read,
                summarize: { _ in "Browsertabblad lezen" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let targetBrowser = (input["browser"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    var scripts: [(name: String, bundle: String, script: String)] = []

                    if targetBrowser == nil || targetBrowser?.lowercased().contains("safari") == true {
                        if ScriptText.isRunning("com.apple.Safari") {
                            scripts.append(("Safari", "com.apple.Safari", """
                            tell application "Safari"
                                if (count of documents) > 0 then
                                    set doc to front document
                                    set docTitle to name of doc
                                    set docURL to URL of doc
                                    set docText to text of doc
                                    if (length of docText) > 12000 then set docText to text 1 thru 12000 of docText
                                    return docTitle & "|||" & docURL & linefeed & docText
                                end if
                            end tell
                            """))
                        }
                    }
                    if targetBrowser == nil || targetBrowser?.lowercased().contains("chrome") == true {
                        if ScriptText.isRunning("com.google.Chrome") {
                            scripts.append(("Google Chrome", "com.google.Chrome", """
                            tell application "Google Chrome"
                                if (count of windows) > 0 then
                                    set tab to active tab of front window
                                    set docTitle to title of tab
                                    set docURL to URL of tab
                                    set docText to execute front window's active tab javascript "document.body.innerText"
                                    if (length of docText) > 12000 then set docText to text 1 thru 12000 of docText
                                    return docTitle & "|||" & docURL & linefeed & docText
                                end if
                            end tell
                            """))
                        }
                    }
                    if targetBrowser == nil || targetBrowser?.lowercased().contains("edge") == true {
                        if ScriptText.isRunning("com.microsoft.edgemac") {
                            scripts.append(("Microsoft Edge", "com.microsoft.edgemac", """
                            tell application "Microsoft Edge"
                                if (count of windows) > 0 then
                                    set tab to active tab of front window
                                    set docTitle to title of tab
                                    set docURL to URL of tab
                                    set docText to execute front window's active tab javascript "document.body.innerText"
                                    if (length of docText) > 12000 then set docText to text 1 thru 12000 of docText
                                    return docTitle & "|||" & docURL & linefeed & docText
                                end if
                            end tell
                            """))
                        }
                    }
                    if targetBrowser == nil || targetBrowser?.lowercased().contains("brave") == true {
                        if ScriptText.isRunning("com.brave.Browser") {
                            scripts.append(("Brave Browser", "com.brave.Browser", """
                            tell application "Brave Browser"
                                if (count of windows) > 0 then
                                    set tab to active tab of front window
                                    set docTitle to title of tab
                                    set docURL to URL of tab
                                    set docText to execute front window's active tab javascript "document.body.innerText"
                                    if (length of docText) > 12000 then set docText to text 1 thru 12000 of docText
                                    return docTitle & "|||" & docURL & linefeed & docText
                                end if
                            end tell
                            """))
                        }
                    }
                    if targetBrowser == nil || targetBrowser?.lowercased().contains("arc") == true {
                        if ScriptText.isRunning("company.thebrowser.Browser") {
                            scripts.append(("Arc", "company.thebrowser.Browser", """
                            tell application "Arc"
                                if (count of windows) > 0 then
                                    set tab to active tab of front window
                                    set docTitle to title of tab
                                    set docURL to URL of tab
                                    return docTitle & "|||" & docURL
                                end if
                            end tell
                            """))
                        }
                    }

                    // Prioritize the frontmost browser if one is currently active on screen.
                    if let frontBundle, let idx = scripts.firstIndex(where: { $0.bundle == frontBundle }), idx > 0 {
                        let front = scripts.remove(at: idx)
                        scripts.insert(front, at: 0)
                    }

                    for (browserName, _, script) in scripts {
                        let result = await ScriptText.run(script, timeout: 3.0)
                        if let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                            let header = String(lines.first ?? "").components(separatedBy: "|||")
                            let body = lines.count > 1 ? String(lines[1]) : ""
                            let title = header.first ?? "Webpagina"
                            let url = header.count > 1 ? header[1] : ""
                            return "## \(title) (\(browserName))\nBron: \(url)\n\n\(body)\n\n" + ReferenceParser.line(title: title, url: url.isEmpty ? nil : url, detail: browserName)
                        }
                    }
                    return "Geen geopende webpagina met tekst gevonden in Safari, Chrome of Edge."
                }
            )
        ]
    }
}

// MARK: - Files

/// Reads text from standard documents. Shared by the Shelf and file tools.
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
            throw NookError("I cannot read text from \(url.lastPathComponent). Plain text, PDF, Word, and RTF work.")
        }
        return text
    }

    /// Only files in your own home folder, not in hidden folders or Library (keys, passwords, settings).
    static func isAllowed(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(home + "/") else { return false }
        let relative = path.dropFirst(home.count + 1)
        let parts = relative.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts.first == "Library" { return false }
        return !isSensitive(url)
    }

    /// Keys, certificates, keychains and password exports are never read, wherever they are.
    static let sensitiveExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "p8", "keychain", "keychain-db", "kdbx", "kdb", "1pux", "1pif", "agilekeychain",
        "opvault", "psafe3", "gpg", "asc", "ovpn", "mobileprovision", "cer", "der", "crt", "jks", "keystore"
    ]

    static func isSensitive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if sensitiveExtensions.contains(ext) { return true }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let patterns = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "credentials", "passwords", "wachtwoorden", "recovery-codes", "recovery codes", "seed phrase", "secret"]
        return patterns.contains { name.contains($0) } && ["", "txt", "csv", "json", "md", "rtf"].contains(ext)
    }

    /// Opening these would run something (apps, scripts, installers, automations) instead of showing it.
    static func couldExecute(_ url: URL) -> Bool {
        let risky: Set<String> = [
            "app", "command", "sh", "zsh", "bash", "tool", "terminal", "pkg", "mpkg", "dmg", "scpt", "scptd", "applescript",
            "workflow", "shortcut", "jar", "py", "rb", "pl", "js", "action", "prefpane", "saver", "webloc", "inetloc", "fileloc", "url"
        ]
        if risky.contains(url.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
           FileManager.default.isExecutableFile(atPath: url.path) {
            return true
        }
        return isDirectory.boolValue && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}

/// Recently used files (Spotlight) and searching your files.
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

    private nonisolated static func spotlight(_ arguments: [String], maxLines: Int = 350) async -> [URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let output = (try? SystemControl.runProcess("/usr/bin/mdfind", ["-onlyin", home] + arguments, timeout: 5.0)) ?? ""
                var urls: [URL] = []
                urls.reserveCapacity(min(maxLines, 64))
                for line in output.split(whereSeparator: \.isNewline) {
                    urls.append(URL(fileURLWithPath: String(line)))
                    if urls.count >= maxLines { break }
                }
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
        return ["Recently used files:"] + recent.prefix(10).map { "- " + $0.path.replacingOccurrences(of: home, with: "~") }
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_files",
                description: "Searches the user's files using Spotlight (name and content) and returns paths of the best matches.",
                schema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search terms."]], "required": ["query"]],
                kind: .read,
                summarize: { _ in "Search files" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Search query is missing.") }
                    async let byNameTask = FilesConnector.spotlight(["-name", query], maxLines: 120)
                    async let byContentTask = FilesConnector.spotlight([query], maxLines: 120)
                    let (byName, byContent) = await (byNameTask, byContentTask)
                    var seen = Set<String>()
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    var hits = Array((byName + byContent).filter { FileText.isAllowed($0) && seen.insert($0.path).inserted }.prefix(20))
                    // Spotlight wants every word; when that finds nothing, look per word in parallel and keep the files most words hit.
                    let words = Research.words(of: query)
                    if hits.isEmpty, words.count > 1 {
                        let wordList = Array(words.prefix(4))
                        let perWordResults = await withTaskGroup(of: (Int, [URL]).self) { group in
                            for (idx, word) in wordList.enumerated() {
                                group.addTask {
                                    let urls = await FilesConnector.spotlight([word], maxLines: 100)
                                    return (idx, urls)
                                }
                            }
                            var collected: [(Int, [URL])] = []
                            for await res in group { collected.append(res) }
                            return collected.sorted { $0.0 < $1.0 }
                        }
                        var counts: [String: (url: URL, count: Int, first: Int)] = [:]
                        var order = 0
                        for (_, urls) in perWordResults {
                            for url in urls.prefix(60) where FileText.isAllowed(url) {
                                order += 1
                                let entry = counts[url.path] ?? (url, 0, order)
                                counts[url.path] = (entry.url, entry.count + 1, entry.first)
                            }
                        }
                        hits = counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }.prefix(15).map(\.url)
                    }
                    // Documents first, code after them, build output never: a word in a bundled script is no answer.
                    let codeQuery = query.range(of: #"\b(code|func\w*|class|script|swift|python|javascript|typescript|api|bug|repo)\b"#,
                                                options: [.regularExpression, .caseInsensitive]) != nil
                    let order = Research.rankFiles(hits.map(\.path), codeFirst: codeQuery)
                    hits = order.compactMap { path in hits.first { $0.path == path } }
                    if hits.isEmpty { return "Nothing found for \"\(query)\"." }
                    let paths = hits.map { $0.path.replacingOccurrences(of: home, with: "~") }
                    let refs = hits.prefix(8).map {
                        ReferenceParser.line(title: $0.lastPathComponent, url: $0.absoluteString, detail: $0.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~"))
                    }
                    return (paths + refs).joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "read_file",
                description: "Reads the text of a user document (plain text, PDF, Word, RTF). Provide a path from search_files or from the recent files list.",
                schema: ["type": "object", "properties": ["path": ["type": "string", "description": "Path, may start with ~."]], "required": ["path"]],
                kind: .read,
                summarize: { _ in "Read file" },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let raw = ((input["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                    guard FileText.isAllowed(url) else { throw NookError("Nook is not allowed to read that file.") }
                    let text = try FileText.read(url)
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { "modified \(NookDates.short($0))" } ?? ""
                    var output = String(text.prefix(15_000))
                    if text.count > 15_000 { output += "\n… (truncated: the first 15,000 characters of \(text.count))" }
                    return output + "\n" + ReferenceParser.line(title: url.lastPathComponent, url: url.absoluteString, detail: modified)
                }
            )
        ]
    }
}

// MARK: - Clipboard

/// What you just copied. Off by default: a clipboard can be sensitive. Passwords (marked as concealed/transient) are always skipped by Nook.
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
        return ["Clipboard (recently copied):", String(text.prefix(1500))]
    }
}
