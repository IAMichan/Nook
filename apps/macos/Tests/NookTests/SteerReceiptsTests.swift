import XCTest

/// "Steer · waiting to be read" (`SteerReceipts`): which steer an agent's echo reads, what a turn's end makes of the
/// ones still waiting, the echoes Pi and Codex send, and that saved timelines without the field still load.
final class SteerReceiptsTests: XCTestCase {
    private func steer(_ text: String, _ status: RunEvent.SteerStatus? = .pending) -> RunEvent {
        var event = RunEvent(kind: .user, text: text)
        event.steer = .steer
        event.steerStatus = status
        return event
    }

    func testEchoReadsTheSteerWithTheSameWordsElseTheOldest() {
        let first = steer("use the new API")
        let second = steer("and keep the  tests")
        let events = [RunEvent(kind: .user, text: "fix the bug"), first, RunEvent(kind: .assistant, text: "ok"), second]
        XCTAssertEqual(SteerReceipts.read(in: events, echo: "and keep the tests", turnPrompt: "fix the bug"), second.id)
        // Words the agent changed on the way (context it added) still read the oldest waiting steer.
        XCTAssertEqual(SteerReceipts.read(in: events, echo: "something else", turnPrompt: "fix the bug"), first.id)
        XCTAssertEqual(SteerReceipts.read(in: events, echo: nil, turnPrompt: nil), first.id)
    }

    func testTheTurnsOwnPromptReadsNoSteer() {
        let waiting = steer("stop and explain")
        let events = [RunEvent(kind: .user, text: "fix the bug"), waiting]
        XCTAssertNil(SteerReceipts.read(in: events, echo: "fix the bug", turnPrompt: "fix the bug"))
        XCTAssertNil(SteerReceipts.read(in: [steer("x", nil)], echo: "x", turnPrompt: nil))
    }

    func testATurnsEndReadsOrDropsWhatStillWaits() {
        let waiting = steer("one")
        let read = steer("two", nil)
        let events = [waiting, read]
        XCTAssertEqual(SteerReceipts.settled(events, dropped: false).map(\.id), [waiting.id])
        XCTAssertNil(SteerReceipts.settled(events, dropped: false).first?.status)
        XCTAssertEqual(SteerReceipts.settled(events, dropped: true).first?.status, .cancelled)
    }

    func testOldTimelinesStillDecode() throws {
        let event = steer("hi")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(object["steerStatus"] as? String, "pending")
        object["steerStatus"] = nil
        let decoded = try JSONDecoder().decode(RunEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.steerStatus)
        XCTAssertEqual(decoded.steer, .steer)
    }

    func testOnlyAgentsThatEchoSteersMarkThemPending() {
        for provider in RunProvider.allCases {
            let capabilities = provider.capabilities
            // An agent that echoes steers steers natively; one steered by an interrupt reads the steer as its next prompt.
            if capabilities.echoesSteers { XCTAssertTrue(capabilities.steering, provider.rawValue) }
        }
        XCTAssertTrue(RunProvider.pi.capabilities.echoesSteers)
        XCTAssertTrue(RunProvider.codex.capabilities.echoesSteers)
        XCTAssertFalse(RunProvider.claude.capabilities.echoesSteers)
    }

    func testPiEchoesAMessageOfYoursAsItsUserMessageStart() {
        let string = #"{"type":"message_start","message":{"role":"user","content":"keep going"}}"#
        XCTAssertEqual(PiStreamParser.parse(string), [.userMessage("keep going")])
        let parts = #"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"a"}]}}"#
        XCTAssertEqual(PiStreamParser.parse(parts), [.userMessage("a")])
        let assistant = #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#
        XCTAssertEqual(PiStreamParser.parse(assistant), [])
    }

    func testCodexEchoesAMessageOfYoursAsAUserMessageItem() throws {
        let line = #"{"method":"item/started","params":{"threadId":"t1","turnId":"u1","item":{"type":"userMessage","id":"i1","content":[{"type":"text","text":"use the new API"},{"type":"image","url":"x"}]}}}"#
        let message = try XCTUnwrap(CodexRPC.parse(line))
        XCTAssertEqual(CodexAppServerMapper.events(message), [.userMessage(text: "use the new API", thread: "t1")])
    }
}
