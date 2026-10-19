import XCTest

/// Think-along offers: a clean teaser, nothing about dates far away, and no reworded repeats.
final class NudgeFilterTests: XCTestCase {
    private let now = NookDates.parse("2026-10-19T10:00:00")!

    func testLineKeepsAPeriodInsideAWord() {
        let body = "Zal ik hem herinneren aan de deadline van IMDigital.info? IMDigital.info wordt verlengd op 2027-09-20."
        XCTAssertEqual(NudgeFilter.line(body: body, fallback: nil), "Zal ik hem herinneren aan de deadline van IMDigital.info?")
    }

    func testLineEndsAtTheFirstSentenceAndFallsBack() {
        XCTAssertEqual(NudgeFilter.line(body: "Tip: dit kan in één keer. Gebruik **zoeken**.", fallback: nil), "Tip: dit kan in één keer.")
        XCTAssertEqual(NudgeFilter.line(body: "", fallback: "Zal ik dit doen?"), "Zal ik dit doen?")
    }

    func testFarOffDatesAreNoReasonToSpeakUp() {
        XCTAssertTrue(NudgeFilter.isFarOff([NookDates.parse("2027-09-20T00:00:00")!], now: now), "a renewal next year")
        XCTAssertFalse(NudgeFilter.isFarOff([NookDates.parse("2026-10-21T09:00:00")!], now: now), "the day after tomorrow")
        XCTAssertFalse(NudgeFilter.isFarOff([NookDates.parse("2027-09-20T00:00:00")!, NookDates.parse("2026-10-20T09:00:00")!], now: now))
        XCTAssertFalse(NudgeFilter.isFarOff([], now: now), "no dates, nothing to judge")
    }

    func testRewordedOffersCountAsTheSame() {
        XCTAssertTrue(NudgeFilter.similar("Zal ik hem herinneren aan de deadline van IMDigital.info?",
                                          "Zal ik je herinneren aan de verlenging van IMDigital.info?"))
        XCTAssertFalse(NudgeFilter.similar("Zal ik hem herinneren aan de deadline van IMDigital.info?",
                                           "Zal ik een concept-antwoord aan Sanne schrijven?"))
    }

    func testNumericDatesAreReadInBothOrders() {
        let body = "Tip: dit kan ook in één keer.\nZal ik hem herinneren aan de deadline van IMDigital.info (2027-09-20)?"
        XCTAssertEqual(NudgeFilter.numericDates(in: body).count, 1)
        XCTAssertTrue(NudgeFilter.isFarOff(NudgeFilter.numericDates(in: body), now: now))
        XCTAssertTrue(NudgeFilter.isFarOff(NudgeFilter.numericDates(in: "verloopt op 20-09-2027"), now: now))
        XCTAssertFalse(NudgeFilter.isFarOff(NudgeFilter.numericDates(in: "deadline 20/10/2026"), now: now))
        XCTAssertTrue(NudgeFilter.numericDates(in: "versie 1.2.3, build 2027-13-40").isEmpty)
    }

    func testAQuestionAnywhereNeedsAnAction() {
        let body = "Tip: dit kan ook in één keer.\nZal ik hem herinneren aan de deadline van IMDigital.info (2027-09-20)?"
        XCTAssertTrue(NudgeFilter.asksWithoutAction(body, hasActions: false), "the question hides behind a tip on the first line")
        XCTAssertFalse(NudgeFilter.asksWithoutAction(body, hasActions: true))
        XCTAssertFalse(NudgeFilter.asksWithoutAction("Tip: met ⌘⇧T open je het tabblad weer.", hasActions: false))
    }
}
