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
                name: "find_time",
                description: "Finds concrete free times for a meeting, call or block of work across ALL of the user's calendars (the same ones check_availability reads), and returns ready options with exact ISO start and end. Use this whenever the user wants to plan, schedule or move something (\"plan een uur met Jan volgende week\", \"when can I fit in two hours for the report?\", \"find a time for lunch with Sara\", \"plan my afternoon\"), instead of working out gaps yourself. Offer the options to the user (or, when they asked you to just plan it, pick the first) and use its start and end in create_event; to invite other people, add invite to compose_mail.",
                schema: [
                    "type": "object",
                    "properties": [
                        "duration_minutes": ["type": "number", "description": "How long it takes, in minutes. Default 60."],
                        "from": ["type": "string", "description": "Earliest moment, ISO 8601 (a date alone is the start of that day). Default: now."],
                        "to": ["type": "string", "description": "Latest moment, ISO 8601 (a date alone includes that whole day). Default: seven days after from. At most 31 days."],
                        "count": ["type": "number", "description": "How many options. Default 3, at most 10."],
                        "day_start": ["type": "string", "description": "Earliest time of day, \"HH:MM\". Default 09:00 (or what the user said: \"in the evening\" is 18:00)."],
                        "day_end": ["type": "string", "description": "Latest end time of day, \"HH:MM\". Default 18:00."],
                        "prefer": ["type": "string", "enum": ["any", "morning", "afternoon", "evening"], "description": "Part of the day to try first. Default any."],
                        "buffer_minutes": ["type": "number", "description": "Free minutes kept before and after other appointments (travel, a breather). Default 0; 15 to 30 for a meeting somewhere else."],
                        "weekends": ["type": "boolean", "description": "Also Saturday and Sunday. Default false, unless the user names a weekend day or a private plan."]
                    ],
                    "required": [String]()
                ],
                kind: .read,
                summarize: { _ in "Finding a time in all calendars" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError("Integrations are not available.") }
                    return try await self.findTime(input)
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

    /// Every active calendar's events in the range, which calendars were read and what could not be.
    private func gatherAgenda(from: Date, to: Date) async -> (checked: [String], entries: [AgendaEntry], problems: [String]) {
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
        return (checked, entries, problems)
    }

    func availability(from: Date, to: Date) async throws -> String {
        let calendar = Calendar.current
        let (checked, entries, problems) = await gatherAgenda(from: from, to: to)
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

    // MARK: Finding a time

    func findTime(_ input: [String: Any], now: Date = Date()) async throws -> String {
        let calendar = Calendar.current
        func number(_ key: String) -> Double? {
            if let value = input[key] as? Double { return value }
            if let value = input[key] as? Int { return Double(value) }
            return (input[key] as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let fromText = (input["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let toText = (input["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let from = max(NookDates.parse(fromText) ?? now, calendar.startOfDay(for: now))
        var to = NookDates.parse(toText) ?? (calendar.date(byAdding: .day, value: 7, to: from) ?? from.addingTimeInterval(7 * 86_400))
        if toText.count == 10, let next = calendar.date(byAdding: .day, value: 1, to: to) { to = next }
        to = min(to, from.addingTimeInterval(TimeInterval(MeetingTimes.maxDays) * 86_400))
        guard to > from else { throw NookError("to must be after from.") }

        let minutes = min(max(number("duration_minutes") ?? 60, 5), 12 * 60)
        var request = MeetingTimes.Request(from: from, to: to, duration: minutes * 60)
        request.count = Int(number("count") ?? 3)
        request.dayStart = MeetingTimes.minutes(input["day_start"] as? String) ?? request.dayStart
        request.dayEnd = MeetingTimes.minutes(input["day_end"] as? String) ?? request.dayEnd
        if request.dayEnd <= request.dayStart { request.dayEnd = min(request.dayStart + Int(minutes), 24 * 60) }
        request.buffer = min(max(number("buffer_minutes") ?? 0, 0), 120) * 60
        request.weekends = (input["weekends"] as? Bool) ?? ((input["weekends"] as? String) == "true")
        request.preference = MeetingTimes.Preference(text: input["prefer"] as? String)

        let (checked, entries, problems) = await gatherAgenda(from: from.addingTimeInterval(-request.buffer), to: to.addingTimeInterval(request.buffer))
        // All-day items and events marked "free" do not block, as in check_availability.
        let busy = entries.filter { !$0.allDay && $0.busy }.map { MeetingTimes.Busy(start: $0.start, end: $0.end) }
        let slots = MeetingTimes.find(request, busy: busy, now: now, calendar: calendar)

        func clock(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
        var lines: [String] = []
        lines.append("Looking for \(Int(minutes)) minutes between \(NookDates.long(from)) and \(NookDates.long(to)), \(clock(request.dayStart))–\(clock(request.dayEnd))"
            + (request.weekends ? "" : ", weekdays only") + (request.buffer > 0 ? ", \(Int(request.buffer / 60)) minutes buffer around other appointments" : "")
            + (request.preference == .any ? "" : ", \(request.preference.rawValue) first") + ".")
        lines.append(checked.isEmpty ? "Checked: none (no calendar connected or access not granted): these times are not checked against anything." : "Checked: " + checked.joined(separator: "; ") + ".")
        if !problems.isEmpty { lines.append("Could not read: " + problems.joined(separator: "; ") + ".") }
        if slots.isEmpty {
            lines.append("No free time of that length in this window. Offer a longer period, other hours, the weekend or a shorter duration.")
        } else {
            lines.append("Options:")
            for (index, slot) in slots.enumerated() {
                lines.append("\(index + 1). \(NookDates.day(slot.start)) \(NookDates.time(slot.start))–\(NookDates.time(slot.end)) | start \(NookDates.iso(slot.start)) | end \(NookDates.iso(slot.end))")
            }
            let allDay = entries.filter(\.allDay)
            if !allDay.isEmpty {
                lines.append("All-day items in this period (they do not block, judge for yourself): "
                    + allDay.prefix(6).map { "\(NookDates.day($0.start)) \(CloudHelp.short($0.title))" }.joined(separator: "; ") + ".")
            }
            lines.append("Give the options as a short list the user can pick from (or take the first when they asked you to just plan it). For the chosen one: create_event with its start and end; when other people come, compose_mail to them with invite, so they get a real invitation.")
        }
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
