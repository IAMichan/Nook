import XCTest

/// Reading apps without an API (Messages, WhatsApp, Bear, Things): the SQL Nook builds, how it decodes what Messages
/// stores, and the text the brain gets. Rows are written by hand in the shape `sqlite3 -json` returns.
final class AppDataTests: XCTestCase {
    func testLikeEscapesQuotesAndWildcards() {
        XCTAssertEqual(AppData.literal("it's"), "'it''s'")
        let sql = AppData.anyLike(["m.text"], ["50%", "o'brien"])
        XCTAssertTrue(sql.contains("'%50\\%%'"), sql)
        XCTAssertTrue(sql.contains("'%o''brien%'"), sql)
        XCTAssertEqual(AppData.anyLike(["m.text"], []), "0", "no words matches nothing instead of everything")
    }

    func testMessagesTextIsReadFromTheArchivedBody() {
        let text = "Zullen we vrijdag de offerte bespreken?"
        var bytes: [UInt8] = Array("streamtyped NSAttributedString NSObject ".utf8) + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes.append(UInt8(text.utf8.count))
        bytes += Array(text.utf8) + [0x86, 0x84]
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(AppData.attributedText(hex: hex), text)

        let long = String(repeating: "lang bericht ", count: 30)
        var longBytes: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81]
        longBytes += [UInt8(long.utf8.count & 0xFF), UInt8(long.utf8.count >> 8)] + Array(long.utf8)
        XCTAssertEqual(AppData.attributedText(hex: longBytes.map { String(format: "%02X", $0) }.joined()), long)
        XCTAssertNil(AppData.attributedText(hex: "ZZ"))
    }

    func testDatesInSecondsAndNanoseconds() {
        let seconds = AppData.appleDate(700_000_000)
        let nanoseconds = AppData.appleDate(700_000_000 * 1_000_000_000)
        XCTAssertEqual(seconds.timeIntervalSinceReferenceDate, nanoseconds.timeIntervalSinceReferenceDate, accuracy: 1)
    }

    func testOnePersonHoweverTheNumberIsWritten() {
        XCTAssertEqual(AppData.key("+31 6 1234 5678"), AppData.key("0612345678"))
        XCTAssertEqual(AppData.key("31612345678@s.whatsapp.net"), AppData.key("06-12345678"))
        XCTAssertEqual(AppData.key("Lisa@Example.com"), "lisa@example.com")
    }

    private let rows: [[String: Any]] = [
        ["chat": 7, "chatname": "+31612345678", "handle": "+31612345678", "me": 0, "date": 700_000_300, "text": "De offerte voor de keuken komt morgen", "body": ""],
        ["chat": 7, "chatname": "+31612345678", "handle": "", "me": 1, "date": 700_000_200, "text": "Hoe staat het met de offerte?", "body": ""],
        ["chat": 9, "chatname": "Voetbal", "handle": "+31600000000", "me": 0, "date": 700_000_100, "text": "Training gaat niet door", "body": ""],
        ["chat": 9, "chatname": "Voetbal", "handle": "+31600000000", "me": 0, "date": 700_000_050, "text": "\u{FFFC}", "body": ""]
    ]

    func testMessagesGetContactNamesAndSkipAttachments() {
        let messages = AppData.messages(rows, names: [AppData.key("06 12345678"): "Jan de Vries"])
        XCTAssertEqual(messages.count, 3, "an attachment without text is left out")
        XCTAssertEqual(messages[0].chatName, "Jan de Vries")
        XCTAssertEqual(messages[0].sender, "Jan de Vries")
        XCTAssertEqual(messages[1].sender, "Ik")
        XCTAssertEqual(messages[2].chatName, "Voetbal")
    }

    func testSearchGroupsPerConversationBestFirst() {
        let messages = AppData.messages(rows, names: [AppData.key("0612345678"): "Jan de Vries"])
        let text = AppData.formatSearch(messages, terms: Research.Terms(words: ["offerte"]), app: "Berichten")
        XCTAssertTrue(text.hasPrefix("### Jan de Vries"), text)
        XCTAssertTrue(text.contains("[chat: 7]"))
        XCTAssertFalse(text.contains("Training"), "a conversation without the word is not a result")
        let hits = Research.hits(in: text, tool: "search_messages")
        XCTAssertEqual(hits.first?.read, "read_messages")
        XCTAssertEqual(hits.first?.input["chat"] as? String, "7")
    }

    func testThreadShowsThePassageAroundTheMatchInTimeOrder() {
        var thread: [AppData.Message] = []
        for index in 0..<60 {
            let text = index == 10 ? "Het budget is 15.000 euro" : "bericht \(index)"
            thread.append(AppData.Message(chat: "7", chatName: "Jan", sender: "Jan", fromMe: false,
                                          date: Date(timeIntervalSinceReferenceDate: Double(1_000 + index)), text: text))
        }
        let text = AppData.formatThread(thread.reversed(), terms: Research.Terms(words: ["budget"]), app: "Berichten", around: 2, recent: 5)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasSuffix("Jan: Het budget is 15.000 euro") })
        XCTAssertTrue(lines.contains("…"), "a gap between the passage and the recent messages")
        let budget = lines.firstIndex { $0.contains("budget") } ?? 0
        let last = lines.firstIndex { $0.hasSuffix("bericht 59") } ?? 0
        XCTAssertLessThan(budget, last, "in time order")
        XCTAssertFalse(text.contains("bericht 30"), "messages far from the match are not sent")
    }

    func testBearNotesOpenLikeAppleNotes() {
        let text = AppData.formatNotes([
            ["id": "A1-B2", "title": "Verbouwing", "date": 700_000_000, "text": String(repeating: "keuken en badkamer ", count: 60)],
            ["id": "C3", "title": "Boodschappen", "date": 700_000_000, "text": "melk"]
        ], terms: Research.Terms(words: ["verbouwing"]), app: "Bear")
        let hits = Research.hits(in: text, tool: "search_bear")
        XCTAssertEqual(hits.first?.title, "Verbouwing")
        XCTAssertEqual(hits.first?.input["id"] as? String, "A1-B2")
        XCTAssertFalse(text.contains("Boodschappen"))
    }

    func testThingsShowsStatusAndProject() {
        let text = AppData.formatTasks([
            ["title": "Offerte keuken opvragen", "notes": "Bij Jansen", "status": 3, "type": 0, "project": "Verbouwing", "area": ""]
        ], terms: Research.Terms(words: ["offerte"]))
        XCTAssertTrue(text.hasPrefix("- Offerte keuken opvragen [to-do, done] (Verbouwing)"), text)
    }
}
