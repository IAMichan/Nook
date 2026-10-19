import XCTest

/// Recognizing what a chat message asks for, before any model runs: the right tools for a small local model, and the one
/// action to fill in when the model proposed nothing. New phrasings that users try belong here.
final class ChatIntentTests: XCTestCase {
    private func action(_ text: String) -> String? { ChatIntent.detect(text).primaryAction }

    func testActionsInDutch() {
        XCTAssertEqual(action("Herinner me morgen om 9 uur aan de tandarts"), "create_reminder")
        XCTAssertEqual(action("Zet vrijdag om 15:00 een afspraak met Lisa in mijn agenda"), "create_event")
        XCTAssertEqual(action("Plan een meeting met Jan op maandag om 10 uur"), "create_event")
        XCTAssertEqual(action("Verplaats mijn afspraak met Lisa naar maandag"), "update_event")
        XCTAssertEqual(action("Stuur een mail naar Lisa dat ik later ben"), "compose_mail")
        XCTAssertEqual(action("Maak een notitie: boodschappen melk en eieren"), "create_note")
        XCTAssertEqual(action("Kun je een taak toevoegen om de offerte af te maken?"), "add_open_loop")
        XCTAssertEqual(action("Nook, vergeet niet dat ik de huur moet betalen"), "create_reminder")
    }

    func testActionsInEnglishAndGerman() {
        XCTAssertEqual(action("Remind me to call Jan tomorrow"), "create_reminder")
        XCTAssertEqual(action("Can you schedule a meeting with Lisa on Friday at 3?"), "create_event")
        XCTAssertEqual(action("Write an email to Tom about the invoice"), "compose_mail")
        XCTAssertEqual(action("Erinnere mich morgen an den Zahnarzt"), "create_reminder")
    }

    func testWhatToMakeWinsOverWhatItIsAbout() {
        XCTAssertEqual(action("Maak een grafiek van mijn afspraken per dag"), "show_chart")
        XCTAssertEqual(action("Stuur Lisa een mail over de meeting van vrijdag"), "compose_mail")
        XCTAssertEqual(action("Herinner me aan de call met Jan"), "create_reminder")
        XCTAssertEqual(action("Zet de muziek wat zachter"), "set_volume")
        XCTAssertNil(action("Open de pull request van Jan"), "a pull request is not an app")
        XCTAssertEqual(action("open Safari"), "open_app")
    }

    func testFollowUpCarriesTheMessageOfTheConversation() {
        // The conversation from the bug report: Nook said it sent the WhatsApp message without proposing it.
        let history = [
            ChatTurn(fromUser: true, text: "Staan er chats in whatsapp open"),
            ChatTurn(fromUser: false, text: "Ja, Arjan den Hartog stuurde een pdf."),
            ChatTurn(fromUser: true, text: "ik wil een bericht naar Arjan sturen"),
            ChatTurn(fromUser: false, text: "Nook kan een bericht naar Arjan sturen via WhatsApp. Wil je het bericht opschrijven of een tekst invoeren?")
        ]
        XCTAssertEqual(ChatIntent.detect("Stuur: Mooi idee, maar nog niet volledig", history: history).primaryAction, "whatsapp_send")
        let proposed = history + [
            ChatTurn(fromUser: true, text: "Stuur: Mooi idee, maar nog niet volledig"),
            ChatTurn(fromUser: false, text: "Nook stelt het bericht \"Mooi idee, maar nog niet volledig\" in te sturen naar Arjan den Hartog via WhatsApp. Wil je het bericht nu verzenden?")
        ]
        XCTAssertEqual(ChatIntent.detect("Verzend", history: proposed).primaryAction, "whatsapp_send")
        XCTAssertEqual(ChatIntent.detect("Ja", history: proposed).primaryAction, "whatsapp_send")
        XCTAssertEqual(ChatIntent.detect("ok", history: proposed).primaryAction, "whatsapp_send")
        // A mail conversation stays a mail.
        let mail = [ChatTurn(fromUser: true, text: "Heb ik nog ongelezen mail van Lisa?"), ChatTurn(fromUser: false, text: "Ja, over de offerte.")]
        XCTAssertEqual(ChatIntent.detect("Stuur haar een bericht dat ik morgen bel", history: mail).primaryAction, "compose_mail")
        // A go-ahead for the reminder the user asked for.
        let reminder = [ChatTurn(fromUser: true, text: "Herinner me morgen aan de tandarts"), ChatTurn(fromUser: false, text: "Hoe laat?")]
        XCTAssertEqual(ChatIntent.detect("ja", history: reminder).primaryAction, "create_reminder")
    }

