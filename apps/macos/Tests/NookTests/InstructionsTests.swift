import XCTest

/// Answer styles, saved prompts, spaces, the context breakdown, `nook://` deep links and the shortcut cheat sheet.
final class InstructionsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "nook.tests.instructions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Response styles

    func testStandardStyleAddsNothing() {
        XCTAssertNil(ResponseStyle.standard.contextLine)
        for style in ResponseStyle.allCases where style != .standard {
            XCTAssertTrue(style.contextLine?.contains("Answer style") == true)
        }
    }

    func testStyleIsPerConversationAndFollowsTheDefault() {
        let store = ResponseStyleStore(defaults: freshDefaults())
        let a = UUID(), b = UUID()
        XCTAssertEqual(store.style(for: a), .standard)
        store.set(.concise, for: a)
        XCTAssertEqual(store.style(for: a), .concise)
        XCTAssertEqual(store.style(for: b), .standard)
        store.defaultStyle = .formal
        XCTAssertEqual(store.style(for: b), .formal)
        XCTAssertEqual(store.style(for: a), .concise)
        // Choosing the default again drops the conversation's own choice.
        store.set(.formal, for: a)
        store.defaultStyle = .casual
        XCTAssertEqual(store.style(for: a), .casual)
        store.set(.concise, for: a)
        store.forget(a)
        XCTAssertEqual(store.style(for: a), .casual)
    }

    // MARK: Saved prompts

    func testVariablesAreFoundOnceInOrderWithDefaults() {
        let prompt = SavedPrompt(title: "Mail", body: "Write {{tone|friendly}} mail to {{ person }} about {{topic}}. Thanks, {{person}}")
        XCTAssertEqual(prompt.variables, [
            SavedPrompt.Variable(name: "tone", defaultValue: "friendly"),
            SavedPrompt.Variable(name: "person", defaultValue: ""),
            SavedPrompt.Variable(name: "topic", defaultValue: ""),
        ])
    }

    func testRenderFillsValuesThenDefaults() {
        let prompt = SavedPrompt(title: "Mail", body: "A {{tone|friendly}} mail to {{person}}, {{person}}!")
        XCTAssertEqual(prompt.render(["person": "Anna"]), "A friendly mail to Anna, Anna!")
        XCTAssertEqual(prompt.render(["tone": "formal", "person": "Bob"]), "A formal mail to Bob, Bob!")
        XCTAssertEqual(prompt.render([:]), "A friendly mail to , !")
    }

    func testLibraryKeepsOneTriggerPerPromptAndSkipsEmptyOnes() {
        var library = PromptLibrary()
        XCTAssertFalse(library.save(SavedPrompt(title: " ", body: "x")))
        XCTAssertFalse(library.save(SavedPrompt(title: "x", body: "  ")))
        XCTAssertTrue(library.save(SavedPrompt(title: "Summarize", body: "Summarize {{text}}", trigger: "/Summarize!")))
        XCTAssertEqual(library.prompts.first?.trigger, "summarize")
        XCTAssertTrue(library.save(SavedPrompt(title: "Other", body: "Other", trigger: "summarize")))
        XCTAssertEqual(library.prompts.first?.trigger, "", "the trigger belongs to the first prompt")
        XCTAssertEqual(library.prompt(trigger: "/summarize")?.title, "Summarize")
    }

    func testMatchesPutTriggersFirst() {
        var library = PromptLibrary()
        library.save(SavedPrompt(title: "Weekly notes", body: "Write the sum of the week"))
        library.save(SavedPrompt(title: "Sum up", body: "Sum up {{text}}", trigger: "sum"))
        XCTAssertEqual(library.matches("sum").map(\.title), ["Sum up", "Weekly notes"])
        XCTAssertEqual(library.matches("").count, 2)
        XCTAssertTrue(library.matches("zzz").isEmpty)
    }

    func testLibraryRoundTripsThroughJSON() throws {
        var library = PromptLibrary()
        library.save(SavedPrompt(title: "A", body: "B {{c}}", trigger: "a"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        library.write(to: url)
        XCTAssertEqual(PromptLibrary.load(url).prompts.first?.body, "B {{c}}")
        XCTAssertTrue(PromptLibrary.load(url.appendingPathExtension("missing")).prompts.isEmpty)
    }

    // MARK: Spaces

    func testSpaceMembershipAndInstructions() {
        var book = NookSpaceBook()
        var space = NookSpace(name: "  Taxes  ", instructions: "Answer in Dutch.")
        book.save(space)
        space = book.spaces[0]
        XCTAssertEqual(space.name, "Taxes")
        XCTAssertTrue(space.contextText.contains("Answer in Dutch."))
        XCTAssertEqual(NookSpace(name: "Empty").contextText, "")
        let chat = UUID()
        book.assign(conversation: chat, to: space.id)
        XCTAssertEqual(book.space(of: chat)?.id, space.id)
        XCTAssertEqual(book.conversations(in: space.id), [chat])
        book.assign(conversation: chat, to: UUID())
        XCTAssertNil(book.space(of: chat), "an unknown space takes the conversation out")
        book.assign(conversation: chat, to: space.id)
        book.remove(space.id)
        XCTAssertNil(book.space(of: chat))
        book.save(NookSpace(name: " "))
        XCTAssertTrue(book.spaces.isEmpty)
    }

    // MARK: Context breakdown

    func testBreakdownSkipsEmptyPartsAndSumsTokens() {
        let breakdown = ContextBreakdown(parts: [
            .init(kind: .style, text: ""),
            .init(kind: .memory, text: String(repeating: "a", count: 40)),
            .init(kind: .overview, text: String(repeating: "b", count: 120)),
        ], budget: 400)
        XCTAssertEqual(breakdown.parts.map(\.kind), [.memory, .overview])
        XCTAssertEqual(breakdown.totalTokens, 40)
        XCTAssertEqual(breakdown.fill ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(breakdown.share(of: breakdown.parts[0]), 0.25, accuracy: 0.001)
        XCTAssertNil(ContextBreakdown(parts: []).fill)
    }

    // MARK: Deep links

    func testDeepLinksRoundTrip() {
        let id = UUID()
        for link in [NookDeepLink.conversation(id), .settings("memory"), .settings(""), .memory, .shortcuts] {
            XCTAssertEqual(link.url.flatMap(NookDeepLink.parse), link)
        }
    }

    func testDeepLinksNeverCarryAnythingElse() {
        XCTAssertNil(NookDeepLink.parse(URL(string: "nook://conversation/not-a-uuid")!))
        XCTAssertNil(NookDeepLink.parse(URL(string: "nook://settings/../etc")!))
        XCTAssertNil(NookDeepLink.parse(URL(string: "nook://run/rm")!))
        XCTAssertNil(NookDeepLink.parse(URL(string: "https://conversation/\(UUID().uuidString)")!))
        XCTAssertEqual(NookDeepLink.parse(URL(string: "nook://settings/Memory")!), .settings("memory"))
    }

    // MARK: Cheat sheet

    func testCheatSheetShowsRemappedKeysAndFoldsNumberedJumps() {
        let user = [KeybindingRule(key: "mod+shift+o", command: "commandPalette.toggle")]
        let sheet = ShortcutCheatSheet(effective: Keybindings.effective(user: user))
        let palette = sheet.entries.first { $0.command == "commandPalette.toggle" }
        XCTAssertEqual(palette?.keys, ["⇧⌘K", "⇧⌘O"])
        XCTAssertFalse(sheet.entries.contains { $0.command == "session.jump1" })
        XCTAssertFalse(sheet.entries.contains { $0.command == "session.interrupt" }, "unbound commands are not listed")
        XCTAssertEqual(sheet.entries.first { $0.command == "shortcuts.cheatSheet" }?.group, .navigation)
    }

    func testCheatSheetOpensWithCommandSlashAndLeavesQuestionMarkForTyping() {
        let rules = Keybindings.effective(user: [])
        XCTAssertEqual(Keybindings.match(KeyChord.parse("mod+/")!, context: [:], rules: rules), "shortcuts.cheatSheet")
        XCTAssertNil(Keybindings.match(KeyChord.parse("shift+/")!, context: [:], rules: rules), "? must stay typeable")
        XCTAssertTrue(Keybindings.commandIDs.contains("shortcuts.cheatSheet"))
    }

    func testCheatSheetFilter() {
        let sheet = ShortcutCheatSheet(effective: Keybindings.defaults)
        let found = sheet.filtered("palette") { $0 }
        XCTAssertEqual(found.map(\.command), ["commandPalette.toggle"])
        XCTAssertEqual(sheet.filtered("  ") { $0 }, sheet.entries)
    }
}
