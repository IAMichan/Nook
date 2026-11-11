import XCTest

/// Settings › Archive: which archived items a search shows, and which of them "Delete all archived…" removes.
final class ArchivePurgeTests: XCTestCase {
    private struct Item: Equatable {
        let name: String
        var archived = true
        var busy = false
        var project = ""
        var updated = Date(timeIntervalSince1970: 0)
    }

    private func shown(_ items: [Item], query: String = "") -> [Item] {
        ArchivePurge.shown(items, query: query, archived: \.archived, fields: { [$0.name, $0.project] }, updated: \.updated)
    }

    func testEmptySearchMatchesEverything() {
        XCTAssertTrue(ArchivePurge.matches("", ["anything"]))
        XCTAssertTrue(ArchivePurge.matches("   ", []))
    }

    func testSearchIsCaseInsensitiveAndLooksAtEveryField() {
        XCTAssertTrue(ArchivePurge.matches("FIX", ["Fix the login"]))
        XCTAssertTrue(ArchivePurge.matches("nook", ["Refactor", "/Users/me/Nook"]))
        XCTAssertFalse(ArchivePurge.matches("billing", ["Refactor", "/Users/me/Nook"]))
    }

    func testShowsOnlyArchivedItemsNewestFirst() {
        let items = [
            Item(name: "old", updated: Date(timeIntervalSince1970: 10)),
            Item(name: "live", archived: false, updated: Date(timeIntervalSince1970: 30)),
            Item(name: "new", updated: Date(timeIntervalSince1970: 20)),
        ]
        XCTAssertEqual(shown(items).map(\.name), ["new", "old"])
    }

    func testSearchNarrowsTheShownItems() {
        let items = [Item(name: "Fix login", project: "web"), Item(name: "Docs", project: "nook"), Item(name: "Ship")]
        XCTAssertEqual(shown(items, query: "nook").map(\.name), ["Docs"])
        XCTAssertEqual(shown(items, query: "login").map(\.name), ["Fix login"])
    }

    func testDeleteAllLeavesWorkingItemsAlone() {
        let items = [Item(name: "a"), Item(name: "working", busy: true), Item(name: "b")]
        let deletable = ArchivePurge.deletable(shown(items), busy: \.busy)
        XCTAssertEqual(deletable.map(\.name).sorted(), ["a", "b"])
    }

    func testDeleteAllTakesOnlyWhatTheSearchShows() {
        let items = [Item(name: "Fix login"), Item(name: "Docs"), Item(name: "Fix crash", archived: false)]
        let deletable = ArchivePurge.deletable(shown(items, query: "fix"), busy: \.busy)
        XCTAssertEqual(deletable.map(\.name), ["Fix login"])
    }

    func testNothingToDeleteWhenEverythingWorks() {
        let items = [Item(name: "a", busy: true)]
        XCTAssertTrue(ArchivePurge.deletable(shown(items), busy: \.busy).isEmpty)
    }
}