    func testRetryCarriesTheLastAction() {
        // "Probeer het opnieuw" after a message that never arrived: it is that WhatsApp message again, to approve.
        let sent = [
            ChatTurn(fromUser: true, text: "App Arjan: Mooi idee, maar nog niet volledig"),
            ChatTurn(fromUser: false, text: "Ik heb het bericht aan Arjan via WhatsApp klaargezet."),
            ChatTurn(fromUser: true, text: "Stuur"),
            ChatTurn(fromUser: false, text: "Het bericht is verzonden.")
        ]
        XCTAssertEqual(ChatIntent.detect("Hij is niet aangekomen, probeer het opnieuw", history: sent).primaryAction, "whatsapp_send")
        XCTAssertEqual(ChatIntent.detect("nog een keer", history: sent).primaryAction, "whatsapp_send")
        XCTAssertEqual(ChatIntent.detect("try again", history: sent).primaryAction, "whatsapp_send")
        let reminder = [ChatTurn(fromUser: true, text: "Herinner me morgen om 9 uur aan de tandarts"), ChatTurn(fromUser: false, text: "Dat lukte niet.")]
        XCTAssertEqual(ChatIntent.detect("probeer opnieuw", history: reminder).primaryAction, "create_reminder")
        XCTAssertNil(ChatIntent.detect("Wat stond er nog eens in die mail?", history: sent).primaryAction, "a question, not a retry")
        XCTAssertNil(ChatIntent.detect("opnieuw", history: []).primaryAction, "nothing to do again")
    }

    func testFollowUpWithoutAnOpenQuestionStaysPlain() {
        let sent = [
            ChatTurn(fromUser: true, text: "App Lisa dat ik later ben"),
            ChatTurn(fromUser: false, text: "Ik heb het bericht aan Lisa klaargezet.")
        ]
        XCTAssertNil(ChatIntent.detect("top", history: sent).primaryAction, "thanks after the plan is not a new message")
        XCTAssertNil(ChatIntent.detect("Wat stuurt Lisa voor berichten?", history: sent).primaryAction)
        XCTAssertNil(ChatIntent.detect("Verzend", history: []).primaryAction, "nothing to carry over")
    }

    func testQuestionsAreNotActions() {
        XCTAssertNil(action("Ben ik vrijdag vrij?"))
        XCTAssertNil(action("Wat staat er morgen in mijn agenda?"))
        XCTAssertNil(action("Heb ik nog ongelezen mail van Lisa?"))
        XCTAssertNil(action("Wat is de hoofdstad van Frankrijk?"))
        let free = ChatIntent.detect("Ben ik vrijdag vrij?")
        XCTAssertEqual(free.tools.first, "check_availability")
        XCTAssertTrue(ChatIntent.detect("Heb ik nog ongelezen mail?").tools.contains("inbox_mail"))
    }

    func testSmallTalk() {
        XCTAssertTrue(ChatIntent.detect("Hoi!").isSmallTalk)
        XCTAssertTrue(ChatIntent.detect("Bedankt Nook").isSmallTalk)
        XCTAssertTrue(ChatIntent.detect("thanks!").isSmallTalk)
        XCTAssertFalse(ChatIntent.detect("Hoi, ben ik morgen vrij?").isSmallTalk)
        XCTAssertTrue(ChatIntent.detect("Wat is de hoofdstad van Frankrijk?").isEmpty)
    }

    func testToolsOfTheActionComeFirst() {
        let tools = ChatIntent.detect("Herinner me aan de call met Jan").tools
        XCTAssertEqual(tools.first, "create_reminder")
        XCTAssertEqual(Set(tools).count, tools.count, "no duplicates")
    }

    func testDateSheetSpellsOutTheComingDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 30))!
        let sheet = ChatIntent.dateSheet(now: now, calendar: calendar)
        XCTAssertTrue(sheet.contains("today: Thursday 2026-10-15"), sheet)
        XCTAssertTrue(sheet.contains("tomorrow: Friday 2026-10-16"), sheet)
        XCTAssertTrue(sheet.contains("+02:00"), sheet)
        XCTAssertTrue(sheet.contains("now 09:30"), sheet)
        XCTAssertTrue(sheet.contains("2026-10-16T15:00:00+02:00"), sheet)
    }
}
