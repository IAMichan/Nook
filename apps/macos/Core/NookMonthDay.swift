import Foundation

/// A day of the year as month and day, for a birthday. Stored as "MM-dd".
struct NookMonthDay: Equatable, Codable {
    var month: Int
    var day: Int

    init?(month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.month = month
        self.day = day
    }

    init?(stored: String?) {
        let parts = (stored ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(month: parts[0], day: parts[1])
    }

    var stored: String { String(format: "%02d-%02d", month, day) }

    func matches(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        // Born on 29 February: celebrated on the 28th in other years.
        if month == 2, day == 29, parts.month == 2, parts.day == 28,
           let year = calendar.dateComponents([.year], from: date).year, !Self.isLeap(year) { return true }
        return parts.month == month && parts.day == day
    }

    private static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }
}
