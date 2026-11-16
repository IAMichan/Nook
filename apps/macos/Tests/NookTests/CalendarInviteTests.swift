import XCTest

final class CalendarInviteTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    private func event() -> CalendarInvite.Event {
        CalendarInvite.Event(title: "Lunch, with Jan; and Sara", start: start, end: start.addingTimeInterval(3600),
                             location: "Café de Jaren", notes: "Line one\nLine two", organizer: "Me@Example.com",
                             attendees: ["jan@example.com", "JAN@example.com", "not an address", "me@example.com", "sara@example.nl"],
                             uid: "abc@nook", stamp: start)
    }

    func testRequestWithEveryAttendeeOnce() {
        let text = CalendarInvite.ics(event())
        XCTAssertTrue(text.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(text.contains("METHOD:REQUEST\r\n"))
        XCTAssertTrue(text.contains("UID:abc@nook\r\n"))
        XCTAssertTrue(text.contains("DTSTART:\(CalendarInvite.utc(start))\r\n"))
        XCTAssertTrue(text.contains("ORGANIZER:mailto:me@example.com\r\n"))
        let attendees = text.components(separatedBy: "\r\n").filter { $0.hasPrefix("ATTENDEE") }
        XCTAssertEqual(attendees.count, 2, "duplicates, the organizer and a non-address are left out")
        XCTAssertTrue(attendees.allSatisfy { $0.contains("RSVP=TRUE") })
        XCTAssertTrue(text.hasSuffix("END:VCALENDAR\r\n"))
    }

    func testTextIsEscaped() {
        let text = CalendarInvite.ics(event())
        XCTAssertTrue(text.contains("SUMMARY:Lunch\\, with Jan\\; and Sara\r\n"))
        XCTAssertTrue(text.contains("DESCRIPTION:Line one\\nLine two\r\n"))
    }

    func testUTCStamp() {
        XCTAssertEqual(CalendarInvite.utc(Date(timeIntervalSince1970: 0)), "19700101T000000Z")
    }

    func testLongLinesFoldWithoutSplittingCharacters() {
        let line = "DESCRIPTION:" + String(repeating: "é", count: 80)
        let folded = CalendarInvite.fold(line)
        let parts = folded.components(separatedBy: "\r\n")
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 75 })
        XCTAssertTrue(parts.dropFirst().allSatisfy { $0.hasPrefix(" ") })
        XCTAssertEqual(parts.enumerated().map { $0.offset == 0 ? $0.element : String($0.element.dropFirst()) }.joined(), line)
    }

    func testEventFromToolInput() {
        let input: [String: Any] = ["title": "Call", "start": "2026-11-18T10:00:00+01:00", "end": "2026-11-18T09:00:00+01:00"]
        let made = CalendarInvite.event(from: input, attendees: ["a@b.nl"], organizer: "", parse: NookDates.parse)
        XCTAssertEqual(made?.end.timeIntervalSince(made!.start), 3600, "an end before the start falls back to an hour")
        XCTAssertNil(CalendarInvite.event(from: ["title": "Call"], attendees: [], organizer: "", parse: NookDates.parse))
    }

    func testWritesAFileOfItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-invite-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = try CalendarInvite.write(event(), in: folder)
        let two = try CalendarInvite.write(event(), in: folder)
        XCTAssertNotEqual(one, two)
        XCTAssertTrue(one.hasSuffix("/invite.ics"))
        XCTAssertEqual(try String(contentsOfFile: one, encoding: .utf8), CalendarInvite.ics(event()))
    }
}
