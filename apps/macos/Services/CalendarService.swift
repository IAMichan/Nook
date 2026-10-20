import Foundation
@preconcurrency import EventKit

struct CalEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location: String
    var calendar: String = ""
}

struct ReminderItem: Identifiable, Equatable {
    var id: String
    var title: String
    var due: Date?
    var list: String
}

/// Calendar and reminders via EventKit.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    var hasEventAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var hasReminderAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    @discardableResult
    func requestEvents() async -> Bool {
        if hasEventAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    @discardableResult
    func requestReminders() async -> Bool {
        if hasReminderAccess { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    func events(from start: Date, to end: Date) -> [CalEvent] {
        guard hasEventAccess else { return [] }
        return Self.eventList(store, from: start, to: end)
    }

    /// Same as `events(from:to:)`, read off the main thread: a cold EventKit query can take a moment, and launching Nook
    /// (or a background refresh) should not wait for it.
    func loadEvents(from start: Date, to end: Date) async -> [CalEvent] {
        guard hasEventAccess else { return [] }
        let store = store
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.eventList(store, from: start, to: end))
            }
        }
    }

    private nonisolated static func eventList(_ store: EKEventStore, from start: Date, to end: Date) -> [CalEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                CalEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate,
                    location: $0.location ?? "",
                    calendar: $0.calendar?.title ?? ""
                )
            }
    }

    /// Events for availability checking: excludes canceled and declined events.
    func agendaEntries(from start: Date, to end: Date) -> [AgendaEntry] {
        guard hasEventAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled && !(($0.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }) }
            .sorted { $0.startDate < $1.startDate }
            .map {
                AgendaEntry(
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate,
                    allDay: $0.isAllDay,
                    busy: $0.availability != .free,
                    location: $0.location ?? "",
                    calendar: $0.calendar?.title ?? "Calendar"
                )
            }
    }

    /// All calendars Nook can read, followed by their account (iCloud, Google, Exchange…).
    func calendarNames() -> [String] {
        guard hasEventAccess else { return [] }
        return store.calendars(for: .event).map { calendar -> String in
            let source: EKSource? = calendar.source
            let account = source?.title ?? ""
            return account.isEmpty || account == calendar.title ? calendar.title : "\(calendar.title) (\(account))"
        }.sorted()
    }

    /// Pending reminders, earliest due date first.
    func incompleteReminders() async -> [ReminderItem] {
        guard hasReminderAccess else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await Self.fetch(store, predicate)
    }

    /// All reminders, optionally including completed ones.
    func allReminders(includeCompleted: Bool = false) async -> [ReminderItem] {
        guard hasReminderAccess else { return [] }
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await Self.fetch(store, predicate)
    }

    /// Searches reminders by query (title or list name).
    func searchReminders(query: String) async -> [ReminderItem] {
        let items = await allReminders(includeCompleted: false)
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return items }
        return items.filter { $0.title.lowercased().contains(q) || $0.list.lowercased().contains(q) }
    }

    /// Nonisolated helper: EventKit invokes the callback on its own thread.
    private nonisolated static func fetch(_ store: EKEventStore, _ predicate: NSPredicate) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder in
                    ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Untitled",
                        due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        list: reminder.calendar?.title ?? ""
                    )
                }
                continuation.resume(returning: items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        }
    }

    /// Creates an event and returns its ID, allowing follow-ups ("move it to 3pm") to refer to the same event.
    /// `calendarName`: target calendar name (as shown in Calendar); defaults to default calendar if omitted.
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, calendarName: String? = nil) async throws -> String {
        guard await requestEvents() else {
            throw NookError("Nook does not have access to your calendar. Enable it in Settings › Permissions.")
        }
        let calendar: EKCalendar
        if let calendarName, !calendarName.isEmpty {
            let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
            guard let match = writable.first(where: { $0.title.caseInsensitiveCompare(calendarName) == .orderedSame }) else {
                throw NookError("No writable calendar found named \(calendarName). Available: " + writable.map(\.title).joined(separator: ", ") + ".")
            }
            calendar = match
        } else {
            guard let fallback = store.defaultCalendarForNewEvents else {
                throw NookError("No default calendar found to save into.")
            }
            calendar = fallback
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    /// Updates an existing event. Only specified fields are changed; returns description of what changed.
    func updateEvent(id: String, title: String?, start: Date?, end: Date?, location: String?, notes: String?) async throws -> String {
        guard await requestEvents() else {
            throw NookError("Nook does not have access to your calendar. Enable it in Settings › Permissions.")
        }
        guard let event = store.event(withIdentifier: id) else {
            throw NookError("That event does not exist (anymore). Look it up again using list_events.")
        }
        guard event.calendar?.allowsContentModifications ?? false else {
            throw NookError("The calendar \(event.calendar?.title ?? "") is read-only.")
        }
        var changes: [String] = []
        if let title, title != event.title { event.title = title; changes.append("title") }
        if let start {
            let length = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = start
            event.endDate = end ?? start.addingTimeInterval(length)
            changes.append("time")
        } else if let end {
            guard end > event.startDate else { throw NookError("End time is not after start time.") }
            event.endDate = end
            changes.append("end time")
        }
        if let location { event.location = location; changes.append("location") }
        if let notes { event.notes = notes; changes.append("notes") }
        guard !changes.isEmpty else { throw NookError("There is nothing to update.") }
        try store.save(event, span: .thisEvent)
        return changes.joined(separator: ", ")
    }

    @discardableResult
    func createReminder(title: String, due: Date?) async throws -> String {
        guard await requestReminders() else {
            throw NookError("Nook does not have access to your reminders. Enable it in Settings › Permissions.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw NookError("No default reminder list available.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Removes an event Nook made ("maak ongedaan"). Returns its title.
    func deleteEvent(id: String) async throws -> String {
        guard await requestEvents() else {
            throw NookError("Nook does not have access to your calendar. Enable it in Settings › Permissions.")
        }
        guard let event = store.event(withIdentifier: id) else { throw NookError("That event does not exist (anymore).") }
        guard event.calendar?.allowsContentModifications ?? false else {
            throw NookError("The calendar \(event.calendar?.title ?? "") is read-only.")
        }
        let title = event.title ?? ""
        try store.remove(event, span: .thisEvent, commit: true)
        return title
    }

    /// Removes a reminder Nook made. Returns its title.
    func deleteReminder(id: String) async throws -> String {
        guard await requestReminders() else {
            throw NookError("Nook does not have access to your reminders. Enable it in Settings › Permissions.")
        }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NookError("That reminder does not exist (anymore).")
        }
        let title = reminder.title ?? ""
        try store.remove(reminder, commit: true)
        return title
    }

    /// Whether an event with this identifier exists (used to confirm an action really happened).
    func eventExists(_ id: String) -> Bool {
        store.event(withIdentifier: id) != nil
    }

    func reminderExists(_ id: String) -> Bool {
        store.calendarItem(withIdentifier: id) is EKReminder
    }

    /// Marks a reminder as completed, by ID or (if unique) by title. Returns the title.
    func completeReminder(_ idOrTitle: String) async throws -> String {
        guard await requestReminders() else {
            throw NookError("Nook does not have access to your reminders. Enable it in Settings › Permissions.")
        }
        if let item = store.calendarItem(withIdentifier: idOrTitle) as? EKReminder {
            item.isCompleted = true
            try store.save(item, commit: true)
            return item.title ?? idOrTitle
        }
        let open = await incompleteReminders().filter { $0.title.caseInsensitiveCompare(idOrTitle) == .orderedSame }
        guard open.count == 1, let match = store.calendarItem(withIdentifier: open[0].id) as? EKReminder else {
            throw NookError(open.isEmpty ? "No open reminder found for \(idOrTitle)." : "Multiple reminders found with that title; please specify the ID.")
        }
        match.isCompleted = true
        try store.save(match, commit: true)
        return match.title ?? idOrTitle
    }
}
