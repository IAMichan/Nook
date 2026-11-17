import XCTest

/// The phone's Foundation-only logic (`apps/ios/Core`): dictation languages and text, diagrams and math in messages, and
/// where a comment on a line of a pull request's diff lands, and the iPad layout's session stepping and dropped text.
final class PhoneCoreTests: XCTestCase {
    // MARK: Dictation

    func testOfferedLanguagesFollowYourOrderAndMatchTheRecognizer() {
        let offered = DictationLanguages.offered(preferred: ["nl_NL", "en-GB", "nl"], supported: ["en-US", "nl-NL", "de-DE"])
        XCTAssertEqual(offered, ["nl-NL", "en-US"])
    }

    func testPickKeepsTheSavedLanguageOnlyWhileOffered() {
        XCTAssertEqual(DictationLanguages.pick(saved: "en_us", offered: ["nl-NL", "en-US"]), "en-US")
        XCTAssertEqual(DictationLanguages.pick(saved: "fr-FR", offered: ["nl-NL", "en-US"]), "nl-NL")
        XCTAssertNil(DictationLanguages.pick(saved: nil, offered: []))
    }

    func testMergeJoinsWhatWasHeardToWhatWasTyped() {
        XCTAssertEqual(DictationText.merge(base: "", heard: " hello "), "hello")
        XCTAssertEqual(DictationText.merge(base: "Fix", heard: "the bug"), "Fix the bug")
        XCTAssertEqual(DictationText.merge(base: "Fix\n", heard: "the bug"), "Fix\nthe bug")
        XCTAssertEqual(DictationText.merge(base: "Fix", heard: ", then ship"), "Fix, then ship")
        XCTAssertEqual(DictationText.merge(base: "Fix", heard: "  "), "Fix")
    }

    // MARK: Diagrams and math

    func testPlainMessagesAreNotParsed() {
        XCTAssertFalse(MessageSegments.mayBeRich("Just words."))
        XCTAssertEqual(MessageSegments.split("Just words."), [.text("Just words.")])
    }

    func testMermaidAndMathFencesBecomeSegments() {
        let text = "Before\n```mermaid\ngraph TD\nA-->B\n```\nAfter\n$$\nx^2\n$$\n"
        let segments = MessageSegments.split(text)
        XCTAssertTrue(segments.contains(.mermaid("graph TD\nA-->B")))
        XCTAssertTrue(segments.contains(.math("x^2")))
        XCTAssertTrue(segments.contains(.text("Before")))
    }

    func testMoneyIsNotMath() {
        let pieces = MessageSegments.inlinePieces("It costs $5 and $10 today")
        XCTAssertFalse(pieces.contains { $0.math })
        let math = MessageSegments.inlinePieces("Energy is $E=mc^2$ here")
        XCTAssertEqual(math.filter(\.math).map(\.text), ["E=mc^2"])
    }

    func testRichPageEscapesAndStaysOffline() throws {
        let html = try XCTUnwrap(RichPage.html(.mermaid("A<b>\"")))
        XCTAssertTrue(html.contains("A&lt;b&gt;&quot;"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("http://") || html.contains("https://"))
        XCTAssertNil(RichPage.html(.text("plain")))
    }

    // MARK: Comment positions in a diff

    func testPositionsFollowTheHunkNumbers() {
        let lines = ["@@ -10,3 +20,3 @@ func", " keep", "-old", "+new", " tail", "\\ No newline at end of file"]
        let positions = PatchPositions.positions(lines)
        XCTAssertNil(positions[0])
        XCTAssertEqual(positions[1]?.line, 20)
        XCTAssertEqual(positions[2], .init(line: 11, side: "LEFT"))
        XCTAssertEqual(positions[3], .init(line: 21, side: "RIGHT"))
        XCTAssertEqual(positions[4], .init(line: 22, side: "RIGHT"))
        XCTAssertNil(positions[5])
    }

    func testCommentOnARangeStartsOnTheSameSide() throws {
        let lines = ["@@ -1,2 +1,3 @@", " a", "+b", "+c"]
        let positions = PatchPositions.positions(lines)
        let comment = try XCTUnwrap(PatchPositions.comment(path: "f.swift", picked: 2...3, positions: positions, body: "why"))
        XCTAssertEqual(comment.line, 3)
        XCTAssertEqual(comment.startLine, 2)
        XCTAssertEqual(comment.side, "RIGHT")
        XCTAssertNil(PatchPositions.comment(path: "f", picked: 0...0, positions: positions, body: "x"))
    }

    // MARK: iPad layout

    func testSessionSteppingMovesThroughTheListAndHoldsAtTheEnds() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(SessionStepping.target(order: order, current: "b", step: 1), "c")
        XCTAssertEqual(SessionStepping.target(order: order, current: "b", step: -1), "a")
        XCTAssertEqual(SessionStepping.target(order: order, current: "c", step: 1), "c")
        XCTAssertEqual(SessionStepping.target(order: order, current: "a", step: -1), "a")
    }

