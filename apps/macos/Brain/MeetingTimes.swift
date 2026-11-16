import Foundation

/// Picks concrete times for a meeting or a block of focus work out of the busy intervals of every calendar, so the brain
/// proposes "Tuesday 10:00–11:00" instead of doing time arithmetic on a list of gaps (small models get that wrong).
/// Foundation-only and pure: `find_time` (`ConnectorHub.hubTools`) gathers the busy times, this decides.
enum MeetingTimes {
    struct Busy: Equatable {
        var start: Date
        var end: Date
    }

    struct Slot: Equatable {
        var start: Date
        var end: Date
    }

    /// Which part of the day the user prefers. `any` takes the earliest time that fits.
    enum Preference: String, CaseIterable {
        case any, morning, afternoon, evening

        init(text: String?) {
            self = Preference(rawValue: (text ?? "").lowercased().trimmingCharacters(in: .whitespaces)) ?? .any
        }

        /// The hours this preference covers, start inclusive and end exclusive.
        var hours: Range<Int>? {
            switch self {
            case .any: return nil
            case .morning: return 0..<12
            case .afternoon: return 12..<17
            case .evening: return 17..<24
            }
        }
    }

    struct Request {
        var from: Date
        var to: Date
        var duration: TimeInterval
        /// How many options to propose.
        var count: Int = 3
        /// The hours a slot may fall in each day, in the user's time zone ("09:00" to "18:00" as minutes after midnight).
        var dayStart: Int = 9 * 60
        var dayEnd: Int = 18 * 60
        /// Free time kept before and after every busy event (travel, a breather).
        var buffer: TimeInterval = 0
        var weekends: Bool = false
        var preference: Preference = .any
        /// Starts fall on this grid (a quarter of an hour), so a proposal reads 10:15, never 10:07.
        var step: TimeInterval = 15 * 60
    }

    /// At most this many days are searched, so a vague "some time" stays quick and the answer stays short.
    static let maxDays = 31

    /// Up to `count` slots, spread over different days first (one per day, the preferred part of the day when it fits),
    /// then more on the same days. Nothing starts before `now`. Sorted by start.
    static func find(_ request: Request, busy: [Busy], now: Date, calendar: Calendar = .current) -> [Slot] {
        guard request.duration > 0, request.to > request.from, request.dayEnd > request.dayStart else { return [] }
        let count = max(1, min(request.count, 10))
        let blocked = merge(busy.map {
            Busy(start: $0.start.addingTimeInterval(-request.buffer), end: max($0.end, $0.start).addingTimeInterval(request.buffer))
        })

        var perDay: [[Slot]] = []
        var day = calendar.startOfDay(for: request.from)
        var days = 0
        while day < request.to, days < maxDays {
            days += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            defer { day = next }
            if !request.weekends, calendar.isDateInWeekend(day) { continue }
            // By the clock, not by seconds since midnight: a day with a daylight saving switch keeps 09:00 at 09:00.
            let open = clock(request.dayStart, on: day, next: next, calendar: calendar)
            let close = clock(request.dayEnd, on: day, next: next, calendar: calendar)
            let start = max(open, request.from, now)
            let end = min(close, request.to)
            guard end > start else { continue }
            let starts = candidates(in: free(blocked, from: start, to: end), duration: request.duration, step: request.step, day: day)
            if !starts.isEmpty { perDay.append(starts.map { Slot(start: $0, end: $0.addingTimeInterval(request.duration)) }) }
        }

        var chosen: [Slot] = []
        // First pass: one per day, the preferred part of the day when that day has it.
        for options in perDay where chosen.count < count {
            if let pick = preferred(options, request.preference, calendar: calendar) { chosen.append(pick) }
        }
        // Second pass: more on the same days, never overlapping what was chosen, still preferred times first.
        if chosen.count < count {
            let rest = perDay.flatMap { $0 }.filter { slot in !chosen.contains { $0.start < slot.end && slot.start < $0.end } }
            for slot in ordered(rest, request.preference, calendar: calendar) where chosen.count < count {
                if !chosen.contains(where: { $0.start < slot.end && slot.start < $0.end }) { chosen.append(slot) }
            }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// `minutes` after midnight on `day` by the clock; midnight at the end of the day is `next`.
    private static func clock(_ minutes: Int, on day: Date, next: Date, calendar: Calendar) -> Date {
        guard minutes < 24 * 60 else { return next }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            ?? day.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Overlapping or touching intervals joined, sorted by start.
    static func merge(_ busy: [Busy]) -> [Busy] {
        var merged: [Busy] = []
        for item in busy.sorted(by: { $0.start < $1.start }) where item.end > item.start {
            if let last = merged.last, item.start <= last.end {
                merged[merged.count - 1].end = max(last.end, item.end)
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    /// The free gaps between `from` and `to`.
    static func free(_ blocked: [Busy], from: Date, to: Date) -> [Slot] {
        var cursor = from
        var gaps: [Slot] = []
        for item in blocked {
            if item.end <= cursor { continue }
            if item.start >= to { break }
            if item.start > cursor { gaps.append(Slot(start: cursor, end: item.start)) }
            cursor = max(cursor, item.end)
        }
        if to > cursor { gaps.append(Slot(start: cursor, end: to)) }
        return gaps
    }

    /// Every start on the grid (counted from midnight) where the whole duration fits in a gap.
    private static func candidates(in gaps: [Slot], duration: TimeInterval, step: TimeInterval, day: Date) -> [Date] {
        let grid = max(step, 60)
        var starts: [Date] = []
        for gap in gaps {
            let offset = gap.start.timeIntervalSince(day)
            var start = day.addingTimeInterval((offset / grid).rounded(.up) * grid)
            while start.addingTimeInterval(duration) <= gap.end {
                starts.append(start)
                start = start.addingTimeInterval(grid)
            }
        }
        return starts
    }

    private static func inPreference(_ slot: Slot, _ preference: Preference, calendar: Calendar) -> Bool {
        guard let hours = preference.hours else { return true }
        return hours.contains(calendar.component(.hour, from: slot.start))
    }

    private static func preferred(_ options: [Slot], _ preference: Preference, calendar: Calendar) -> Slot? {
        options.first { inPreference($0, preference, calendar: calendar) } ?? options.first
    }

    private static func ordered(_ options: [Slot], _ preference: Preference, calendar: Calendar) -> [Slot] {
        let sorted = options.sorted { $0.start < $1.start }
        return sorted.filter { inPreference($0, preference, calendar: calendar) } + sorted.filter { !inPreference($0, preference, calendar: calendar) }
    }

    /// "09:30" or "9" as minutes after midnight; nil for anything else.
    static func minutes(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").map(String.init)
        guard let hour = Int(parts[0]), (0...24).contains(hour) else { return nil }
        let minute = parts.count > 1 ? Int(parts[1].prefix(2)) ?? 0 : 0
        guard (0..<60).contains(minute) else { return nil }
        return min(hour * 60 + minute, 24 * 60)
    }
}
