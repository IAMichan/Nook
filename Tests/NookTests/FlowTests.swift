import XCTest

/// Flow, dictation anywhere: the key, the dictionary, the merging of recognizer results and the clean-up's checks.
/// Partly after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
final class FlowTests: XCTestCase {
    func testHoldToDictateAndDoubleTapForHandsFree() {
        var logic = FlowKeyLogic()
        XCTAssertEqual(logic.keyDown(at: 0), .start)
        XCTAssertEqual(logic.keyDown(at: 0.1), .none, "key repeat")
        XCTAssertEqual(logic.keyUp(at: 1.0), .finish, "a hold pastes on release")

        XCTAssertEqual(logic.keyDown(at: 10), .start)
        XCTAssertEqual(logic.keyUp(at: 10.1), .none, "a tap waits for a second one")
        XCTAssertEqual(logic.keyDown(at: 10.3), .lock, "two taps: hands-free")
        XCTAssertEqual(logic.keyDown(at: 20), .finish, "the next tap ends it")

        XCTAssertEqual(logic.keyDown(at: 30), .start)
        XCTAssertEqual(logic.keyUp(at: 30.1), .none)
        XCTAssertEqual(logic.tick(at: 31), .cancel, "a lone tap is dropped")

        XCTAssertEqual(logic.keyDown(at: 40), .start)
        XCTAssertEqual(logic.otherKey(), .cancel, "⌥E is a shortcut, not dictation")
        XCTAssertEqual(logic.keyDown(at: 50), .start)
        XCTAssertEqual(logic.escape(), .cancel)
    }

    func testTheRightKeyOnly() {
        XCTAssertTrue(FlowKey.rightOption.isDown(rawFlags: 0x0008_0040))
        XCTAssertFalse(FlowKey.rightOption.isDown(rawFlags: 0x0008_0020), "the left ⌥ is not the right one")
        XCTAssertTrue(FlowKey.fn.isDown(rawFlags: 0x0080_0000))
        XCTAssertEqual(FlowKey.rightCommand.keyCode, 0x36)
    }

    func testDictionaryReplacementsAndSnippets() {
        let parsed = FlowDictionaryText.parse("""
        Supabase
        cloud code => Claude Code
        # a comment
        mijn handtekening :: Groet,\\nMichan
        supabase
        """)
        XCTAssertEqual(parsed.words, ["Supabase"])
        XCTAssertEqual(parsed.replacements.first?.to, "Claude Code")
        XCTAssertEqual(parsed.snippets.first?.text, "Groet,\nMichan")

        let text = FlowText.apply("ik gebruik supabase met cloud code. mijn handtekening", words: parsed.words,
                                  replacements: parsed.replacements, snippets: parsed.snippets)
        XCTAssertEqual(text, "ik gebruik Supabase met Claude Code. Groet,\nMichan")
        XCTAssertEqual(FlowText.replacing("art", with: "ART", in: "partir art"), "partir ART", "whole words only")

        let back = FlowDictionaryText.parse(FlowDictionaryText.format(words: parsed.words, replacements: parsed.replacements, snippets: parsed.snippets))
        XCTAssertEqual(back.words, parsed.words)
        XCTAssertEqual(back.snippets.first?.text, "Groet,\nMichan")
    }

    func testSnippetsSurviveTheCleanUp() {
        let prepared = FlowText.prepare("stuur mijn handtekening", words: [], replacements: [],
                                        snippets: [FlowSnippet(trigger: "mijn handtekening", text: "Groet, Michan")])
        XCTAssertEqual(prepared.text, "stuur ⟦1⟧")
        XCTAssertTrue(FlowText.keepsMarks("Stuur ⟦1⟧.", prepared.snippets))
        XCTAssertFalse(FlowText.keepsMarks("Stuur.", prepared.snippets))
        XCTAssertEqual(FlowText.finish("Stuur ⟦1⟧.", snippets: prepared.snippets), "Stuur Groet, Michan.")
    }

    func testCleanUpChecks() {
        XCTAssertEqual(FlowCleanup.clean(reply: "<think>hm</think>\n\"Om 4 uur bij jou.\""), "Om 4 uur bij jou.")
        XCTAssertTrue(FlowCleanup.plausible("Om 4 uur bij jou.", from: "eh om 3 uur nee om 4 uur bij jou"))
        XCTAssertFalse(FlowCleanup.plausible("Natuurlijk! Hier is een uitgebreid antwoord op je vraag over de planning van morgen en alles wat erbij komt kijken, met tips.", from: "om 4 uur"))
        XCTAssertFalse(FlowCleanup.plausible("", from: "om 4 uur"))
        XCTAssertTrue(FlowCleanup.plausibleTransform("Goal: fix the login\nSteps:\n1. …", from: "fix de login", prompt: true))
        let system = FlowCleanup.system(style: .polished, prompt: false, language: nil, app: "Mail", words: ["Nook"])
        XCTAssertTrue(system.contains("Never translate"))
        XCTAssertTrue(system.contains("pasted in Mail"))
        XCTAssertTrue(FlowCleanup.system(style: .natural, prompt: false, language: "English", app: nil, words: []).contains("in English"))
    }

    func testStyleSuggestedPerApp() {
        XCTAssertEqual(FlowStyle.suggested(for: "com.apple.Terminal"), .verbatim)
        XCTAssertEqual(FlowStyle.suggested(for: "com.microsoft.VSCode"), .verbatim)
        XCTAssertEqual(FlowStyle.suggested(for: "com.apple.mail"), .polished)
        XCTAssertEqual(FlowStyle.suggested(for: "net.whatsapp.WhatsApp"), .natural)
    }

    func testTranscriptKeepsWhatARestartWouldLose() {
        var transcript = DictationTranscript()
        transcript.absorb("ik ben om acht uur")
        transcript.absorb("thuis")
        XCTAssertEqual(transcript.text, "ik ben om acht uur thuis")
    }

    func testNumbers() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var stats = FlowStats()
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        stats.record(words: 120, seconds: 60, app: "Mail", on: today, calendar: calendar)
        stats.record(words: 30, seconds: 15, app: "Mail", on: today.addingTimeInterval(-86_400), calendar: calendar)
        XCTAssertEqual(stats.totalWords, 150)
        XCTAssertEqual(stats.apps["Mail"], 150)
        XCTAssertEqual(stats.streak(today: today, calendar: calendar), 2)
        XCTAssertEqual(FlowText.wordsPerMinute(words: 150, seconds: 75), 120)
    }
}
