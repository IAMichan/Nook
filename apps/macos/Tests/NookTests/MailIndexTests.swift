import XCTest

/// Searching Mail through its own index and reading its message files.
final class MailIndexTests: XCTestCase {
    private func emlx(_ message: String) -> Data {
        let bytes = Data(message.utf8)
        return Data("\(bytes.count)\n".utf8) + bytes + Data("<?xml version=\"1.0\"?><plist/>".utf8)
    }

    func testMessageFolderCountsTheThousandsBackwards() {
        XCTAssertEqual(MailIndex.folder(of: 56_789), "Data/6/5/Messages")
        XCTAssertEqual(MailIndex.folder(of: 123_456), "Data/3/2/1/Messages")
        XCTAssertEqual(MailIndex.folder(of: 999), "Data/Messages")
    }

    func testMailboxPath() {
        XCTAssertEqual(MailIndex.mailboxPath("imap://ABC-1/%5BGmail%5D/Alle%20e-mail"), "ABC-1/[Gmail].mbox/Alle e-mail.mbox")
        XCTAssertEqual(MailIndex.mailboxPath("imap://ABC-1/INBOX"), "ABC-1/INBOX.mbox")
        XCTAssertNil(MailIndex.mailboxPath("nonsense"))
    }

    func testSearchWordsCannotBreakOutOfTheQuery() {
        let sql = MailIndex.searchSQL(words: ["o'brien%"], sent: false, limit: 5)
        XCTAssertTrue(sql.contains(#"'%o''brien\%%' ESCAPE '\'"#), sql)
    }

    func testTrashAndJunkStayOutAndSentLooksOnlyInSent() {
        XCTAssertTrue(MailIndex.searchSQL(words: ["x"], sent: false, limit: 5).contains("NOT LIKE '%Verwijderd%'"))
        let sent = MailIndex.searchSQL(words: ["x"], sent: true, limit: 5)
        XCTAssertTrue(sent.contains("b.url LIKE '%Verzonden%'"))
        XCTAssertTrue(sent.contains("ra.address LIKE"))
    }

    func testAMessageInTwoMailboxesComesBackOnce() {
        let row: [String: Any] = ["id": NSNumber(value: 1), "subject": "Teksten", "address": "h@x.nl", "name": "Henk", "date": NSNumber(value: 100), "mailbox": "imap://a/b"]
        var other = row
        other["id"] = NSNumber(value: 2)
        let rows = MailIndex.rows([row, other])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sender, "Henk <h@x.nl>")
    }

    func testPlainMessage() {
        let message = MailIndex.message(emlx: emlx("Message-ID: <abc@x.nl>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHallo Michan\r\n"))
        XCTAssertEqual(message, MailIndex.Message(id: "abc@x.nl", text: "Hallo Michan"))
    }

    func testMultipartPrefersPlainTextAndDecodesIt() {
        let source = """
        Message-ID: <m@x.nl>
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/html; charset=utf-8

        <p>html</p>
        --b1
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Caf=C3=A9 om =
        vier
        --b1--
        """
        XCTAssertEqual(MailIndex.message(emlx: emlx(source))?.text, "Café om vier")
    }

    func testBase64AndHTML() {
        let body = Data("<style>p{}</style><p>Beste Henk &amp; Lisa</p>".utf8).base64EncodedString()
        let source = "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64\n\n\(body)\n"
        XCTAssertEqual(MailIndex.message(emlx: emlx(source))?.text, "Beste Henk & Lisa")
    }

    func testAnAttachmentIsNotTheText() {
        let source = """
        Content-Type: multipart/mixed; boundary=b2

        --b2
        Content-Type: text/plain
        Content-Disposition: attachment; filename=a.txt

        bijlage
        --b2
        Content-Type: text/plain

        de mail zelf
        --b2--
        """
        XCTAssertEqual(MailIndex.message(emlx: emlx(source))?.text, "de mail zelf")
    }

    func testAFileWithoutLengthIsNoMessage() {
        XCTAssertNil(MailIndex.message(emlx: Data("no length here".utf8)))
    }

    // MARK: Recent mail per account

    func testInboxAndSentBoxesAreFoundByNameInEveryLanguage() {
        let raw: [[String: Any]] = [
            ["id": NSNumber(value: 2), "url": "imap://ICLOUD/INBOX"],
            ["id": NSNumber(value: 3), "url": "imap://ICLOUD/Sent%20Messages"],
            ["id": NSNumber(value: 8), "url": "imap://GMAIL/%5BGmail%5D/Alle%20e-mail"],
            ["id": NSNumber(value: 18), "url": "imap://GMAIL/%5BGmail%5D/Verzonden%20berichten"],
            ["id": NSNumber(value: 29), "url": "ews://WORK/Postvak%20IN"],
            ["id": NSNumber(value: 50), "url": "ews://WORK/"],
            ["id": NSNumber(value: 60), "url": "imap://GMAIL/Archive/INBOX"],
        ]
        let boxes = MailIndex.boxes(raw, sentNames: MailChatData.sentNames)
        XCTAssertEqual(boxes, [
            .init(id: 2, account: "ICLOUD", path: "INBOX", kind: .inbox),
            .init(id: 3, account: "ICLOUD", path: "Sent Messages", kind: .sent),
            .init(id: 18, account: "GMAIL", path: "[Gmail]/Verzonden berichten", kind: .sent),
            .init(id: 29, account: "WORK", path: "Postvak IN", kind: .inbox),
        ], "All Mail and a nested folder named INBOX are no inbox; Gmail's Sent is reached by its whole path")
    }

    func testRecentSQLTakesGmailLabelsAndLeavesDeletedMailOut() {
        let sql = MailIndex.recentSQL(box: 9, limit: 60)
        XCTAssertTrue(sql.contains("SELECT message_id FROM labels WHERE mailbox_id = 9"), sql)
        XCTAssertTrue(sql.contains("m.deleted = 0"), sql)
        XCTAssertTrue(sql.hasSuffix("LIMIT 60"), sql)
    }

    func testRecentRowsNameSenderAndRecipient() {
        let raw: [[String: Any]] = [[
            "id": NSNumber(value: 57_293), "subject": "Re: Plan", "address": "lisa@example.com", "name": "Lisa de Vries",
            "date": NSNumber(value: 1_794_450_335), "read": NSNumber(value: 0), "replied": NSNumber(value: 1),
            "summary": "Hoi", "mailbox": "imap://GMAIL/%5BGmail%5D/Alle%20e-mail", "to_address": "me@example.com", "to_name": NSNull(),
        ], ["id": NSNull(), "date": NSNumber(value: 1)]]
        let rows = MailIndex.recent(raw)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sender, "Lisa de Vries <lisa@example.com>")
        XCTAssertEqual(rows.first?.recipient, "me@example.com")
        XCTAssertEqual(rows.first?.read, false)
        XCTAssertEqual(rows.first?.replied, true)
        XCTAssertEqual(rows.first?.date, Date(timeIntervalSince1970: 1_794_450_335))
    }
}