    func testSessionSteppingWithNothingOpenStartsAtAnEnd() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(SessionStepping.target(order: order, current: nil, step: 1), "a")
        XCTAssertEqual(SessionStepping.target(order: order, current: nil, step: -1), "c")
        XCTAssertEqual(SessionStepping.target(order: order, current: "gone", step: 1), "a")
        XCTAssertNil(SessionStepping.target(order: [], current: nil, step: 1))
    }

    func testDroppedTextJoinsWhatWasTyped() {
        XCTAssertEqual(DroppedText.merge(current: "", dropped: "https://example.com"), "https://example.com")
        XCTAssertEqual(DroppedText.merge(current: "Look at this ", dropped: " https://example.com\n"),
                       "Look at this\n\nhttps://example.com")
        XCTAssertEqual(DroppedText.merge(current: "Typed", dropped: "  "), "Typed")
        XCTAssertEqual(DroppedText.clip(String(repeating: "x", count: DroppedText.maxLength + 10)).count, DroppedText.maxLength)
    }

    // MARK: Agents by project

    func testProjectGroupsKeepTheNewestProjectFirstAndEachSessionsOrder() {
        let sessions = [("a", "nook"), ("b", "site"), ("c", "nook"), ("d", ""), ("e", " site ")]
        let groups = ProjectGroups.group(sessions) { $0.1 }
        XCTAssertEqual(groups.map(\.folder), ["nook", "site", ""])
        XCTAssertEqual(groups.map { $0.items.map { $0.0 } }, [["a", "c"], ["b", "e"], ["d"]])
        XCTAssertTrue(ProjectGroups.group([(String, String)]()) { $0.1 }.isEmpty)
    }

    func testProjectPathPrefersTheNameTheMacOffersThenTheFolderName() {
        let projects: [(name: String, path: String)] = [(name: "Nook", path: "/Users/me/code/nook"),
                                                        (name: "site", path: "/Users/me/code/website"),
                                                        (name: "Other", path: "/Users/me/code/site")]
        XCTAssertEqual(ProjectGroups.path(forFolder: "site", in: projects), "/Users/me/code/website")
        XCTAssertEqual(ProjectGroups.path(forFolder: "nook", in: projects), "/Users/me/code/nook")
        XCTAssertNil(ProjectGroups.path(forFolder: "elsewhere", in: projects))
        XCTAssertNil(ProjectGroups.path(forFolder: " ", in: projects))
    }

    func testFoldedProjectsSurviveBeingStored() {
        let folded: Set<String> = ["nook", "site", ""]
        XCTAssertEqual(ProjectGroups.decode(ProjectGroups.encode(folded)), ["nook", "site"])
        XCTAssertEqual(ProjectGroups.decode(""), [])
    }

    // MARK: Drafts

    private func drafts() -> PhoneDrafts {
        let suite = "PhoneDraftsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PhoneDrafts(defaults: defaults)
    }

    func testDraftsAreKeptPerPlace() {
        let store = drafts()
        store.set("Fix the relay", for: .session("s1"))
        store.set("Hi Anna", for: .chat("w1"))
        XCTAssertEqual(store.text(.session("s1")), "Fix the relay")
        XCTAssertEqual(store.text(.chat("w1")), "Hi Anna")
        XCTAssertEqual(store.text(.session("s2")), "")
        XCTAssertEqual(store.text(.nookChat("s1")), "", "a session and a Nook chat with the same id keep their own drafts")
    }

    func testSendingOrClearingForgetsTheDraft() {
        let store = drafts()
        store.set("Ship it", for: .newSession)
        store.set("  \n", for: .newSession)
        XCTAssertEqual(store.text(.newSession), "")
    }

    func testTheOldestDraftsGoFirst() {
        var store = drafts()
        var clock = 0.0
        store.now = { clock += 1; return Date(timeIntervalSince1970: clock) }
        for index in 0...PhoneDrafts.limit { store.set("draft \(index)", for: .session("s\(index)")) }
        XCTAssertEqual(store.text(.session("s0")), "", "past the limit the oldest draft goes")
        XCTAssertEqual(store.text(.session("s1")), "draft 1")
        XCTAssertEqual(store.text(.session("s\(PhoneDrafts.limit)")), "draft \(PhoneDrafts.limit)")
    }

    func testClearForgetsEveryDraft() {
        let store = drafts()
        store.set("a", for: .newNookChat)
        store.clear()
        XCTAssertEqual(store.text(.newNookChat), "")
    }

    // MARK: A session as Markdown

    func testSessionMarkdownReadsAsTheMacsExport() {
        let entries = [
            TimelineEntry(id: "1", kind: .user, text: "Fix the relay", detail: nil, date: 0, failed: false),
            TimelineEntry(id: "2", kind: .tool, text: "swift test\n--filter Relay", detail: "Bash", date: 1, failed: false),
            TimelineEntry(id: "3", kind: .change, text: "", detail: "Sources/Relay.swift", date: 2, failed: false),
            TimelineEntry(id: "4", kind: .notice, text: "Context compacted", detail: "compacted", date: 3, failed: false),
            TimelineEntry(id: "5", kind: .assistant, text: "Done.", detail: nil, date: 4, failed: false),
        ]
        let markdown = SessionMarkdown.markdown(title: "Relay", agent: "Codex", folder: "nook", branch: "fix/relay", entries: entries)
        XCTAssertEqual(markdown, """
        # Relay

        _Codex · nook · fix/relay_

        ## You

        Fix the relay

        <details><summary>2 steps</summary>

        - `swift test --filter Relay`
        - `Sources/Relay.swift`

        </details>

        ## Codex

        Done.

        """)
    }

    // MARK: What a turn changed

    func testTurnChangesGoUnderEachTurnsLastAnswer() {
        func entry(_ id: String, _ kind: TimelineEntry.Kind, file: String? = nil, patch: String? = nil) -> TimelineEntry {
            var entry = TimelineEntry(id: id, kind: kind, text: "", detail: file, date: 0, failed: false)
            entry.output = patch
            return entry
        }
        let entries = [
            entry("u1", .user),
            entry("c1", .change, file: "Sources/A.swift", patch: "--- a\n+++ b\n@@\n+one\n+two\n-old"),
            entry("a1", .assistant),
            entry("c2", .change, file: "Sources/A.swift", patch: "+three"),
            entry("c3", .change, file: "README.md", patch: "-gone"),
            entry("a2", .assistant),
            entry("u2", .user),
            entry("a3", .assistant),
            entry("u3", .user),
            entry("c4", .change, file: "B.swift", patch: "+x"),
        ]
        let turns = PhoneTurnChanges.byFinalAnswer(entries)
        XCTAssertEqual(Set(turns.keys), ["a2"], "only a turn with an answer and changes gets a card, under its last answer")
        let files = turns["a2"] ?? []
        XCTAssertEqual(files.map(\.path), ["Sources/A.swift", "README.md"])
        XCTAssertEqual(files.first?.added, 3)
        XCTAssertEqual(files.first?.removed, 1)
        XCTAssertEqual(files.first?.patches.count, 2)
        XCTAssertEqual(files.last?.name, "README.md")
    }
}
