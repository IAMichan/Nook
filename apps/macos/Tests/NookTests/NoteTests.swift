import XCTest

/// The Notetaker's transcript, summary and search. Partly after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
final class NoteTests: XCTestCase {
    private func words(_ text: String, from start: Double, step: Double = 0.3) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: String(word), start: start + Double(index) * step, end: start + Double(index) * step + 0.25)
        }
    }

    func testWordsFromTheRecognizerArePlacedInTheRecording() {
        let placed = NoteBuilder.words([(text: "hallo", start: 0.2, duration: 0.3), (text: " ", start: 1, duration: 0)], offset: 30)
        XCTAssertEqual(placed, [TimedWord(text: "hallo", start: 30.2, end: 30.5)])
    }

    func testTranscriptFromBothSidesWithoutTheEcho() {
        let mine = words("zullen we vrijdag afspreken", from: 0) + words("de offerte komt morgen", from: 10)
        let theirs = words("prima vrijdag om tien uur", from: 3) + words("de offerte komt morgen", from: 10.1)
        let built = NoteBuilder.build(mine: mine, others: theirs, meName: "Ik", othersName: "De anderen")
        XCTAssertEqual(built.speakers.map(\.name), ["Ik", "De anderen"])
        XCTAssertEqual(built.lines.map(\.text), ["zullen we vrijdag afspreken", "prima vrijdag om tien uur", "de offerte komt morgen"])
        XCTAssertEqual(built.lines.last?.speaker, "others", "my microphone hearing their speakers is not me speaking")
    }

    func testSummaryIsReadEvenWithTextAround() {
        let reply = """
        Hier zijn de notities:
        ```json
        {"title": "Offerte Lisa", "summary": "We spreken vrijdag af.", "key_points": ["Vrijdag 10 uur"], "todos": [{"text": "Offerte sturen", "owner": "Ik", "due": "morgen"}, {"text": "Agenda checken", "owner": null, "due": "null"}]}
        ```
        """
        let summary = NoteBuilder.parseSummary(reply)
        XCTAssertEqual(summary?.title, "Offerte Lisa")
        XCTAssertEqual(summary?.todos.first?.due, "morgen")
        XCTAssertNil(summary?.todos.last?.owner)
        XCTAssertNil(summary?.todos.last?.due)
        XCTAssertNil(NoteBuilder.parseSummary("geen json"))
    }

    func testSearchAndOverview() {
        var older = Note(title: "Sprint", start: Date(timeIntervalSince1970: 1_700_000_000))
        older.lines = [NoteLine(speaker: "me", start: 0, end: 2, text: "de offerte van Lisa")]
        older.end = older.start.addingTimeInterval(600)
        var newer = Note(title: "Offerte Lisa", start: Date(timeIntervalSince1970: 1_800_000_000))
        newer.summary = "Afspraak vrijdag."
        newer.todos = [NoteTodo(text: "Offerte sturen")]
        newer.end = newer.start.addingTimeInterval(1800)
        let found = NoteBuilder.search([older, newer], query: "offerte")
        XCTAssertEqual(found.map(\.title), ["Offerte Lisa", "Sprint"], "a word in the title counts more")
        XCTAssertTrue(NoteBuilder.search([older, newer], query: "budget").isEmpty)
        let line = NoteBuilder.overview(newer)
        XCTAssertTrue(line.contains("(30 min) Offerte Lisa: Afspraak vrijdag. To-dos: Offerte sturen"), line)
        XCTAssertTrue(line.contains(newer.id.uuidString))
    }

    func testMarkdownAndClock() {
        var note = Note(title: "Call", start: Date())
        note.speakers = [NoteSpeaker(id: "me", name: "Ik", color: 0, isMe: true)]
        note.lines = [NoteLine(speaker: "me", start: 75, end: 77, text: "hallo")]
        note.todos = [NoteTodo(text: "Bellen", owner: "Ik", due: nil)]
        let markdown = NoteBuilder.markdown(note, labels: .init(summary: "S", keyPoints: "K", todos: "T", transcript: "Tr"))
        XCTAssertTrue(markdown.contains("- [ ] Bellen (Ik)"))
        XCTAssertTrue(markdown.contains("**Ik** (1:15) : hallo"))
        XCTAssertEqual(NoteBuilder.clock(3725), "1:02:05")
    }

    func testOthersToldApartWithTheDiarizer() {
        let theirs = words("goedemorgen allemaal", from: 0) + words("ik heb de cijfers", from: 5)
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 1), SpeakerTurn(speaker: "B", start: 4.8, end: 6.5)]
        let built = NoteBuilder.build(mine: [], others: theirs, turns: turns, meName: "Ik", personName: { "Persoon \($0)" })
        XCTAssertEqual(built.speakers.filter { !$0.isMe }.map(\.name), ["Persoon 2", "Persoon 3"])
        XCTAssertEqual(built.lines.map(\.speaker), ["p2", "p3"])
    }
}
