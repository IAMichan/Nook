import XCTest

final class EmojiUsageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "EmojiUsageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ count: Double) -> Date { start.addingTimeInterval(count * 24 * 3600) }

    func testEmptyUntilSomethingIsChosen() {
        let usage = EmojiUsage(defaults: defaults)
        XCTAssertEqual(usage.ranked(at: start), [])
        let list = ["😀", "😂"]
        XCTAssertEqual(usage.usedFirst(list, character: { $0 }, at: start), list)
    }

    func testMostUsedComesFirstAndTiesGoToTheLastUsed() {
        let usage = EmojiUsage(defaults: defaults)
        usage.record("😂", at: start)
        usage.record("😂", at: start)
        usage.record("👍", at: start)
        usage.record("🔥", at: start.addingTimeInterval(60))
        XCTAssertEqual(usage.ranked(at: days(0.1)), ["😂", "🔥", "👍"])
    }

    func testOldUseFadesSoRecentUseRises() {
        let usage = EmojiUsage(defaults: defaults)
        for _ in 0..<4 { usage.record("😂", at: start) }
        // Two months on, four old choices weigh less than two today.
        usage.record("🎉", at: days(60))
        usage.record("🎉", at: days(60))
        XCTAssertEqual(usage.ranked(at: days(60)), ["🎉", "😂"])
        XCTAssertEqual(EmojiUsage.score(EmojiUsage.Entry(score: 2, last: start), at: days(14)), 1, accuracy: 0.0001)
    }

    func testKeepsAFewAndSurvivesARestart() {
        let usage = EmojiUsage(defaults: defaults)
        for (index, emoji) in EmojiCatalog.all.prefix(EmojiUsage.keptCount + 10).enumerated() {
            usage.record(emoji.character, at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(usage.entries.count, EmojiUsage.keptCount)
        XCTAssertEqual(usage.ranked(at: days(1)).count, EmojiUsage.shownCount)
        XCTAssertEqual(EmojiUsage(defaults: defaults).ranked(limit: 1, at: days(1)),
                       [EmojiCatalog.all[EmojiUsage.keptCount + 9].character])
    }

    func testSearchResultsYouUseComeFirst() {
        let usage = EmojiUsage(defaults: defaults)
        usage.record("❤️", at: start)
        let found = usage.usedFirst(EmojiCatalog.search("heart"), character: \.character, at: start)
        XCTAssertEqual(found.first?.character, "❤️")
        XCTAssertGreaterThan(found.count, 1)
    }

    func testCatalogLooksUpEmojiByCharacter() {
        XCTAssertEqual(EmojiCatalog.emoji(for: "😂").name, "face with tears of joy")
        XCTAssertEqual(EmojiCatalog.emoji(for: "❤").character, "❤️", "the text-style heart finds the emoji one")
        XCTAssertEqual(EmojiCatalog.emoji(for: "👍🏽").name, "👍🏽", "a skin tone the catalog lacks keeps its character")
    }
}
