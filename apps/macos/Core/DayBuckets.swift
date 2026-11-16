import Foundation

/// The age groups a list of conversations is sorted into, as the Claude app does it: Today, Yesterday, the 7 days before
/// that, and everything older. Foundation only, so it is tested without the app.
enum DayBucket: Int, CaseIterable {
    case today, yesterday, previousWeek, older

    /// The translation key of the group's name.
    var titleKey: String {
        switch self {
        case .today: return "nooks.section.today"
        case .yesterday: return "nooks.section.yesterday"
        case .previousWeek: return "nooks.section.previous7"
        case .older: return "nooks.section.older"
        }
    }

    /// The group `date` falls in. A date in the future counts as today.
    static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> DayBucket {
        if date >= calendar.startOfDay(for: now) { return .today }
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        if date >= yesterdayStart { return .yesterday }
        let weekStart = calendar.date(byAdding: .day, value: -8, to: calendar.startOfDay(for: now)) ?? now
        return date >= weekStart ? .previousWeek : .older
    }

    /// `items` split into groups, in the order they come (newest first stays newest first); empty groups are left out.
    static func group<T>(_ items: [T], date: (T) -> Date, now: Date = Date(), calendar: Calendar = .current)
        -> [(bucket: DayBucket, items: [T])] {
        var byBucket: [DayBucket: [T]] = [:]
        for item in items {
            byBucket[bucket(for: date(item), now: now, calendar: calendar), default: []].append(item)
        }
        return allCases.compactMap { bucket in
            guard let items = byBucket[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }
}
