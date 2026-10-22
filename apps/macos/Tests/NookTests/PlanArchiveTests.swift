import XCTest

/// A plan in an old conversation shows as a plan again, also when an older version saved it as text.
final class PlanArchiveTests: XCTestCase {
    func testAPlanSavedAsTextIsReadBackStepByStep() throws {
        let text = "Done.\n\n_Plan:_\n_1. WhatsApp → Arjan: Hoi Arjan,\n\nInstalleer Nook. · ✓ WhatsApp message sent to Arjan._\n"
            + "_2. Reminder: call back · not executed_"
        let legacy = try XCTUnwrap(StoredPlan.legacy(in: text))
        XCTAssertEqual(legacy.text, "Done.")
        XCTAssertEqual(legacy.plan.steps.map(\.summary), ["WhatsApp → Arjan: Hoi Arjan,\n\nInstalleer Nook.", "Reminder: call back"])
        XCTAssertEqual(legacy.plan.steps.map(\.state), [.done("WhatsApp message sent to Arjan."), .pending])
        XCTAssertEqual(legacy.plan.outcome, "done")
    }

    func testAPlanWithoutTextBeforeItAndEveryOutcome() throws {
        let text = "_Plan:_\n_1. A · ✓✓ checked_\n_2. B · ✗ failed: no access_\n_3. C · skipped_\n_4. D · already completed on Monday_"
        let legacy = try XCTUnwrap(StoredPlan.legacy(in: text))
        XCTAssertEqual(legacy.text, "")
        XCTAssertEqual(legacy.plan.steps.map(\.state), [.verified("checked"), .failed("no access"), .skipped, .duplicate("Monday")])
        XCTAssertEqual(legacy.plan.steps.map(\.included), [true, true, false, true])
        XCTAssertEqual(legacy.plan.outcome, "failed")
    }

    func testACancelledPlanStaysCancelled() throws {
        let legacy = try XCTUnwrap(StoredPlan.legacy(in: "_Plan:_\n_1. Event · Tue · cancelled_"))
        XCTAssertEqual(legacy.plan.steps.first?.summary, "Event · Tue")
        XCTAssertEqual(legacy.plan.outcome, "cancelled")
    }

    func testTextThatOnlyMentionsAPlanIsLeftAlone() {
        XCTAssertNil(StoredPlan.legacy(in: "Here is the plan."))
        XCTAssertNil(StoredPlan.legacy(in: "See _Plan:_\n_1. A · ✓ ok_"))
        XCTAssertNil(StoredPlan.legacy(in: "_Plan:_\n_1. A without an outcome_"))
    }

    func testAStoredPlanSurvivesEncoding() throws {
        let plan = StoredPlan(steps: [.init(tool: "send_whatsapp", summary: "WhatsApp → Arjan", input: #"{"to":"Arjan"}"#,
                                            state: .done("sent"), included: true)], outcome: "done", detail: "1 of 1")
        let decoded = try JSONDecoder().decode(StoredPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
    }
}
