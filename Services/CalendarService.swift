import Foundation
import EventKit

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

/// Agenda en herinneringen via EventKit.
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
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                CalEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Zonder titel",
                    start: $0.startDate,
                    end: $0.endDate,
                    location: $0.location ?? "",
                    calendar: $0.calendar?.title ?? ""
                )
            }
    }

    /// Afspraken voor de beschikbaarheidscheck: zonder geannuleerde en afgewezen afspraken.
    func agendaEntries(from start: Date, to end: Date) -> [AgendaEntry] {
        guard hasEventAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled && !(($0.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }) }
            .sorted { $0.startDate < $1.startDate }
            .map {
                AgendaEntry(
                    title: $0.title ?? "Zonder titel",
                    start: $0.startDate,
                    end: $0.endDate,
                    allDay: $0.isAllDay,
                    busy: $0.availability != .free,
                    location: $0.location ?? "",
                    calendar: $0.calendar?.title ?? "Agenda"
                )
            }
    }

    /// Alle agenda's die Nook kan lezen, met het account erachter (iCloud, Google, Exchange…).
    func calendarNames() -> [String] {
        guard hasEventAccess else { return [] }
        return store.calendars(for: .event).map { calendar -> String in
            let source: EKSource? = calendar.source
            let account = source?.title ?? ""
            return account.isEmpty || account == calendar.title ? calendar.title : "\(calendar.title) (\(account))"
        }.sorted()
    }

    /// Herinneringen die nog open staan, met de vroegste deadline eerst.
    func incompleteReminders() async -> [ReminderItem] {
        guard hasReminderAccess else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await Self.fetch(store, predicate)
    }

    /// Buiten de main actor: EventKit roept de callback aan op een eigen thread.
    private nonisolated static func fetch(_ store: EKEventStore, _ predicate: NSPredicate) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder in
                    ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Zonder titel",
                        due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        list: reminder.calendar?.title ?? ""
                    )
                }
                continuation.resume(returning: items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        }
    }

    /// Maakt een afspraak en geeft het id terug, zodat een vervolgvraag ("verplaats hem naar 15:00") dezelfde afspraak vindt.
    /// `calendarName`: in welke agenda (naam zoals in Agenda); zonder naam de standaardagenda.
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, calendarName: String? = nil) async throws -> String {
        guard await requestEvents() else {
            throw NookError("Nook heeft geen toegang tot je agenda. Zet dat aan bij Instellingen › Machtigingen.")
        }
        let calendar: EKCalendar
        if let calendarName, !calendarName.isEmpty {
            let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
            guard let match = writable.first(where: { $0.title.caseInsensitiveCompare(calendarName) == .orderedSame }) else {
                throw NookError("Geen agenda met de naam \(calendarName) waarin Nook mag schrijven. Wel: " + writable.map(\.title).joined(separator: ", ") + ".")
            }
            calendar = match
        } else {
            guard let fallback = store.defaultCalendarForNewEvents else {
                throw NookError("Er is geen standaardagenda om in op te slaan.")
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

    /// Past een bestaande afspraak aan. Alleen wat meegegeven wordt verandert; geeft terug wat er veranderde.
    func updateEvent(id: String, title: String?, start: Date?, end: Date?, location: String?, notes: String?) async throws -> String {
        guard await requestEvents() else {
            throw NookError("Nook heeft geen toegang tot je agenda. Zet dat aan bij Instellingen › Machtigingen.")
        }
        guard let event = store.event(withIdentifier: id) else {
            throw NookError("Die afspraak bestaat niet (meer). Zoek hem opnieuw op met list_events.")
        }
        guard event.calendar?.allowsContentModifications ?? false else {
            throw NookError("De agenda \(event.calendar?.title ?? "") is alleen-lezen.")
        }
        var changes: [String] = []
        if let title, title != event.title { event.title = title; changes.append("titel") }
        if let start {
            let length = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = start
            event.endDate = end ?? start.addingTimeInterval(length)
            changes.append("tijd")
        } else if let end {
            guard end > event.startDate else { throw NookError("Het einde ligt niet na het begin.") }
            event.endDate = end
            changes.append("eindtijd")
        }
        if let location { event.location = location; changes.append("plaats") }
        if let notes { event.notes = notes; changes.append("notities") }
        guard !changes.isEmpty else { throw NookError("Er is niets om aan te passen.") }
        try store.save(event, span: .thisEvent)
        return changes.joined(separator: ", ")
    }

    @discardableResult
    func createReminder(title: String, due: Date?) async throws -> String {
        guard await requestReminders() else {
            throw NookError("Nook heeft geen toegang tot je herinneringen. Zet dat aan bij Instellingen › Machtigingen.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw NookError("Er is geen standaardlijst voor herinneringen.")
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

    /// Vinkt een herinnering af, op id of (als die uniek is) op titel. Geeft de titel terug.
    func completeReminder(_ idOrTitle: String) async throws -> String {
        guard await requestReminders() else {
            throw NookError("Nook heeft geen toegang tot je herinneringen. Zet dat aan bij Instellingen › Machtigingen.")
        }
        if let item = store.calendarItem(withIdentifier: idOrTitle) as? EKReminder {
            item.isCompleted = true
            try store.save(item, commit: true)
            return item.title ?? idOrTitle
        }
        let open = await incompleteReminders().filter { $0.title.caseInsensitiveCompare(idOrTitle) == .orderedSame }
        guard open.count == 1, let match = store.calendarItem(withIdentifier: open[0].id) as? EKReminder else {
            throw NookError(open.isEmpty ? "Geen open herinnering gevonden voor \(idOrTitle)." : "Er zijn meerdere herinneringen met die titel; geef het id.")
        }
        match.isCompleted = true
        try store.save(match, commit: true)
        return match.title ?? idOrTitle
    }
}
