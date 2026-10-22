import XCTest

/// Every emoji for the reaction picker's "+": the groups, and a search by English and by Nook's own names.
final class EmojiCatalogTests: XCTestCase {
    func testEveryGroupHoldsItsEmojiOnce() {
        XCTAssertEqual(EmojiCatalog.groups.map(\.id), ["emoji.group.smileys", "emoji.group.people", "emoji.group.animals",
                                                       "emoji.group.food", "emoji.group.travel", "emoji.group.activities",
                                                       "emoji.group.objects", "emoji.group.symbols", "emoji.group.flags"])
        XCTAssertGreaterThan(EmojiCatalog.all.count, 1_800)
        XCTAssertEqual(Set(EmojiCatalog.all.map(\.character)).count, EmojiCatalog.all.count)
        XCTAssertEqual(EmojiCatalog.groups.first?.emoji.first, EmojiCatalog.Emoji(character: "😀", name: "grinning face"))
        XCTAssertTrue(EmojiCatalog.all.allSatisfy { !$0.character.isEmpty && !$0.name.isEmpty })
        // No skin-tone variants: the picker shows each emoji once.
        XCTAssertFalse(EmojiCatalog.all.contains { $0.character.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } })
    }

    func testSearchFindsByEveryWordAndByNooksOwnNames() {
        XCTAssertEqual(EmojiCatalog.search("tears joy").first?.character, "😂")
        XCTAssertTrue(EmojiCatalog.search("pizza").contains { $0.character == "🍕" })
        // Nook's own (Dutch) names for an emoji find it too.
        XCTAssertTrue(EmojiCatalog.search("lachen").contains { $0.character == "😂" })
        XCTAssertTrue(EmojiCatalog.search("netherlands").contains { $0.character == "🇳🇱" })
        XCTAssertTrue(EmojiCatalog.search("").isEmpty)
        XCTAssertTrue(EmojiCatalog.search("qqqzzz").isEmpty)
    }
}
