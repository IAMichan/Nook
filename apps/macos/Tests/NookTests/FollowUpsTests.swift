import XCTest

final class FollowUpsTests: XCTestCase {
    func testTheChatKeepsThreeNextSteps() {
        let text = "The invoice is due Friday [1].\n\n» Add a reminder for Thursday\n» Compare with March\n» What did Henk reply?\n» Mail Henk"
        let split = FollowUps.split(text)
        XCTAssertEqual(split.body, "The invoice is due Friday [1].")
        XCTAssertEqual(split.offers, ["Add a reminder for Thursday", "Compare with March", "What did Henk reply?"])
    }

    func testACardKeepsTwo() {
        let split = FollowUps.split("Done.\n» One\n» Two\n» Three", limit: FollowUps.cardLimit)
        XCTAssertEqual(split.offers, ["One", "Two"])
    }

    func testOffersWrittenAsAListAreStillOffers() {
        let split = FollowUps.split("Here it is.\n- » Add to calendar\n1. » Mail Henk\n* »Open the note")
        XCTAssertEqual(split.body, "Here it is.")
        XCTAssertEqual(split.offers, ["Add to calendar", "Mail Henk", "Open the note"])
    }

    func testAnOrdinaryListStaysInTheAnswer() {
        let text = "Steps:\n- open the app\n1. sign in\n> a quote"
        let split = FollowUps.split(text)
        XCTAssertEqual(split.body, text)
        XCTAssertTrue(split.offers.isEmpty)
    }

    func testGenericAndDuplicateOffersAreDropped() {
        let split = FollowUps.split("Ok.\n» Tell me more\n» Erzähl mir mehr\n» Add to calendar\n» add to calendar")
        XCTAssertEqual(split.offers, ["Add to calendar"])
    }

    func testStreamingHidesAHalfWrittenOffer() {
        XCTAssertEqual(FollowUps.streamingBody("Answer\n»"), "Answer")
        XCTAssertEqual(FollowUps.streamingBody("Answer\n-"), "Answer")
        XCTAssertEqual(FollowUps.streamingBody("Answer\n*"), "Answer")
    }
}
