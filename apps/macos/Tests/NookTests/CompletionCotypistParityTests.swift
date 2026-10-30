import XCTest

/// British or American spelling, emoticons, the word being typed, coding agent prompts in terminals and their fonts.
final class CompletionCotypistParityTests: XCTestCase {
    // MARK: Spelling

    func testSpellingFollowsTheFieldPerFamily() {
        let british = CompletionSpelling.habit(in: "My favourite colour is grey.")
        XCTAssertEqual(british.variant(for: .our), .british)
        XCTAssertEqual(CompletionSpelling.apply(british, to: " flavor and behavior", before: "the "), " flavour and behaviour")
        // "-ize" is British too (Oxford): "colour" says nothing about it.
        XCTAssertNil(british.variant(for: .ise))
        XCTAssertEqual(CompletionSpelling.apply(british, to: " organize it", before: "we"), " organize it")

        let american = CompletionSpelling.habit(in: "We will organize the center and analyze the color.")
        XCTAssertEqual(CompletionSpelling.apply(american, to: " Organised, centred and travelled", before: "It was"),
                       " Organized, centered and traveled")
        XCTAssertEqual(CompletionSpelling.convert("COLOUR", habit: american), "COLOR")
    }

    func testSpellingLeavesMixedAndUnknownTextAlone() {
        let mixed = CompletionSpelling.habit(in: "colour color")
        XCTAssertTrue(mixed.isEmpty)
        XCTAssertEqual(CompletionSpelling.apply(mixed, to: " flavour", before: "a"), " flavour")
        // Words that are -ise everywhere, and other words, never change.
        let american = CompletionSpelling.habit(in: "color")
        XCTAssertEqual(CompletionSpelling.apply(american, to: " surprise and advertise the programme", before: "a"),
                       " surprise and advertise the programme")
    }

    func testSpellingFinishesTheTypedWordInTheUsersVariant() {
        let american = CompletionSpelling.habit(in: "favorite")
        // "colo" + "ur" is "colour": in American only "r" is left to suggest.
        XCTAssertEqual(CompletionSpelling.apply(american, to: "ur scheme", before: "the colo"), "r scheme")
        // The user already typed "colou": that is how they want it.
        XCTAssertEqual(CompletionSpelling.apply(american, to: "r scheme", before: "the colou"), "r scheme")
    }

    func testSpellingHabitFromWritingNeedsAClearMajority() {
        let habit = CompletionSpelling.habit(words: [("colour", 9), ("color", 1)])
        XCTAssertEqual(habit.variant(for: .our), .british)
        XCTAssertTrue(CompletionSpelling.habit(words: [("colour", 3), ("color", 2)]).isEmpty)
        // The field's own text goes first.
        let field = CompletionSpelling.habit(in: "color").filling(from: habit)
        XCTAssertEqual(field.variant(for: .our), .american)
    }

    // MARK: Emoticons

    func testEmoticonAtTheEndOfAWord() {
        XCTAssertEqual(CompletionEmojiCatalog.emoticon(endingAt: "see you :-)")?.emoji, "🙂")
        XCTAssertEqual(CompletionEmojiCatalog.emoticon(endingAt: "love you <3")?.emoticon, "<3")
        XCTAssertEqual(CompletionEmojiCatalog.emoticon(endingAt: ";)")?.emoji, "😉")
        XCTAssertNil(CompletionEmojiCatalog.emoticon(endingAt: "see https:/"))
        XCTAssertNil(CompletionEmojiCatalog.emoticon(endingAt: "(see note:)"))
        XCTAssertNil(CompletionEmojiCatalog.emoticon(endingAt: "plan B)"))
        XCTAssertNil(CompletionEmojiCatalog.emoticon(endingAt: "done :) "))
    }

    func testPickerPutsTheEmoticonFirst() {
        let grin = CompletionEmojiCatalog.choices(for: "D", recent: [], limit: 8)
        XCTAssertEqual(grin.first?.character, "😄")
    }

    // MARK: The word being typed

