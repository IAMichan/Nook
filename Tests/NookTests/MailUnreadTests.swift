import XCTest
#if canImport(NookCore)
@testable import NookCore
#endif

final class MailUnreadTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)!
    }

    func testCountsPerDayAccountAndSender() {
        let raw = """
        TOTAL|||4
        ACC|||iCloud|||1
        ACC|||Werk|||3
        MSG|||Lisa de Vries <lisa@example.com>|||2026-10-14T09:12:00
        MSG|||Lisa de Vries <lisa@example.com>|||2026-10-13T17:40:00
        MSG|||Bank <info@bank.nl>|||2026-10-13T08:00:00
        MSG|||Oud <oud@example.com>|||2026-09-01T08:00:00
        """
        let stats = MailStats.unread(raw, now: date("2026-10-14T12:00:00"), calendar: calendar)
        XCTAssertTrue(stats.contains("Ongelezen in de inbox: 4"))
        XCTAssertTrue(stats.contains("Per account: iCloud: 1, Werk: 3"))
        XCTAssertTrue(stats.contains("Ouder dan 14 dagen: 1"))
        XCTAssertTrue(stats.contains("Meeste ongelezen van: Lisa de Vries: 2"))
        XCTAssertTrue(stats.contains("Oud: 1"))
        // De laatste twee dagen van de reeks: gisteren 2, vandaag 1.
        let perDay = stats.components(separatedBy: "\n").first { $0.hasPrefix("Per dag") } ?? ""
        XCTAssertTrue(perDay.hasSuffix(": 2, wo 14 okt: 1") || perDay.hasSuffix(": 2, wo 14 okt.: 1"), perDay)
    }

    func testNothingUnread() {
        let stats = MailStats.unread("TOTAL|||0\nACC|||iCloud|||0\n", now: Date(), calendar: calendar)
        XCTAssertEqual(stats, "Geen ongelezen mail in de inbox.")
    }
}
