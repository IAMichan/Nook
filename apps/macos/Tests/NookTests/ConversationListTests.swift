import XCTest

/// The list of Nooks: search, pinning, and archiving instead of deleting.
final class ConversationListTests: XCTestCase {
    private struct Item: ConversationListItem {
        var id = UUID()
        var title: String
        var preview = ""
        var updated: Date
        var pinned = false
        var archived = false
        var busy = false
        var asksAttention = false
        var isScheduledRun = false
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

    func testNewestFirstAndPinnedOnTop() {
        let a = Item(title: "A", updated: day(1)), b = Item(title: "B", updated: day(3)), c = Item(title: "C", updated: day(2), pinned: true)
        XCTAssertEqual(ConversationList.visible([a, b, c], query: "", showArchived: false).map(\.title), ["C", "B", "A"])
    }

    func testArchivedAreHiddenUntilAsked() {
        let a = Item(title: "A", updated: day(1)), b = Item(title: "B", updated: day(2), archived: true)
        XCTAssertEqual(ConversationList.visible([a, b], query: "", showArchived: false).map(\.title), ["A"])
        XCTAssertEqual(ConversationList.visible([a, b], query: "", showArchived: true).map(\.title), ["B"])
    }

    func testSearchMatchesTitleAndPreviewIgnoringCaseAndAccents() {
        let a = Item(title: "Offerte café", preview: "prijs 400", updated: day(1)), b = Item(title: "Reis", preview: "treinkaartjes", updated: day(2))
        XCTAssertEqual(ConversationList.visible([a, b], query: "CAFE", showArchived: false).map(\.title), ["Offerte café"])
        XCTAssertEqual(ConversationList.visible([a, b], query: "trein", showArchived: false).map(\.title), ["Reis"])
        XCTAssertEqual(ConversationList.visible([a, b], query: "offerte 400", showArchived: false).map(\.title), ["Offerte café"])
        XCTAssertEqual(ConversationList.visible([a, b], query: "nothing", showArchived: false).count, 0)
    }

    func testTheOldestUnpinnedAreArchivedBeyondTheLimit() {
        var items = (1...5).map { Item(title: "\($0)", updated: day($0)) }
        items[0].pinned = true   // the oldest, but pinned
        let ids = ConversationList.toArchive(items, limit: 3)
        XCTAssertEqual(Set(ids), Set([items[1].id, items[2].id]))
    }

    func testBusyConversationsAreNeverArchivedAndNothingHappensUnderTheLimit() {
        var items = (1...3).map { Item(title: "\($0)", updated: day($0)) }
        items[0].busy = true
        XCTAssertEqual(ConversationList.toArchive(items, limit: 3), [])
        XCTAssertEqual(ConversationList.toArchive(items, limit: 2), [items[1].id])
    }

    func testOnlyBeyondTheArchiveLimitIsAnythingDeleted() {
        let items = (1...4).map { Item(title: "\($0)", updated: day($0), archived: true) }
        XCTAssertEqual(ConversationList.toDelete(items, limit: 4), [])
        XCTAssertEqual(ConversationList.toDelete(items, limit: 3), [items[0].id])
    }

    // MARK: The list's parts

    func testWhatAsksForYouGoesOnTopAndTheRestSplitsOnPinned() {
        let new = Item(title: "New", updated: day(1), pinned: true, asksAttention: true)
        let pinned = Item(title: "Pinned", updated: day(2), pinned: true)
        let rest = Item(title: "Rest", updated: day(3))
        let parts = ConversationList.sections([new, pinned, rest], searching: false)
        XCTAssertEqual(parts.attention.map(\.title), ["New"])
        XCTAssertEqual(parts.pinned.map(\.title), ["Pinned"])
        XCTAssertEqual(parts.rest.map(\.title), ["Rest"])
    }

    func testAReadScheduledRunLeavesTheListUntilYouSearch() {
        let read = Item(title: "Morning update", updated: day(3), isScheduledRun: true)
        let unread = Item(title: "Morning update", updated: day(4), asksAttention: true, isScheduledRun: true)
        let kept = Item(title: "Pinned run", updated: day(2), pinned: true, isScheduledRun: true)
        let own = Item(title: "Own", updated: day(1))
        let parts = ConversationList.sections([unread, read, kept, own], searching: false)
        XCTAssertEqual(parts.attention.map(\.id), [unread.id])
        XCTAssertEqual(parts.pinned.map(\.id), [kept.id])
        XCTAssertEqual(parts.rest.map(\.id), [own.id])
        XCTAssertEqual(ConversationList.sections([unread, read, own], searching: true).rest.map(\.id), [read.id, own.id])
    }

    // MARK: Short titles

    func testATitleIsCleanedOfQuotesLabelsAndAFinalPeriod() {
        XCTAssertEqual(ConversationTitle.clean("\"Offerte van Infaris\"."), "Offerte van Infaris")
        XCTAssertEqual(ConversationTitle.clean("Titel: roadmapmail van Laura\nmore text"), "Roadmapmail van Laura")
        XCTAssertEqual(ConversationTitle.clean("\n  **BIT Support e-mailadres**  "), "BIT Support e-mailadres")
        // A colon that is part of the subject stays.
        XCTAssertEqual(ConversationTitle.clean("Training: dinsdag"), "Training: dinsdag")
    }

    func testAnAnswerThatIsNoTitleIsDropped() {
        XCTAssertNil(ConversationTitle.clean(""))
        XCTAssertNil(ConversationTitle.clean("  \n \"\"  "))
        XCTAssertNil(ConversationTitle.clean(String(repeating: "word ", count: 20)))
    }
}