    func testWordBeingTyped() {
        XCTAssertEqual(CompletionTextAnalysis.wordBeingTyped(in: "I will recie"), "recie")
        XCTAssertNil(CompletionTextAnalysis.wordBeingTyped(in: "I will "))
        XCTAssertNil(CompletionTextAnalysis.wordBeingTyped(in: "the cat"))
        XCTAssertNil(CompletionTextAnalysis.wordBeingTyped(in: "call McDonal"))
        XCTAssertNil(CompletionTextAnalysis.wordBeingTyped(in: "see v2abcd"))
        XCTAssertEqual(CompletionTextAnalysis.wordBeingTyped(in: "\"Hallo"), "Hallo")
    }

    // MARK: Terminals

    func testClaudeCodePromptBetweenRules() {
        let screen = """
        ⏺ I updated the file.

        ────────────────────────────────────────────
        > please also update the docs and
          then run the
        """
        let after = """
         tests
        ────────────────────────────────────────────
          ? for shortcuts
        """
        let prompt = CompletionTerminal.agentPrompt(before: screen, after: after)
        XCTAssertEqual(prompt, CompletionTerminal.Prompt(before: "please also update the docs and then run the", after: " tests"))
    }

    func testGeminiBoxPrompt() {
        let screen = "╭──────────────────────────────╮\n│ > explain this error │"
        // The cursor is after "error ", the right side of the box is after it.
        let prompt = CompletionTerminal.agentPrompt(before: "╭──────────────────────────────╮\n│ > explain this error ",
                                                    after: "  │\n╰──────────────────────────────╯")
        XCTAssertEqual(prompt?.before, "explain this error ")
        XCTAssertEqual(prompt?.after, "")
        XCTAssertNil(CompletionTerminal.agentPrompt(before: screen, after: ""))
    }

    func testCodexPromptWithFooter() {
        let prompt = CompletionTerminal.agentPrompt(before: "› fix the failing", after: "\n\n  ⏎ send   ⌃J newline   100% context left")
        XCTAssertEqual(prompt?.before, "fix the failing")
    }

    func testShellIsNotAnAgentPrompt() {
        XCTAssertNil(CompletionTerminal.agentPrompt(before: "michan@mac ~ % git sta", after: ""))
        // A heredoc's continuation prompt.
        XCTAssertNil(CompletionTerminal.agentPrompt(before: "% cat <<EOF\n> some text", after: "\n"))
        XCTAssertNil(CompletionTerminal.inputStart("->x"))
        XCTAssertEqual(CompletionTerminal.inputStart("│ > hi"), "hi")
    }

    func testOnlyAgentPromptsInTerminalsByDefault() {
        var prefs = CompletionPreferences()
        prefs.enabled = true
        XCTAssertFalse(prefs.isEnabled(inApp: "com.apple.Terminal"))
        XCTAssertTrue(prefs.onlyAgentPrompts(inApp: "com.apple.Terminal"))
        XCTAssertFalse(prefs.onlyAgentPrompts(inApp: "com.apple.TextEdit"))
        prefs.apps["com.apple.Terminal"] = CompletionAppRule(enabled: .off)
        XCTAssertFalse(prefs.onlyAgentPrompts(inApp: "com.apple.Terminal"))
        prefs.apps["com.apple.Terminal"] = CompletionAppRule(enabled: .on)
        // On for the shell too: then it is not "only".
        XCTAssertFalse(prefs.onlyAgentPrompts(inApp: "com.apple.Terminal"))
        prefs.apps = [:]
        prefs.agentPromptsInTerminals = false
        XCTAssertFalse(prefs.onlyAgentPrompts(inApp: "com.apple.Terminal"))
    }

    func testNewSettingsSurviveOldStoredPreferences() throws {
        let old = try JSONSerialization.data(withJSONObject: ["enabled": true, "apps": ["com.slack.Slack": ["leaveTab": true]]])
        let prefs = CompletionPreferences.decode(old)
        XCTAssertTrue(prefs.holdOnTypo)
        XCTAssertTrue(prefs.matchSpelling)
        XCTAssertTrue(prefs.emoticons)
        XCTAssertTrue(prefs.agentPromptsInTerminals)
        XCTAssertEqual(prefs.app("com.slack.Slack").insertMode, .keys)
        XCTAssertTrue(prefs.app("com.slack.Slack").leaveTab)
    }

