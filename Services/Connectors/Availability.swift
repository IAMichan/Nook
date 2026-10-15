import Foundation

// Single unified view across all calendars: Apple Calendar (with everything inside it, including Google and Outlook accounts from macOS),
// calendars via an ICS URL, and Cal.com. This enables Nook to answer questions like "am I available on October 13?" without
// requiring the user to specify which calendar to inspect.

struct AgendaEntry: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool = false
    /// False if the event is marked as "free" / "available".
    var busy: Bool = true
    var location: String = ""
    /// Name of the originating calendar.
    var calendar: String
}

struct AgendaResult {
    var entries: [AgendaEntry]
    /// Non-fatal issues encountered during fetching, presented to user.
    var problems: [String] = []
}

/// A source providing events for availability checking.
@MainActor
protocol AgendaSource: ContextSource {
    /// What is being inspected, e.g. "Work (Google)".
    func agendaNames() -> [String]
    /// Freshly fetched events overlapping the time range.
    func agendaEntries(from: Date, to: Date) async throws -> AgendaResult
}

extension ConnectorHub {
    var agendaSources: [AgendaSource] { sources.compactMap { $0 as? AgendaSource } }

    /// Hub-level tools: inspect across all sources.
    var hubTools: [ToolSpec] {
        [
            ToolSpec(
                name: "check_availability",
                description: "Checks ALL calendars of the user simultaneously (Apple Calendar and its connected accounts, calendars via an ICS URL such as Google or Outlook, Cal.com) and returns busy intervals and free time per day. Use this IMMEDIATELY for any question like \"am I available on October 13?\", \"when do I have time?\", or \"does Tuesday 2 PM work?\", even if the period is mentioned in context. Provide from and to (ISO 8601); for a single full day, from as a date (e.g. 2027-10-13) suffices. Mention in your response which calendars were checked.",
                schema: [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string", "description": "Start, ISO 8601. Date only (2027-10-13) covers the entire day."],
                        "to": ["type": "string", "description": "End, ISO 8601. Omit for a single full day. At most 14 days after from."]
                    ],
                    "required": ["from"]
                ],
                kind: .read,
                summarize: { _ in "Checking all calendars" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Integrations are not available.") }
                    guard let fromText = (input["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let from = NookDates.parse(fromText) else {
                        throw NookError("from must be a date or ISO 8601 string.")
                    }
                    let calendar = Calendar.current
                    var to = (input["to"] as? String).flatMap { NookDates.parse($0) }
                    if let end = to, (input["to"] as? String)?.count == 10 {
                        // "to" as date only: that entire day is included.
                        to = calendar.date(byAdding: .day, value: 1, to: end)
                    }
                    let end = to ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)) ?? from.addingTimeInterval(86_400)
                    guard end > from else { throw NookError("to must be after from.") }
                    return try await self.availability(from: from, to: min(end, from.addingTimeInterval(14 * 86_400)))
                }
            ),
            ToolSpec(
                name: "list_sources",
                description: "Shows which sources Nook currently knows (calendars, mail, services, custom sources), which are active, and which are not yet connected. Use this when the user asks about an app or service with no data visible, so you can ask which app they use and explain how to connect it.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in "Viewing sources" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self else { throw NookError("Integrations are not available.") }
                    return self.sourceOverview()
                }
            )
        ]
    }

    /// Context prompt line: which calendars Nook checks for availability queries.
    var agendaCoverageLine: String? {
        let names = agendaSources.filter { $0.isActive }.flatMap { $0.agendaNames() }
        guard !names.isEmpty else { return nil }
        return "Calendars checked by check_availability: " + names.joined(separator: "; ") + "."
    }

    func sourceOverview() -> String {
        var lines: [String] = []
        let on = sources.filter { $0.isActive }
        let off = sources.filter { !$0.isActive }
        if !on.isEmpty {
            lines.append("Enabled:")
            for source in on {
                let headline = source.status.headline
                lines.append("- \(source.title)" + (headline.isEmpty ? "" : ": \(headline)"))
            }
        }
        if !off.isEmpty {
            lines.append("Not yet connected or disabled: " + off.map { $0.title }.joined(separator: ", ") + ".")
        }
        lines.append("You can connect services in Settings › Integrations: a calendar via its ICS URL (Google Calendar, Outlook, iCloud…) under Other calendars; almost any other app or service with a web API under Custom sources (read-only). An app without an API can be invoked via Shortcuts (run_shortcut).")
        lines.append("Ask the user which app they mean if it is not listed here, and explain the easiest way to connect it.")
        return lines.joined(separator: "\n")
    }

    // MARK: Availability

    /// Standard working hours for free slots, unless the user requested a shorter window.
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
        lines.append("Period: \(NookDates.long(from)) to \(NookDates.long(to))")
        lines.append(checked.isEmpty ? "Checked: none (no calendar connected or access not granted)." : "Checked: " + checked.joined(separator: "; ") + ".")
        if !problems.isEmpty { lines.append("Could not read: " + problems.joined(separator: "; ") + ".") }
        if !skipped.isEmpty { lines.append("Not checked (disabled or no access): " + skipped.joined(separator: ", ") + ".") }

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
            if today.isEmpty { lines.append("- no events in the checked calendars") }
            for entry in timed.prefix(30) {
                let place = entry.location.isEmpty ? "" : " | \(CloudHelp.short(entry.location, 40))"
                lines.append("- busy \(NookDates.time(max(entry.start, day)))–\(NookDates.time(min(entry.end, next))) \(CloudHelp.short(entry.title)) [\(entry.calendar)]\(place)")
            }
            for entry in allDay.prefix(10) {
                lines.append("- all day: \(CloudHelp.short(entry.title)) [\(entry.calendar)] (does not block automatically, judge for yourself)")
            }
            for entry in marked.prefix(10) {
                lines.append("- marked as available: \(NookDates.time(entry.start)) \(CloudHelp.short(entry.title)) [\(entry.calendar)]")
            }

            let windowStart = wholeDays
                ? max(calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: day) ?? day, from)
                : max(from, day)
            let windowEnd = wholeDays
                ? min(calendar.date(bySettingHour: Self.dayEndHour, minute: 0, second: 0, of: day) ?? next, to)
                : min(to, next)
            if windowEnd > windowStart {
                let free = Self.freeSlots(busy: timed, from: windowStart, to: windowEnd)
                let label = wholeDays ? "free (\(NookDates.time(windowStart))–\(NookDates.time(windowEnd)))" : "free"
                lines.append("- \(label): " + (free.isEmpty ? "none" : free.map { "\(NookDates.time($0.0))–\(NookDates.time($0.1))" }.joined(separator: ", ")))
            }
            day = next
        }

        lines.append("")
        lines.append(hasFeeds
            ? "Is another calendar or app missing? Ask the user which one they use."
            : "Note: this is everything Nook can access. Does the user also use another calendar (Google Calendar, Outlook, work calendar) not in the list above? Ask which one, and explain they can connect it under Settings › Integrations › Other calendars using its ICS URL.")
        return lines.joined(separator: "\n")
    }

    /// Gaps between events within the window, 15 minutes or longer.
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
