import XCTest

/// Phishing and scams: Nook never counts a fake mail or message as one the user owes an answer, for every source.
final class MessageTrustTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testABrandFromAnotherDomainIsSuspicious() {
        let verdict = MessageTrust.assess(sender: "PayPal Service <service@paypal-secure-login.top>",
                                          subject: "Uw account is beperkt",
                                          body: "Uw account wordt geblokkeerd. Log direct in via https://bit.ly/x om uw gegevens te bevestigen.")
        XCTAssertTrue(verdict.isSuspicious)
        XCTAssertTrue(verdict.reasons.first?.contains("PayPal") == true)
        XCTAssertTrue(verdict.marker.hasPrefix("WARNING"))
    }

    func testTheBrandsOwnDomainIsFine() {
        let verdict = MessageTrust.assess(sender: "PayPal <service@intl.paypal.com>", subject: "Bevestig uw gegevens",
                                          body: "Bevestig uw gegevens in de app.")
        XCTAssertFalse(verdict.isSuspicious)
        XCTAssertFalse(MessageTrust.assess(sender: "Microsoft account team <account-security-noreply@accountprotection.microsoft.com>",
                                           subject: "Unusual sign-in activity", body: "We detected unusual sign-in activity.").isSuspicious)
    }

    func testOrdinaryMailFromPeopleIsFine() {
        XCTAssertFalse(MessageTrust.assess(sender: "Lisa de Vries <lisa@gmail.com>", subject: "Apple keynote vanavond?",
                                           body: "Kijk je mee? Kun je even laten weten of je komt?").isSuspicious)
        // A title, not the bank.
        XCTAssertFalse(MessageTrust.assess(sender: "Ing. J. de Vries <j.devries@bouwbedrijf.nl>", subject: "Offerte",
                                           body: "Hierbij de offerte, graag uw reactie binnen 24 uur.").isSuspicious)
        XCTAssertFalse(MessageTrust.assess(sender: "Henk <henk@example.nl>", subject: "Factuur",
                                           body: "Kun je de openstaande factuur van vorige maand nog betalen?").isSuspicious)
    }

    func testPrizesGiftCardsAndNewNumberStories() {
        XCTAssertTrue(MessageTrust.assess(sender: "Prize Desk <winner@lucky.example>", subject: "You have won!",
                                          body: "Send us gift cards to claim your prize.").isSuspicious)
        XCTAssertTrue(MessageTrust.assess(sender: "+31 6 12345678",
                                          body: "Hoi mam, dit is mijn nieuwe nummer. Kun je een rekening voor me betalen?").isSuspicious)
    }

    func testSomeoneYouWroteWithBeforeTakesMore() {
        let body = "Hoi mam, mijn telefoon is kapot, dit is mijn nieuwe nummer"
        XCTAssertFalse(MessageTrust.assess(sender: "Daan", body: body, known: true).isSuspicious)
    }

    func testFakeMailIsNotMailToAnswer() {
        var scam = MailStats.InboxRow(account: "iCloud", mailbox: "INBOX", index: 1, subject: "Laatste herinnering: uw DigiD verloopt",
                                      sender: "DigiD <noreply-digid@gmail.com>", date: now.addingTimeInterval(-3600), read: false, replied: false)
        scam.body = "Verifieer uw gegevens binnen 24 uur via https://digid-verify.click"
        let real = MailStats.InboxRow(account: "iCloud", mailbox: "INBOX", index: 2, subject: "Etentje zaterdag?",
                                      sender: "Lisa <lisa@gmail.com>", date: now.addingTimeInterval(-7200), read: false, replied: false)
        XCTAssertEqual(MailStats.select([scam, real], now: now, days: 7, unansweredOnly: true).map(\.subject), ["Etentje zaterdag?"])
        let described = MailStats.describe([scam], date: { _ in "today" })
        XCTAssertTrue(described.contains("WARNING likely phishing or scam"))
        XCTAssertTrue(described.contains("DigiD"))
    }

    func testAScamChatIsNotOwedInAnyApp() {
        for app in ["whatsapp", "telegram", "signal", "messages", "mail"] {
            var thread = InboxThread(id: "\(app)|onbekend", app: app, name: "+31 6 87654321")
            thread.messages = [InboxMessage(id: "1", text: "Hoi pap, dit is mijn nieuwe nummer. Kun je dit even voor me betalen?",
                                            date: Date().addingTimeInterval(-6 * 3600))]
            let turn = ChatFollowUpTurn(thread)
            XCTAssertTrue(turn.suspicious, app)
            XCTAssertTrue(ChatFollowUps().owed([turn], now: Date()).isEmpty, app)
            XCTAssertTrue(ChatInbox.details(thread).hasPrefix("WARNING"), app)
        }
    }
}
