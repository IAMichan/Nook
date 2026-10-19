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

    func testRecommendedModelIsGemmaForDutch() {
        XCTAssertTrue(CompletionCatalogModel.recommended(memoryGB: 8).name.hasPrefix("Gemma"))
        XCTAssertEqual(CompletionCatalogModel.recommended(memoryGB: 32).name, "Gemma 3 4B")
        XCTAssertTrue(CompletionCatalogModel.catalog.allSatisfy { $0.url.absoluteString.hasPrefix("https://huggingface.co/") && $0.fileName.hasSuffix(".gguf") })
    }

    func testNookModelsAndResolveOrder() throws {
        let home = try makeHome()
        let folder = home.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sampleGGUF().write(to: folder.appendingPathComponent("own.gguf"))
        let own = CompletionModelLocator.nookModels(in: folder)
        XCTAssertEqual(own.map(\.source), [.nook])
        XCTAssertEqual(CompletionModelLocator.resolve(storedPath: "", candidates: own)?.source, .nook)
    }

    // MARK: Suggestions

    func testMakeKeepsOneLineAndDropsDoubledSpace() {
        XCTAssertEqual(CompletionSuggestion.make(raw: " your message.\nNext", before: "Thanks for", maxWords: 8)?.remaining, " your message.")
        XCTAssertEqual(CompletionSuggestion.make(raw: " your message", before: "Thanks for ", maxWords: 8)?.remaining, "your message")
        XCTAssertNil(CompletionSuggestion.make(raw: "\nmore", before: "Thanks for", maxWords: 8))
        XCTAssertNil(CompletionSuggestion.make(raw: "   ", before: "x", maxWords: 8))
        XCTAssertEqual(CompletionSuggestion.make(raw: " a b c d e", before: "x", maxWords: 3)?.remaining, " a b c")
    }

    func testTruncatedDropsTheCutOffWord() {
        XCTAssertEqual(CompletionSuggestion.make(raw: " see you tomor", before: "I'll", maxWords: 8, truncated: true)?.remaining, " see you")
        XCTAssertEqual(CompletionSuggestion.make(raw: " tomor", before: "I'll", maxWords: 8, truncated: true)?.remaining, " tomor")
    }

    func testMidLineStopsWhereTheExistingTextBegins() {
        XCTAssertEqual(CompletionSuggestion.make(raw: " to see you soon", before: "Nice", after: " see you soon", maxWords: 8)?.remaining, " to")
        XCTAssertNil(CompletionSuggestion.make(raw: " soon", before: "See you", after: " soon!", maxWords: 8))
        XCTAssertEqual(CompletionSuggestion.make(raw: " a lot", before: "Thanks", after: "", maxWords: 8)?.remaining, " a lot")
    }

    func testAcceptWordByWordAndTypeThrough() {
        var suggestion = CompletionSuggestion(" see you there, Anna")
        XCTAssertEqual(suggestion.acceptNextChunk(), " see")
        XCTAssertTrue(suggestion.consume(typed: " "))
        XCTAssertFalse(suggestion.consume(typed: "x"))
        XCTAssertEqual(suggestion.acceptNextChunk(), "you")
        XCTAssertEqual(suggestion.nextChunk(.init(trailingSpace: false, attachedPunctuation: false)), " there")
        XCTAssertEqual(suggestion.acceptNextChunk(), " there,")
        XCTAssertEqual(suggestion.acceptAll(), " Anna")
        XCTAssertTrue(suggestion.isEmpty)
    }

    func testTrailingSpaceOption() {
        let suggestion = CompletionSuggestion(" see you")
        XCTAssertEqual(suggestion.nextChunk(.init(trailingSpace: true)), " see ")
    }

    func testPolicy() {
        let policy = CompletionPolicy()
        XCTAssertTrue(policy.shouldComplete(before: "Dear Anna, thanks for", after: "", hasSelection: false))
        XCTAssertTrue(policy.shouldComplete(before: "Dear Anna", after: "  \nnext line", hasSelection: false))
        XCTAssertFalse(policy.shouldComplete(before: "Hi", after: "", hasSelection: false))
        XCTAssertFalse(policy.shouldComplete(before: "Dear Anna", after: " there", hasSelection: false))
        XCTAssertFalse(policy.shouldComplete(before: "Dear Anna", after: "", hasSelection: true))
        XCTAssertTrue(CompletionPolicy(midLine: true).shouldComplete(before: "Dear Anna", after: " there", hasSelection: false))
    }

    func testOptionsFollowEagerness() {
        let careful = CompletionOptions(maxWords: 4, eagerness: 0)
        let eager = CompletionOptions(maxWords: 4, eagerness: 1)
        XCTAssertGreaterThan(careful.minFirstProbability, eager.minFirstProbability)
        XCTAssertEqual(careful.maxTokens, 12)
    }

    // MARK: Prompt

    func testPromptHeaderAndBody() {
        var input = CompletionContext(before: "Hoi Lisa, ik kom ")
        input.instructions = ["Ik schrijf kort.", "", "  "]
        input.facts = ["Lisa is mijn vrouw"]
        input.appName = "Berichten"
        input.windowTitle = "Lisa"
        let prompt = PromptBuilder().build(input)
        XCTAssertTrue(prompt.hasPrefix("About the author:\nIk schrijf kort."))
        XCTAssertTrue(prompt.contains("Facts about the author:\n- Lisa is mijn vrouw"))
        XCTAssertTrue(prompt.contains("The author is now writing in Berichten — Lisa:"))
        XCTAssertTrue(prompt.hasSuffix("Hoi Lisa, ik kom"), "the trailing space is dropped")
        XCTAssertEqual(PromptBuilder().build(CompletionContext(before: "Just text")), "Just text")
    }

    func testWindowMovesInSteps() {
        let builder = PromptBuilder(windowLength: 10, windowStep: 5)
        XCTAssertEqual(builder.window(of: "short"), "short")
        let a = builder.window(of: String(repeating: "a", count: 16))
        let b = builder.window(of: String(repeating: "a", count: 17))
        XCTAssertEqual(a.count, 11)
        XCTAssertEqual(b.count, 12, "same start, so the cache is reused")
    }

    func testJustCompletedWord() {
        XCTAssertEqual(CompletionTextAnalysis.justCompletedWord(in: "ik heb het gedaam ")?.word, "gedaam")
        XCTAssertNil(CompletionTextAnalysis.justCompletedWord(in: "ik ben bij NASA "))
        XCTAssertNil(CompletionTextAnalysis.justCompletedWord(in: "versie v2 "))
        XCTAssertNil(CompletionTextAnalysis.justCompletedWord(in: "nog bezig"))
        XCTAssertTrue(CompletionTextAnalysis.isSingleWord(" mooi "))
        XCTAssertFalse(CompletionTextAnalysis.isSingleWord("twee woorden"))
    }

    // MARK: Emoji

    func testEmojiQueryAndDutchNames() {
        XCTAssertEqual(CompletionEmojiCatalog.query(in: "haha :lachen"), "lachen")
        XCTAssertNil(CompletionEmojiCatalog.query(in: "om 10:30"))
        XCTAssertNil(CompletionEmojiCatalog.query(in: "zie :x"))
        XCTAssertEqual(CompletionEmojiCatalog.search("lachen").first?.character, "😂")
        XCTAssertEqual(CompletionEmojiCatalog.search("duim").first?.character, "👍")
        XCTAssertEqual(CompletionEmojiCatalog.search("joy").first?.character, "😂")
        XCTAssertTrue(CompletionEmojiCatalog.all.count > 250)
    }

    func testSkinTone() {
        let thumbs = CompletionEmojiCatalog.search("thumbsup").first!
        XCTAssertEqual(CompletionEmojiCatalog.render(thumbs, skinTone: 0), "👍")
        XCTAssertEqual(CompletionEmojiCatalog.render(thumbs, skinTone: 3), "👍🏽")
    }

    // MARK: Privacy

    func testSecretsAreTakenOut() {
        let text = "Mijn kaart 4111 1111 1111 1111, IBAN NL91 ABNA 0417 1643 00, BSN 111222333 en wachtwoord: hunter2 sk-proj-abcdefghijklmnopqrstuvwx"
        let clean = CompletionPrivacy.sanitize(text)
        XCTAssertFalse(clean.contains("4111"))
        XCTAssertFalse(clean.contains("ABNA"))
        XCTAssertFalse(clean.contains("111222333"))
        XCTAssertFalse(clean.contains("hunter2"))
        XCTAssertFalse(clean.contains("sk-proj"))
        XCTAssertTrue(clean.hasPrefix("Mijn kaart [redacted]"))
    }

    func testOrdinaryNumbersStay() {
        XCTAssertEqual(CompletionPrivacy.sanitize("Bel 0612345678 om 10:30, kamer 123456789"), "Bel 0612345678 om 10:30, kamer 123456789")
        XCTAssertTrue(CompletionPrivacy.passesElevenTest("111222333"))
        XCTAssertFalse(CompletionPrivacy.passesElevenTest("123456789"))
        XCTAssertTrue(CompletionPrivacy.passesLuhn("4111111111111111"))
    }

    // MARK: Preferences

    func testPreferencesSurviveNewFields() throws {
        var prefs = CompletionPreferences()
        prefs.enabled = true
        prefs.maxWords = 5
        prefs.apps["com.tinyspeck.slackmacgap"] = CompletionAppRule(enabled: .on, instructions: "Kort")
        var object = try JSONSerialization.jsonObject(with: prefs.encoded()) as! [String: Any]
        object.removeValue(forKey: "emoji")
        var apps = object["apps"] as! [String: [String: Any]]
        apps["com.tinyspeck.slackmacgap"]?.removeValue(forKey: "leaveTab")
        object["apps"] = apps
        let decoded = CompletionPreferences.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.maxWords, 5)
        XCTAssertTrue(decoded.emoji)
        XCTAssertEqual(decoded.app("com.tinyspeck.slackmacgap").instructions, "Kort")
        XCTAssertFalse(decoded.app("com.tinyspeck.slackmacgap").leaveTab)
        XCTAssertEqual(CompletionPreferences.decode(Data("nonsense".utf8)), CompletionPreferences())
    }

    func testOffByDefaultInTerminalsAndPerAppRules() {
        var prefs = CompletionPreferences()
        prefs.enabled = true
        XCTAssertTrue(prefs.isEnabled(inApp: "com.apple.mail"))
        XCTAssertFalse(prefs.isEnabled(inApp: "com.apple.Terminal"))
        prefs.apps["com.apple.Terminal"] = CompletionAppRule(enabled: .on)
        XCTAssertTrue(prefs.isEnabled(inApp: "com.apple.Terminal"))
        prefs.enabledByDefault = false
        XCTAssertFalse(prefs.isEnabled(inApp: "com.apple.mail"))
        prefs.sites["example.com"] = CompletionSiteRule(enabled: .off, instructions: "Formeel")
        XCTAssertFalse(prefs.isEnabled(onSite: "example.com"))
        XCTAssertTrue(prefs.isEnabled(onSite: "other.com"))
        XCTAssertEqual(prefs.instructions(app: nil, site: "example.com").last, "Formeel")
    }

    func testShortcuts() {
        XCTAssertTrue(CompletionShortcut.tab.matches(keyCode: 48, modifiers: 0))
        XCTAssertFalse(CompletionShortcut.tab.matches(keyCode: 48, modifiers: CompletionShortcut.shift))
        XCTAssertTrue(CompletionShortcut.shiftTab.matches(keyCode: 48, modifiers: CompletionShortcut.shift))
        XCTAssertFalse(CompletionShortcut.backtick.isTypingKey)
        XCTAssertTrue(CompletionShortcut(keyCode: 0, label: "A").isTypingKey)
        XCTAssertFalse(CompletionShortcut(keyCode: 0, modifiers: CompletionShortcut.command, label: "⌘A").isTypingKey)
    }

    // MARK: Learning and statistics

    func testSamplesGrowInPlaceAndVocabulary() {
        var samples = CompletionSamples()
        let first = "Hoi team, de offerte voor de klant staat klaar in de map"
        samples.add(first, app: "mail")
        samples.add(first + " en de planning ook", app: "mail")
        XCTAssertEqual(samples.count, 1)
        samples.add("kort", app: "mail")
        XCTAssertEqual(samples.count, 1, "too short to keep")
        samples.add("De offerte gaat morgen naar de klant, de planning volgt later", app: "slack")
        XCTAssertEqual(samples.relevant(for: "slack", limit: 1).first?.hasPrefix("De offerte"), true)
        let words = samples.vocabulary()
        XCTAssertEqual(words["offerte"], 1)
        XCTAssertNil(words["de"])
    }

    func testStats() {
        var stats = CompletionStats()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        stats.recordShown(on: day)
        stats.recordShown(on: day)
        stats.recordAccepted(" see you", first: true, on: day)
        stats.recordAccepted(" soon", first: false, on: day)
        XCTAssertEqual(stats.day(day).words, 3)
        XCTAssertEqual(stats.totalAccepted, 1)
        XCTAssertEqual(stats.acceptance, 0.5)
        XCTAssertEqual(stats.recent(3, endingAt: day).count, 3)
    }

    func testSmartQuotes() {
        XCTAssertEqual(CompletionTypography.smartQuotes(" \"top\" en it's", after: "s"), " “top” en it’s")
        XCTAssertEqual(CompletionTypography.smartQuotes("'s avonds", after: " "), "’s avonds")
        XCTAssertEqual(CompletionTypography.smartQuotes("'sterk'", after: " "), "‘sterk’")
    }
}
