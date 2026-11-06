import XCTest

final class ContextHandoffPortableTests: XCTestCase {
    private func user(_ text: String) -> RunEvent { RunEvent(kind: .user, text: text) }
    private func agent(_ text: String) -> RunEvent { RunEvent(kind: .assistant, text: text) }

    func testMessagesKeepTheirOwnWords() {
        let text = (0..<40).map { "line \($0) of a long request" }.joined(separator: "\n")
        let rendered = ContextHandoff.render(events: [user(text)], source: "Codex")
        XCTAssertTrue(rendered?.text.contains(text) == true)
    }

    func testAShortConversationStaysInOrder() {
        let rendered = ContextHandoff.render(events: [user("first"), agent("second"), user("third")], source: "Codex")
        let text = rendered?.text ?? ""
        XCTAssertEqual(rendered?.omitted, 0)
        XCTAssertLessThan(text.range(of: "first")!.lowerBound, text.range(of: "second")!.lowerBound)
        XCTAssertLessThan(text.range(of: "second")!.lowerBound, text.range(of: "third")!.lowerBound)
    }

    func testTheFirstRequestOutlastsTheBudgetAndTheRestCanBeRead() {
        let id = UUID()
        let events = [user("the original request")] + (0..<200).map { agent("answer \($0) " + String(repeating: "x", count: 500)) }
        let rendered = ContextHandoff.render(events: events, source: "Codex", budget: 2_000, session: id)
        let text = rendered?.text ?? ""
        XCTAssertTrue(text.contains("the original request"))
        XCTAssertTrue(text.contains("answer 199"))
        XCTAssertFalse(text.contains("answer 0 "))
        XCTAssertTrue(text.contains("session_read"))
        XCTAssertTrue(text.contains(id.uuidString))
        XCTAssertGreaterThan(rendered?.omitted ?? 0, 0)
    }

    func testTheFirstRequestKeepsItsPlaceBehindEarlierActivity() {
        var ran = RunEvent(kind: .tool, text: "setup")
        ran.state = .done
        let rendered = ContextHandoff.render(events: [ran, user("alpha"), agent("omega")], source: "Codex")?.text ?? ""
        XCTAssertLessThan(rendered.range(of: "setup")!.lowerBound, rendered.range(of: "alpha")!.lowerBound)
        XCTAssertLessThan(rendered.range(of: "alpha")!.lowerBound, rendered.range(of: "omega")!.lowerBound)
    }

    func testAGapIsMarkedWhereItIs() {
        var ran = RunEvent(kind: .tool, text: "setup")
        ran.state = .done
        let long = (0..<60).map { agent("answer \($0) " + String(repeating: "x", count: 300)) }
        let text = ContextHandoff.render(events: [ran, user("alpha")] + long, source: "Codex", budget: 600)?.text ?? ""
        XCTAssertLessThan(text.range(of: "alpha")!.lowerBound, text.range(of: "(…)")!.lowerBound)
        XCTAssertLessThan(text.range(of: "(…)")!.lowerBound, text.range(of: "answer 59")!.lowerBound)
    }

    func testWithoutNooksToolsNoPointer() {
        let events = [user("a")] + (0..<200).map { agent("answer \($0) " + String(repeating: "x", count: 500)) }
        XCTAssertFalse(ContextHandoff.render(events: events, source: "Codex", budget: 2_000)?.text.contains("session_read") == true)
    }

    func testAHugeMessageIsCutOpenly() {
        let rendered = ContextHandoff.render(events: [user(String(repeating: "y", count: ContextHandoff.messageLimit + 10))], source: "Codex")
        XCTAssertTrue(rendered?.text.contains("(cut here)") == true)
    }
}
