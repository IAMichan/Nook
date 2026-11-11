import XCTest

/// The stores of the user's own data read entry by entry: one bad entry keeps the others, older files without newer fields
/// still load, the original is kept aside before anything is written over it, and an encode failure never deletes a key.
final class StoredDataTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var support: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("stored-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "nook.tests.stored-data.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        // Backups of UserDefaults values go to Nook's folder: this test's own, never the user's.
        support = NookPaths.supportDirectory
        NookPaths.supportDirectory = folder
    }

    override func tearDownWithError() throws {
        NookPaths.supportDirectory = support
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func backups(_ name: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(name + ".unreadable-") }
    }

    // MARK: Files

    func testPromptLibraryKeepsTheGoodPromptsAndTheOriginal() throws {
        let url = folder.appendingPathComponent("prompts.json")
        // One prompt from an older version (no id, trigger or date), one broken (no body), one complete.
        let raw = #"""
        {"prompts":[{"title":"Old","body":"From before"},{"title":"Broken"},
        {"id":"8D7F3C1E-0000-4000-8000-000000000001","title":"New","body":"Hi","trigger":"hi","updatedAt":0}]}
        """#
        try Data(raw.utf8).write(to: url)

        let library = PromptLibrary.load(url)
        XCTAssertEqual(library.prompts.map(\.title), ["Old", "New"])
        XCTAssertEqual(library.prompts.first?.trigger, "")
        XCTAssertEqual(library.prompts.last?.trigger, "hi")
        let kept = try XCTUnwrap(backups("prompts").first, "the original is kept before the next save")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), raw)

        // Saving writes the readable prompts; the backup still holds the broken one.
        library.write(to: url)
        XCTAssertEqual(PromptLibrary.load(url).prompts.map(\.title), ["Old", "New"])
        XCTAssertEqual(try backups("prompts").count, 1)
    }

    func testUnreadablePromptFileIsKeptAside() throws {
        let url = folder.appendingPathComponent("prompts.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertTrue(PromptLibrary.load(url).prompts.isEmpty)
        XCTAssertEqual(try backups("prompts").count, 1)
    }

    func testSpacesFromAnOlderVersionLoadAndABadSpaceIsSkipped() throws {
        let url = folder.appendingPathComponent("spaces.json")
        let space = "8D7F3C1E-0000-4000-8000-000000000002"
        let raw = #"""
        {"spaces":[{"id":"\#(space)","name":"Taxes"},{"id":"not-a-uuid","name":3}],
        "membership":{"A1":"\#(space)","A2":"broken"}}
        """#
        try Data(raw.utf8).write(to: url)

        let book = NookSpaceBook.load(url)
        XCTAssertEqual(book.spaces.map(\.name), ["Taxes"])
        XCTAssertEqual(book.spaces.first?.instructions, "")
        XCTAssertEqual(book.spaces.first?.attachments, [])
        XCTAssertEqual(book.membership, ["A1": UUID(uuidString: space)!])
        XCTAssertEqual(try backups("spaces").count, 1)
    }

    func testIntactFilesLeaveNoBackup() throws {
        let url = folder.appendingPathComponent("prompts.json")
        var library = PromptLibrary()
        library.save(SavedPrompt(title: "A", body: "B"))
        library.write(to: url)
        XCTAssertEqual(PromptLibrary.load(url), library)
        XCTAssertTrue(try backups("prompts").isEmpty)
    }

    // MARK: UserDefaults

    func testCustomAgentsKeepTheReadableOnesAndOlderOnesLoad() throws {
        let raw = #"[{"profileID":"acp-a","name":"A","command":"npx"},{"profileID":"acp-b"},{"profileID":"acp-c","name":"C","command":"uvx","arguments":["x"]}]"#
        defaults.set(Data(raw.utf8), forKey: CustomAgents.defaultsKey)

        let agents = CustomAgents.load(defaults: defaults)
        XCTAssertEqual(agents.map(\.profileID), ["acp-a", "acp-c"])
        XCTAssertEqual(agents.first?.arguments, [], "a field an older version did not write gets its default")
        let kept = try XCTUnwrap(backups(CustomAgents.defaultsKey).first)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), raw)
    }

    func testRemoteMachinesKeepTheReadableOnes() throws {
        let raw = #"[{"name":"Box","host":"box.local"},{"id":"x","name":"Bad","host":7},{"id":"y","name":"Pi","host":"pi","port":2222}]"#
        defaults.set(Data(raw.utf8), forKey: RemoteMachines.defaultsKey)

        let machines = RemoteMachines.load(defaults: defaults)
        XCTAssertEqual(machines.map(\.name), ["Box", "Pi"])
        XCTAssertFalse(machines[0].id.isEmpty, "a machine without an id gets one")
        XCTAssertEqual(machines[1].port, 2222)
        XCTAssertEqual(try backups(RemoteMachines.defaultsKey).count, 1)
    }

    func testProjectOverridesLoseOnlyTheBadValue() throws {
        let raw = #"{"byProject":{"/a":{"one":true,"two":{"nested":1}},"/b":{"three":"x"}}}"#
        let lossy = try JSONDecoder().decode(ProjectOverrides.Lossy.self, from: Data(raw.utf8))
        XCTAssertEqual(lossy.skipped, 1)
        XCTAssertEqual(lossy.overrides.byProject["/a"], ["one": .bool(true)])
        XCTAssertEqual(lossy.overrides.byProject["/b"], ["three": .string("x")])
        // The plain decoder is just as forgiving.
        XCTAssertEqual(try JSONDecoder().decode(ProjectOverrides.self, from: Data(raw.utf8)), lossy.overrides)
    }

    func testShortcutsKeepTheReadableOnes() throws {
        let raw = #"{"talk":{"keyCode":1,"modifiers":256},"ask":{"keyCode":"x"},"futureAction":{"keyCode":2,"modifiers":0}}"#
        defaults.set(Data(raw.utf8), forKey: ShortcutSet.defaultsKey)
        let set = ShortcutSet.load(from: defaults)
        XCTAssertEqual(set.custom[.talk] ?? nil, Shortcut(keyCode: 1, modifiers: 256))
        XCTAssertNil(set.custom[.ask])
        XCTAssertEqual(try backups(ShortcutSet.defaultsKey).count, 1)
    }

    func testSetEncodedKeepsTheStoredValueWhenEncodingFails() {
        defaults.set(Data("kept".utf8), forKey: "value")
        XCTAssertFalse(defaults.setEncoded(Unencodable(), forKey: "value"))
        XCTAssertEqual(defaults.data(forKey: "value"), Data("kept".utf8))

        XCTAssertTrue(defaults.setEncoded(["a"], forKey: "value"))
        XCTAssertEqual(defaults.data(forKey: "value"), try JSONEncoder().encode(["a"]))
    }

    private struct Unencodable: Encodable {
        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "never"))
        }
    }
}
