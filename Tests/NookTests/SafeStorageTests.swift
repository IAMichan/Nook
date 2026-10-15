import XCTest

/// User data is never lost because it could not be read: bad entries are skipped and the original is kept aside.
final class SafeStorageTests: XCTestCase {
    private struct Item: Codable, Equatable {
        enum Kind: String, Codable { case a, b }
        var name: String
        var kind: Kind
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("safestorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMissingFileIsAFreshStart() {
        let outcome = SafeStorage.load(LossyArray<Item>.self, from: folder.appendingPathComponent("none.json"))
        guard case .missing = outcome else { return XCTFail("expected missing") }
    }

    func testOneBadEntryDoesNotLoseTheOthersAndOriginalIsKept() throws {
        let url = folder.appendingPathComponent("items.json")
        let raw = #"[{"name":"one","kind":"a"},{"name":"two","kind":"future-kind"},{"kind":"b"},{"name":"four","kind":"b"}]"#
        try Data(raw.utf8).write(to: url)

        let outcome = SafeStorage.load(LossyArray<Item>.self, from: url, skipped: { $0.skipped })
        guard case .partial(let list, let skipped, let backup) = outcome else { return XCTFail("expected partial, got \(outcome)") }
        XCTAssertEqual(list.elements.map(\.name), ["one", "four"])
        XCTAssertEqual(skipped, 2)
        let kept = try XCTUnwrap(backup)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), raw, "the original is kept byte for byte")
    }

    func testUnreadableFileIsKeptAside() throws {
        let url = folder.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: url)
        let outcome = SafeStorage.load(LossyArray<Item>.self, from: url)
        guard case .unreadable(let backup, _) = outcome else { return XCTFail("expected unreadable") }
        XCTAssertNotNil(backup)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), Data("{ not json".utf8))
    }

    func testSameContentIsPreservedOnlyOnce() throws {
        let url = folder.appendingPathComponent("x.json")
        let data = Data("broken".utf8)
        let first = SafeStorage.preserve(data, for: url, now: Date(timeIntervalSince1970: 0))
        let second = SafeStorage.preserve(data, for: url, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(first, second)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(copies.count, 1)
    }

    func testLossyArrayRoundTrips() throws {
        let list = LossyArray([Item(name: "x", kind: .a)])
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode([Item].self, from: data), [Item(name: "x", kind: .a)], "encodes as a plain list")
    }
}
