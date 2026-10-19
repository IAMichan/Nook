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
        // The last two days of the range: yesterday 2, today 1.
        let perDay = stats.components(separatedBy: "\n").first { $0.hasPrefix("Per dag") } ?? ""
        XCTAssertTrue(perDay.hasSuffix(": 2, wo 14 okt: 1") || perDay.hasSuffix(": 2, wo 14 okt.: 1"), perDay)
    }

    func testNothingUnread() {
        let stats = MailStats.unread("TOTAL|||0\nACC|||iCloud|||0\n", now: Date(), calendar: calendar)
        XCTAssertEqual(stats, "Geen ongelezen mail in de inbox.")
    }

    func testInboxKeepsRecentUnansweredMailFromPeople() {
        let raw = """
        ROW|||Werk|||INBOX|||1|||Offerte vraag|||Lisa de Vries <lisa@example.com>|||2026-10-14T09:00:00|||false|||false
        ROW|||Werk|||INBOX|||2|||Re: planning|||Bob <bob@example.com>|||2026-10-13T09:00:00|||true|||true
        ROW|||Werk|||INBOX|||3|||Je weekoverzicht|||Service <noreply@service.com>|||2026-10-13T08:00:00|||false|||false
        ROW|||iCloud|||INBOX|||7|||Oude vraag|||Kim <kim@example.com>|||2026-09-01T08:00:00|||false|||false
        ROW|||iCloud|||INBOX|||4|||Kun je bellen?|||Kim <kim@example.com>|||2026-10-14T11:00:00|||true|||false
        """
        let now = date("2026-10-14T12:00:00")
        let open = MailStats.inbox(raw, now: now, days: 14, unansweredOnly: true, calendar: calendar)
        XCTAssertEqual(open.map(\.subject), ["Kun je bellen?", "Offerte vraag"], "nieuwste eerst, zonder beantwoord, noreply of te oud")
        XCTAssertEqual(open.first?.account, "iCloud")
        XCTAssertEqual(open.first?.index, 4)
        XCTAssertEqual(MailStats.inbox(raw, now: now, days: 14, unansweredOnly: false, calendar: calendar).count, 4)
    }

    func testBodiesByRowNumber() {
        let texts = MailStats.bodies("<<<BODY>>>0\nHoi, kun je\nmorgen?\n<<<BODY>>>2\nTot dan\n")
        XCTAssertEqual(texts[0], "Hoi, kun je\nmorgen?")
        XCTAssertEqual(texts[2], "Tot dan")
        XCTAssertNil(texts[1])
        XCTAssertTrue(MailStats.bodiesScript([MailStats.InboxRow(account: "Werk \"A\"", mailbox: "INBOX", index: 3, subject: "", sender: "",
                                                                  date: Date(), read: false, replied: false)])
            .contains("content of message 3 of mailbox \"INBOX\" of account \"Werk \\\"A\\\"\""))
    }

    func testRecentReadsUnreadTotalAndDescribes() {
        let raw = "TOTAL|||12\nROW|||Werk|||INBOX|||1|||Vraag|||Lisa <lisa@example.com>|||2026-10-14T09:00:00|||false|||false\n"
        let parsed = MailStats.recent(raw, calendar: calendar)
        XCTAssertEqual(parsed.unread, 12)
        var row = parsed.rows[0]
        row.body = "Kun je morgen?"
        let text = MailStats.describe([row], date: { _ in "14 okt" })
        XCTAssertEqual(text, "### Vraag | van Lisa <lisa@example.com> | 14 okt | ongelezen | Werk\nKun je morgen?")
    }
}
