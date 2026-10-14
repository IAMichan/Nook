import Foundation
import EventKit

struct CalEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location: String
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
                    location: $0.location ?? ""
                )
            }
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

    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?) async throws {
        guard await requestEvents() else {
            throw NookError("Nook heeft geen toegang tot je agenda. Zet dat aan bij Instellingen › Machtigingen.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw NookError("Er is geen standaardagenda om in op te slaan.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    func createReminder(title: String, due: Date?) async throws {
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
    }
}