    // MARK: Terminal fonts

    func testTerminalFontsFromTheirSettings() {
        XCTAssertEqual(CompletionTerminal.iTermFont("MesloLGS-NF-Regular 13"), CompletionTerminal.Font(name: "MesloLGS-NF-Regular", size: 13))
        XCTAssertEqual(CompletionTerminal.ghosttyFont("# mine\nfont-family = \"JetBrains Mono\"\nfont-family = Symbols\nfont-size = 14\n"),
                       CompletionTerminal.Font(name: "JetBrains Mono", size: 14))
        XCTAssertNil(CompletionTerminal.ghosttyFont("theme = dark"))
        XCTAssertEqual(CompletionTerminal.kittyFont("font_family      Fira Code\nfont_size 12.5"), CompletionTerminal.Font(name: "Fira Code", size: 12.5))
        XCTAssertNil(CompletionTerminal.kittyFont("font_family monospace"))
    }

    // MARK: Emoji people and tones

    func testEmojiGenderJoinsTheSign() {
        let shrug = CompletionEmoji(character: "🤷", shortcodes: ["shrug"], toneable: true)
        XCTAssertEqual(CompletionEmojiCatalog.render(shrug, skinTone: 0, gender: 1), "🤷\u{200D}♀\u{FE0F}")
        XCTAssertEqual(CompletionEmojiCatalog.render(shrug, skinTone: 3, gender: 2), "🤷🏽\u{200D}♂\u{FE0F}")
        XCTAssertEqual(CompletionEmojiCatalog.render(shrug, skinTone: 0), "🤷")
        let thumbs = CompletionEmoji(character: "👍", shortcodes: ["+1"], toneable: true)
        XCTAssertEqual(CompletionEmojiCatalog.render(thumbs, skinTone: 1, gender: 2), "👍🏻")
    }

    func testNeutralVariantFollowsEachTonedEmoji() {
        let thumbs = CompletionEmoji(character: "👍", shortcodes: ["+1"], toneable: true)
        let heart = CompletionEmoji(character: "❤️", shortcodes: ["heart"], toneable: false)
        let shown = CompletionEmojiCatalog.withNeutralVariants([thumbs, heart], skinTone: 2)
        XCTAssertEqual(shown.map { CompletionEmojiCatalog.render($0, skinTone: 2) }, ["👍🏼", "👍", "❤️"])
        XCTAssertEqual(CompletionEmojiCatalog.withNeutralVariants([thumbs], skinTone: 0), [thumbs])
    }

    // MARK: Recorded texts, force-activate, settings

    func testOneRecordedTextIsDeleted() {
        var samples = CompletionSamples()
        samples.add("A first message that is long enough", app: "a")
        samples.add("A second message, also long enough", app: "b")
        samples.remove(samples.samples[0])
        XCTAssertEqual(samples.samples.map(\.app), ["b"])
    }

    func testSuggestNowKeyIsTakenWhereItCanForce() {
        var gate = CompletionKeyGate()
        let key = CompletionShortcut(keyCode: 49, modifiers: CompletionShortcut.control, label: "⌃Space")
        gate.suggestNow = key
        let press = CompletionKeyPress(code: 49, modifiers: CompletionShortcut.control, characters: " ")
        XCTAssertFalse(gate.swallows(press))
        gate.canForce = true
        XCTAssertTrue(gate.swallows(press))
    }

    func testLaterSettingsDefaults() throws {
        let prefs = CompletionPreferences.decode(try JSONSerialization.data(withJSONObject: ["enabled": true]))
        XCTAssertEqual(prefs.emojiGender, 0)
        XCTAssertFalse(prefs.neutralEmoji)
        XCTAssertEqual(prefs.loraAdapterPath, "")
        XCTAssertTrue(CompletionPreferences.passwordManagers.isSubset(of: CompletionPreferences.offByDefault))
        var rule = CompletionAppRule()
        rule.insertMode = .spaceKey
        let decoded = try JSONDecoder().decode(CompletionAppRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(decoded.insertMode, .spaceKey)
    }
}
