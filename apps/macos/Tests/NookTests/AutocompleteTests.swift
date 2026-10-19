import XCTest

final class AutocompleteTests: XCTestCase {
    // MARK: GGUF

    private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func string(_ text: String) -> [UInt8] { le(UInt64(text.utf8.count)) + Array(text.utf8) }

    /// A minimal GGUF header: name and architecture as strings, a context length, and a string array in between that must be skipped.
    private func sampleGGUF(version: UInt32 = 3) -> Data {
        var bytes = Array("GGUF".utf8) + le(version) + le(UInt64(0)) + le(UInt64(4))
        bytes += string("general.architecture") + le(UInt32(8)) + string("qwen3")
        bytes += string("general.name") + le(UInt32(8)) + string("Qwen3 0.6B")
        bytes += string("general.tags") + le(UInt32(9)) + le(UInt32(8)) + le(UInt64(2)) + string("a") + string("bb")
        bytes += string("qwen3.context_length") + le(UInt32(4)) + le(UInt32(32_768))
        return Data(bytes)
    }

    func testReadsNameArchitectureAndContext() {
        let info = GGUFReader.parse(sampleGGUF())
        XCTAssertEqual(info, GGUFInfo(version: 3, architecture: "qwen3", name: "Qwen3 0.6B", contextLength: 32_768))
    }

    func testRejectsOtherFilesAndTruncation() {
        XCTAssertNil(GGUFReader.parse(Data("not a model at all".utf8)))
        XCTAssertNil(GGUFReader.parse(Data()))
        XCTAssertNil(GGUFReader.parse(sampleGGUF(version: 99)))
        // Cut in the middle of an entry: what was read stays, nothing crashes.
        let cut = sampleGGUF().prefix(70)
        _ = GGUFReader.parse(Data(cut))
    }

    func testHugeArrayCountDoesNotCrash() {
        var bytes = Array("GGUF".utf8) + le(UInt32(3)) + le(UInt64(0)) + le(UInt64(1))
        bytes += string("tokenizer.tokens") + le(UInt32(9)) + le(UInt32(8)) + le(UInt64.max)
        XCTAssertNotNil(GGUFReader.parse(Data(bytes)))
    }

    // MARK: Finding Cotypist's model

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-ac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testFindsGGUFInCotypistFolderOnly() throws {
        let home = try makeHome()
        let models = home.appendingPathComponent("Library/Application Support/Cotypist/Models", isDirectory: true)
        let other = home.appendingPathComponent("Library/Application Support/SomethingElse", isDirectory: true)
        for folder in [models, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try sampleGGUF().write(to: models.appendingPathComponent("qwen.gguf"))
        try sampleGGUF().write(to: models.appendingPathComponent("vision-mmproj.gguf"))
        try Data("junk".utf8).write(to: models.appendingPathComponent("broken.gguf"))
        try sampleGGUF().write(to: other.appendingPathComponent("elsewhere.gguf"))

        let found = CompletionModelLocator.cotypistModels(home: home, applications: [])
        XCTAssertEqual(found.map { $0.url.lastPathComponent }, ["qwen.gguf"])
        XCTAssertEqual(found.first?.title, "Qwen3 0.6B")
        XCTAssertEqual(found.first?.source, .cotypist)
    }

    func testStoredPathWinsOverCotypist() throws {
        let home = try makeHome()
        let own = home.appendingPathComponent("mine.gguf")
        try sampleGGUF().write(to: own)
        let picked = CompletionModelLocator.resolve(storedPath: own.path, candidates: [])
        XCTAssertEqual(picked?.url.lastPathComponent, "mine.gguf")
        XCTAssertEqual(picked?.source, .custom)
        XCTAssertNil(CompletionModelLocator.resolve(storedPath: home.appendingPathComponent("gone.gguf").path, candidates: []))
        XCTAssertNil(CompletionModelLocator.resolve(storedPath: "", candidates: []))
    }

    // MARK: Text

    func testPromptKeepsTheEndAtAWordBoundary() {
        XCTAssertEqual(CompletionText.prompt(before: "Hello wor"), "Hello wor")
        let long = String(repeating: "word ", count: 600) + "end"
        let prompt = CompletionText.prompt(before: long)
        XCTAssertLessThanOrEqual(prompt.count, CompletionText.contextCharacters)
        XCTAssertTrue(prompt.hasPrefix("word"))
        XCTAssertTrue(prompt.hasSuffix("end"))
    }

    func testWhenToSuggest() {
        XCTAssertTrue(CompletionText.shouldSuggest(before: "Dear Anna, thanks for", after: ""))
        XCTAssertTrue(CompletionText.shouldSuggest(before: "Dear Anna, thanks for", after: "  "))
        XCTAssertFalse(CompletionText.shouldSuggest(before: "Hi", after: ""))
        XCTAssertFalse(CompletionText.shouldSuggest(before: "  \n ", after: ""))
        XCTAssertFalse(CompletionText.shouldSuggest(before: "Dear Anna, thanks for", after: " your note"))
    }

    func testCleanMakesOneShortLine() {
        XCTAssertEqual(CompletionText.clean(" your message.\nNext line", before: "Thanks for"), " your message.")
        XCTAssertEqual(CompletionText.clean(" your message", before: "Thanks for "), "your message")
        XCTAssertEqual(CompletionText.clean("\tyour\tmessage  ", before: "Thanks for"), " your message")
        XCTAssertNil(CompletionText.clean("\n\nmore", before: "Thanks for"))
        XCTAssertNil(CompletionText.clean("   ", before: "Thanks for"))
        let long = (1...30).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(CompletionText.clean(long, before: "x")?.split(separator: " ").count, CompletionText.maxWords)
    }

    func testAcceptKeys() {
        XCTAssertTrue(CompletionAcceptKey.tab.matches(keyCode: 48, optionDown: false, othersDown: false))
        XCTAssertFalse(CompletionAcceptKey.tab.matches(keyCode: 48, optionDown: true, othersDown: false))
        XCTAssertFalse(CompletionAcceptKey.tab.matches(keyCode: 48, optionDown: false, othersDown: true))
        XCTAssertFalse(CompletionAcceptKey.tab.matches(keyCode: 36, optionDown: false, othersDown: false))
        XCTAssertTrue(CompletionAcceptKey.optionTab.matches(keyCode: 48, optionDown: true, othersDown: false))
        XCTAssertFalse(CompletionAcceptKey.optionTab.matches(keyCode: 48, optionDown: false, othersDown: false))
    }
}
