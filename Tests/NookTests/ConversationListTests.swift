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
}
