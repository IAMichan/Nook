import XCTest

/// Taking over a task: which steps wait for the user's yes, what is never typed, and how the outcome is read.
final class TakeoverPolicyTests: XCTestCase {
    private func controlInput(_ steps: [[String: Any]]) -> [String: Any] {
        ["app": "Safari", "steps": steps]
    }

    func testMovingAroundRunsOnItsOwn() {
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "open_url", input: ["url": "https://www.bol.com"], summary: "Open bol.com"))
        let search = controlInput([
            ["action": "type", "element": "Zoeken", "text": "koffiefilters"],
            ["action": "key", "keys": "return"]
        ])
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: search, summary: "search"), "Return after a search field")
        let browse = controlInput([["action": "click", "element": "Melitta koffiefilters 1x4"], ["action": "scroll", "direction": "down"]])
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: browse, summary: "browse"))
        let cart = controlInput([["action": "click", "element": "In winkelwagen"]])
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: cart, summary: "cart"), "adding to the cart commits nothing")
    }

    func testThePointOfNoReturnWaitsForTheUser() {
        for label in ["Bestelling plaatsen", "Nu betalen", "Place order", "Send", "Verzenden", "Unsubscribe", "Delete account",
                      "Book now", "Bevestigen", "Jetzt kaufen"] {
            let input = controlInput([["action": "click", "element": label]])
            XCTAssertEqual(TakeoverPolicy.checkpoint(tool: "control_ui", input: input, summary: "click \(label)"), "click \(label)", label)
        }
        let enter = controlInput([["action": "type", "element": "Message", "text": "Hi"], ["action": "key", "keys": "return"]])
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: enter, summary: "send"), "Return in a message field sends")
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "compose_mail", input: [:], summary: "mail"), "every other action asks")
        XCTAssertNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: controlInput([["action": "click", "element": "Sender"]]),
                                               summary: "x"), "whole words only")
        let message = controlInput([["action": "type", "element": "Message to Anna", "text": "Hoi"], ["action": "key", "keys": "return"]])
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: message, summary: "send"), "\"to\" is no search field")
        let switched = controlInput([
            ["action": "type", "element": "Search", "text": "Anna"],
            ["action": "click", "element": "Message"],
            ["action": "key", "keys": "return"]
        ])
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: switched, summary: "send"), "a click leaves the search field")
        let point = controlInput([["action": "click", "x": 640, "y": 512]])
        XCTAssertNotNil(TakeoverPolicy.checkpoint(tool: "control_ui", input: point, summary: "point"), "a point could be any button")
    }

    func testCardNumbersAreNeverTyped() {
        let card = controlInput([["action": "type", "element": "Kaartnummer", "text": "4111 1111 1111 1111"]])
        XCTAssertNotNil(TakeoverPolicy.refusal(tool: "control_ui", input: card))
        let name = controlInput([["action": "type", "element": "Naam", "text": "Michan"]])
        XCTAssertNil(TakeoverPolicy.refusal(tool: "control_ui", input: name))
    }

    func testTheOutcomeComesFromTheLastLine() {
        let done = TakeoverPolicy.outcome(of: "Besteld: 2 pakken filters, levering morgen.\nSTATUS: DONE")
        XCTAssertEqual(done.outcome, .done)
        XCTAssertEqual(done.summary, "Besteld: 2 pakken filters, levering morgen.")

        let failed = TakeoverPolicy.outcome(of: "Ik moest inloggen.\n**STATUS: COULD_NOT — sign-in needed**")
        XCTAssertEqual(failed.outcome, .couldNot("sign-in needed"))
        XCTAssertEqual(failed.summary, "Ik moest inloggen.")

        XCTAssertEqual(TakeoverPolicy.outcome(of: "STATUS: COULD_NOT — no\nSTATUS: DONE").outcome, .couldNot("no"), "a refusal wins")
        XCTAssertEqual(TakeoverPolicy.outcome(of: "I clicked the button.").outcome, .unconfirmed, "no status is never success")
    }

    func testThePromptCarriesTheTaskAndWhatNookKnows() {
        let prompt = TakeoverPolicy.prompt(task: "Bestel koffiefilters", frontApp: "Safari", window: "bol.com", screen: "Zoeken",
                                           memories: ["Woont in Utrecht"], dates: "Dates: today")
        XCTAssertTrue(prompt.hasPrefix("THE TASK: Bestel koffiefilters"))
        XCTAssertTrue(prompt.contains("In front now: Safari — \"bol.com\""))
        XCTAssertTrue(prompt.contains("- Woont in Utrecht"))
        XCTAssertTrue(prompt.contains("Text on screen now:\nZoeken"))
    }
}
