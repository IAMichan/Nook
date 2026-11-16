import XCTest

final class ChatActionSuggestionTests: XCTestCase {
    func testGateAllowsOnlyAFreshUntriedTurnWhileIdle() {
        let open = ChatActionSuggestion.Gate(enabled: true, brainReady: true, alreadyTried: false, stale: false, busy: false)
        XCTAssertTrue(open.allows)
        for change in [\ChatActionSuggestion.Gate.alreadyTried, \.stale, \.busy] {
            var gate = open
            gate[keyPath: change] = true
            XCTAssertFalse(gate.allows)
        }
        var off = open
        off.enabled = false
        XCTAssertFalse(off.allows)
        var noBrain = open
        noBrain.brainReady = false
        XCTAssertFalse(noBrain.allows)
    }

    func testStaleAfterADay() {
        let now = Date()
        XCTAssertFalse(ChatActionSuggestion.Gate.isStale(now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(ChatActionSuggestion.Gate.isStale(now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertFalse(ChatActionSuggestion.Gate.isStale(nil, now: now))
    }

    func testPromptNamesThePlaceTheLinesAndTheProjects() throws {
        let lines = [ChatActionSuggestion.Line(speaker: "Arjan", text: "https://pages.infaris.com/d/x"),
                     ChatActionSuggestion.Line(speaker: "You", text: "Eigenlijk moeten we pandabot nog toevoegen aan die pages"),
                     ChatActionSuggestion.Line(speaker: "Arjan", text: "  ")]
        let prompt = ChatActionSuggestion.prompt(place: .chat(app: "WhatsApp", name: "Arjan"), lines: lines, fresh: 2,
                                                 projects: ["/Users/me/code/infaris", "/Users/me/code/nook", "/tmp/other/infaris"],
                                                 handled: ["Start claude session: add Pandabot"])
        XCTAssertTrue(prompt.contains("WhatsApp chat with Arjan"))
        XCTAssertTrue(prompt.contains("You: Eigenlijk moeten we pandabot nog toevoegen aan die pages"))
        XCTAssertFalse(prompt.contains("Arjan:   "), "an empty line is left out")
        XCTAssertTrue(prompt.contains("infaris, nook"), "each folder name once")
        XCTAssertTrue(prompt.contains("- Start claude session: add Pandabot"))
        XCTAssertTrue(prompt.contains(ChatActionSuggestion.nothing))
        let new = try XCTUnwrap(prompt.range(of: "New since you last looked"))
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: "Arjan: https://pages")).lowerBound, new.lowerBound,
                          "the link came before the new lines")
        XCTAssertGreaterThan(try XCTUnwrap(prompt.range(of: "You: Eigenlijk")).lowerBound, new.lowerBound)
    }

    func testTranscriptKeepsTheNewestCharacters() {
        let long = String(repeating: "a", count: ChatActionSuggestion.maxTranscript)
        let text = ChatActionSuggestion.transcript([.init(speaker: "X", text: long), .init(speaker: "Y", text: "newest")])
        XCTAssertEqual(text.count, ChatActionSuggestion.maxTranscript)
        XCTAssertTrue(text.hasSuffix("Y: newest"))
        XCTAssertEqual(ChatActionSuggestion.transcript([]), "(no messages yet)")
    }

    func testKeepDropsChatMessagesRepeatsAndWhatWasOffered() {
        let steps = [("whatsapp_send", "Send to Arjan: ok"),
                     ("start_agent_session", "Start agent session: add Pandabot"),
                     ("start_agent_session", "start agent  session: add pandabot"),
                     ("create_reminder", "Reminder: call Arjan"),
                     ("create_event", "Event: demo")]
        let kept = ChatActionSuggestion.keep(steps, tool: { $0.0 }, summary: { $0.1 }, handled: ["Reminder: call Arjan"])
        XCTAssertEqual(kept.map(\.0), ["start_agent_session", "create_event"])
    }

    /// Only reactions, bare links and a word or two are left out on the Mac; the rest is the brain's to judge.
    func testOnlyReactionsAreLeftOutBeforeTheBrain() {
        func worth(_ text: String) -> Bool { ChatActionSuggestion.worthALook([.init(speaker: "X", text: text)]) }
        XCTAssertTrue(worth("Eigenlijk moeten we pandabot nog toevoegen aan die pages"))
        XCTAssertTrue(worth("pandabot op die pages zou mooi zijn"), "a wish without a cue word still counts")
        XCTAssertTrue(worth("Can you fix the login page today?"))
        XCTAssertTrue(worth("Tenemos que arreglar el login mañana"))
        for chatter in ["Okaaayy", "👍", "haha ok", "Thanks a lot for this!", "ok top, bedankt",
                        "https://pages.infaris.com/d/cmwjl563x000106peau8u5t7w"] {
            XCTAssertFalse(worth(chatter), chatter)
        }
    }

    func testVagueStepsAreDropped() {
        let task = "Add the Pandabot chat widget to every page under apps/pages in the Infaris monorepo, using the existing embed script."
        XCTAssertTrue(ChatActionSuggestion.complete(tool: "start_agent_session", input: ["task": task, "folder": "infaris"]))
        XCTAssertFalse(ChatActionSuggestion.complete(tool: "start_agent_session", input: ["task": task]), "no folder")
        XCTAssertFalse(ChatActionSuggestion.complete(tool: "start_agent_session", input: ["task": "Add pandabot", "folder": "infaris"]))
        XCTAssertFalse(ChatActionSuggestion.complete(tool: "create_reminder", input: ["title": "Pandabot"]))
        XCTAssertTrue(ChatActionSuggestion.complete(tool: "create_reminder", input: ["title": "Call Arjan about Pandabot"]))
        XCTAssertFalse(ChatActionSuggestion.complete(tool: "create_event", input: ["title": "Demo"]))
        XCTAssertTrue(ChatActionSuggestion.complete(tool: "create_event", input: ["title": "Demo", "start": "2026-11-17T10:00"]))
    }

    func testNewLinesAreThoseAfterTheLastLook() {
        let lines = (1...6).map { ChatActionSuggestion.Line(speaker: "X", text: "line \($0)", id: "m\($0)") }
        XCTAssertEqual(ChatActionSuggestion.newLines(lines, since: "m4").map(\.id), ["m5", "m6"])
        XCTAssertEqual(ChatActionSuggestion.newLines(lines, since: "m6"), [])
        XCTAssertEqual(ChatActionSuggestion.newLines(lines, since: nil).map(\.id), ["m4", "m5", "m6"])
        XCTAssertEqual(ChatActionSuggestion.newLines(lines, since: "gone").count, 3)
    }

    func testPaceOnlyBoundsTheCost() {
        let now = Date()
        let calm = ChatActionSuggestion.Pace(lastLook: nil, waiting: false, looksThisHour: 0)
        XCTAssertTrue(calm.allows(now: now))
        var pace = calm
        pace.waiting = true
        XCTAssertFalse(pace.allows(now: now), "not while one still waits")
        pace = calm
        pace.lastLook = now.addingTimeInterval(-2)
        XCTAssertFalse(pace.allows(now: now), "one look for a quick burst")
        pace.lastLook = now.addingTimeInterval(-10)
        XCTAssertTrue(pace.allows(now: now))
        pace = calm
        pace.looksThisHour = ChatActionSuggestion.Pace.looksPerHour
        XCTAssertFalse(pace.allows(now: now))
    }
}
