import XCTest

final class MailTemplateTests: XCTestCase {
    func testMailBlockReadsItsHeaders() {
        let text = """
        Here is the mail:

        ```mail
        To: jan@example.com
        Cc: lisa@example.com
        Bcc: archive@example.com
        **Subject:** Latest versions

        Hi Jan,

        Attached are the latest versions.

        Regards,
        Michan
        ```
        """
        guard case .mail(let mail) = MarkdownBlock.parse(text).last else { return XCTFail("no mail") }
        XCTAssertEqual(mail.to, "jan@example.com")
        XCTAssertEqual(mail.cc, "lisa@example.com")
        XCTAssertEqual(mail.bcc, "archive@example.com")
        XCTAssertEqual(mail.subject, "Latest versions")
        XCTAssertTrue(mail.body.hasPrefix("Hi Jan,"))
        XCTAssertTrue(mail.body.hasSuffix("Michan"))
    }

    func testHeadersInOtherLanguages() {
        let mail = MailTemplate.fenced("Aan: jan@example.com\nOnderwerp: Zips\nCci: x@example.com\n\nHoi Jan,")
        XCTAssertEqual(mail.to, "jan@example.com")
        XCTAssertEqual(mail.subject, "Zips")
        XCTAssertEqual(mail.bcc, "x@example.com")
        XCTAssertEqual(mail.body, "Hoi Jan,")
    }

    func testMailBlockWithoutHeadersIsAllText() {
        let mail = MailTemplate.fenced("Hoi Jan,\n\nTot morgen.")
        XCTAssertEqual(mail.to, "")
        XCTAssertEqual(mail.body, "Hoi Jan,\n\nTot morgen.")
    }

    func testQuotedDraftBecomesAMail() {
        let text = """
        Een conceptantwoord:

        > Hoi Jan,
        >
        > In de bijlage vind je de meest recente versies, elk als aparte zip.
        >
        > Laat het weten als je nog iets nodig hebt.
        >
        > Groet,
        > Michan
        """
        guard case .mail(let mail) = MarkdownBlock.parse(text).last else { return XCTFail("no mail") }
        XCTAssertEqual(mail.subject, "")
        XCTAssertTrue(mail.body.hasPrefix("Hoi Jan,"))
        XCTAssertTrue(mail.body.hasSuffix("Michan"))
    }

    func testOrdinaryQuoteStaysAQuote() {
        guard case .quote = MarkdownBlock.parse("> Simple is better than complex.\n> — Tim Peters").first else {
            return XCTFail("a quote that is no mail stays a quote")
        }
        guard case .quote = MarkdownBlock.parse("> [!NOTE]\n> Hi there,\n> Regards,").first else {
            return XCTFail("a call-out stays a quote")
        }
    }

    func testQuotedHeadersBecomeAMail() {
        guard case .mail(let mail) = MarkdownBlock.parse("> To: a@b.nl\n> Subject: Hello\n>\n> Short note.").first else {
            return XCTFail("no mail")
        }
        XCTAssertEqual(mail.to, "a@b.nl")
        XCTAssertEqual(mail.body, "Short note.")
    }

    func testReplyScriptAddsBlindCopies() {
        let script = MailActions.replyScript(id: "a@b", body: "Hi", to: ["x@y.nl"], cc: [], bcc: ["z@y.nl"], openWindow: false)
        XCTAssertTrue(script.contains("make new bcc recipient at end of bcc recipients of m with properties {address:\"z@y.nl\"}"))
    }
}
