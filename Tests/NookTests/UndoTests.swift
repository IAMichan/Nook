import XCTest

/// "Maak ongedaan": reversing what Nook just did.
final class UndoTests: XCTestCase {
    func testWhatCanBeUndone() {
        XCTAssertEqual(Undo.step(tool: "create_event", input: ["title": "Lunch"], result: "Event created: Lunch at vr 12:00 (id ABC:123-x)"),
                       Undo.Step(tool: "delete_event", input: ["id": "ABC:123-x", "title": "Lunch"]))
        XCTAssertEqual(Undo.step(tool: "create_reminder", input: [:], result: "Reminder created: Bellen (id R1)")?.tool, "delete_reminder")
        XCTAssertEqual(Undo.step(tool: "add_open_loop", input: [:], result: "Todo added: Offerte [id 1a2b3c4d]"),
                       Undo.Step(tool: "complete_open_loop", input: ["loop": "1a2b3c4d"]))
        XCTAssertNil(Undo.step(tool: "whatsapp_send", input: [:], result: "WhatsApp message sent to Lisa."))
        XCTAssertNil(Undo.step(tool: "create_event", input: [:], result: "Event created: Lunch"))
    }

    func testRecognizesTheRequest() {
        for text in ["Maak dat ongedaan", "maak het maar weer ongedaan", "Ongedaan maken", "draai dat terug", "undo", "Undo that please",
                     "mach das rückgängig", "Nook, maak dat ongedaan!", "toch niet"] {
            XCTAssertTrue(Undo.isRequest(text), text)
        }
        for text in ["hoe maak ik iets ongedaan in Word?", "maak een afspraak", "undo the last commit in my repo and push it"] {
            XCTAssertFalse(Undo.isRequest(text), text)
        }
    }

    func testOnlyTheLastBatch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let actions = [("old", now.addingTimeInterval(-900)), ("a", now.addingTimeInterval(-100)), ("b", now.addingTimeInterval(-60))]
            .map { (item: $0.0, date: $0.1) }
        XCTAssertEqual(Undo.batch(actions, now: now), ["b", "a"])
        XCTAssertEqual(Undo.batch(actions, now: now.addingTimeInterval(3_600)), [], "too long ago")
    }
}
