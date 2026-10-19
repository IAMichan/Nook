import XCTest

final class AutocompleteTests: XCTestCase {
    // MARK: GGUF

    private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func string(_ text: String) -> [UInt8] { le(UInt64(text.utf8.count)) + Array(text.utf8) }

    /// A minimal GGUF header: name and architecture as strings, a context length, and a string array in between that must be skipped.
    private func sampleGGUF(version: UInt32 = 3, architecture: String = "qwen3") -> Data {
        var bytes = Array("GGUF".utf8) + le(version) + le(UInt64(0)) + le(UInt64(4))
        bytes += string("general.architecture") + le(UInt32(8)) + string(architecture)
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

    // MARK: Finding models on this Mac

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-ac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testFindsTextModelsOnThisMac() throws {
        let home = try makeHome()
        let models = home.appendingPathComponent("Library/Application Support/SomeWriter/Models", isDirectory: true)
        let nook = home.appendingPathComponent("Library/Application Support/Nook/Autocomplete/Models", isDirectory: true)
        let studio = home.appendingPathComponent(".lmstudio/models/qwen", isDirectory: true)
        for folder in [models, nook, studio] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try sampleGGUF().write(to: models.appendingPathComponent("qwen.gguf"))
        try sampleGGUF().write(to: models.appendingPathComponent("vision-mmproj.gguf"))
        try Data("junk".utf8).write(to: models.appendingPathComponent("broken.gguf"))
        try sampleGGUF(architecture: "nomic-bert").write(to: models.appendingPathComponent("embedding.gguf"))
        try sampleGGUF().write(to: nook.appendingPathComponent("own.gguf"))
        try sampleGGUF().write(to: studio.appendingPathComponent("studio.gguf"))

        let found = CompletionModelLocator.foundModels(home: home, minimumBytes: 0)
        XCTAssertEqual(Set(found.map { $0.url.lastPathComponent }), ["qwen.gguf", "studio.gguf"], "Nook's own folder, projectors, embeddings and broken files are left out")
        XCTAssertTrue(found.allSatisfy { $0.source == .found })
        XCTAssertEqual(found.first?.title, "Qwen3 0.6B")
        XCTAssertTrue(CompletionModelLocator.foundModels(home: home).isEmpty, "test files are far below the size of a language model")
    }

    func testStoredPathWinsOverFoundModels() throws {
        let home = try makeHome()
        let own = home.appendingPathComponent("mine.gguf")
        try sampleGGUF().write(to: own)
        let picked = CompletionModelLocator.resolve(storedPath: own.path, candidates: [])
        XCTAssertEqual(picked?.url.lastPathComponent, "mine.gguf")
        XCTAssertEqual(picked?.source, .custom)
        XCTAssertNil(CompletionModelLocator.resolve(storedPath: home.appendingPathComponent("gone.gguf").path, candidates: []))
        XCTAssertNil(CompletionModelLocator.resolve(storedPath: "", candidates: []))
    }

    func testSourceFallsBackToTheBrainModel() throws {
        let home = try makeHome()
        let file = home.appendingPathComponent("base.gguf")
        try sampleGGUF().write(to: file)
        let gguf = try XCTUnwrap(CompletionModelLocator.model(at: file, source: .found))
        let brains = [(id: "mlx-community/gemma", title: "Gemma"), (id: "mlx-community/qwen", title: "Qwen")]

        XCTAssertEqual(CompletionSource.resolve(stored: "", files: [gguf], brainModels: brains, preferredBrain: nil)?.identity, file.path,
                       "a GGUF model goes first")
        XCTAssertEqual(CompletionSource.resolve(stored: "", files: [], brainModels: brains, preferredBrain: "mlx-community/qwen"),
                       .brain(id: "mlx-community/qwen", title: "Qwen"), "without one, the model the brain uses")
        XCTAssertEqual(CompletionSource.resolve(stored: "", files: [], brainModels: brains, preferredBrain: "apple")?.title, "Gemma")
        XCTAssertEqual(CompletionSource.resolve(stored: "brain:mlx-community/gemma", files: [gguf], brainModels: brains, preferredBrain: nil),
                       .brain(id: "mlx-community/gemma", title: "Gemma"), "a chosen brain model wins over a GGUF file")
        XCTAssertNil(CompletionSource.resolve(stored: "brain:gone", files: [gguf], brainModels: brains, preferredBrain: nil))
        XCTAssertNil(CompletionSource.resolve(stored: "", files: [], brainModels: [], preferredBrain: nil))
        XCTAssertEqual(CompletionSource.brain(id: "x", title: "X").identity, "brain:x")
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

    func testRecentlyFinishedWordAlsoWhileTypingTheNext() {
        XCTAssertEqual(CompletionTextAnalysis.recentlyFinishedWord(in: "ik heb het gedaam ")?.tail, " ")
        let typing = CompletionTextAnalysis.recentlyFinishedWord(in: "ik heb het gedaam en")
        XCTAssertEqual(typing?.word, "gedaam")
        XCTAssertEqual(typing?.tail, " en")
        let comma = CompletionTextAnalysis.recentlyFinishedWord(in: "bedankt voor je bericjt, ik")
        XCTAssertEqual(comma?.word, "bericjt")
        XCTAssertEqual(comma?.tail, ", ik")
        XCTAssertEqual(CompletionTextAnalysis.recentlyFinishedWord(in: "thanks,")?.word, "thanks")
        XCTAssertEqual(CompletionTextAnalysis.recentlyFinishedWord(in: "nog bezig")?.word, "nog")
        XCTAssertNil(CompletionTextAnalysis.recentlyFinishedWord(in: "bezig"), "the first word is not finished yet")
        XCTAssertNil(CompletionTextAnalysis.recentlyFinishedWord(in: "ik ben bij NASA en"))
        XCTAssertNil(CompletionTextAnalysis.recentlyFinishedWord(in: "gedaam en nog"), "only the word right before the one being typed")
    }

    func testLikelyFixesStayCloseToTheWord() {
        XCTAssertEqual(CompletionTextAnalysis.editDistance("gedaam", "gedaan"), 1)
        XCTAssertEqual(CompletionTextAnalysis.editDistance("teh", "the"), 1, "a swap is one change")
        XCTAssertEqual(CompletionTextAnalysis.editDistance("", "abc"), 3)
        XCTAssertTrue(CompletionTextAnalysis.isLikelyFix("gedaan", for: "gedaam"))
        XCTAssertTrue(CompletionTextAnalysis.isLikelyFix("bericht", for: "bericjt"))
        XCTAssertTrue(CompletionTextAnalysis.isLikelyFix("receive", for: "recieve"))
        XCTAssertFalse(CompletionTextAnalysis.isLikelyFix("gedaam", for: "gedaam"))
        XCTAssertFalse(CompletionTextAnalysis.isLikelyFix("ge daan", for: "gedaam"))
        XCTAssertFalse(CompletionTextAnalysis.isLikelyFix("hut", for: "hoi"), "two changes in a short word is another word")
        XCTAssertFalse(CompletionTextAnalysis.isLikelyFix("morgenavond", for: "morgen"))
    }

    // MARK: Emoji

    func testEmojiQueryAndDutchNames() {
        XCTAssertEqual(CompletionEmojiCatalog.query(in: "haha :lachen"), "lachen")
        XCTAssertNil(CompletionEmojiCatalog.query(in: "om 10:30"))
        XCTAssertEqual(CompletionEmojiCatalog.query(in: "zie :x"), "x")
        XCTAssertEqual(CompletionEmojiCatalog.query(in: "zie :"), "", "right after the colon the picker opens")
        XCTAssertNil(CompletionEmojiCatalog.query(in: "Note:"))
        XCTAssertNil(CompletionEmojiCatalog.query(in: "zie : x"))
        XCTAssertEqual(CompletionEmojiCatalog.search("lachen").first?.character, "😂")
        XCTAssertEqual(CompletionEmojiCatalog.search("duim").first?.character, "👍")
        XCTAssertEqual(CompletionEmojiCatalog.search("joy").first?.character, "😂")
        XCTAssertTrue(CompletionEmojiCatalog.all.count > 250)
    }

    func testPickerChoicesStartWithRecentEmoji() {
        let opening = CompletionEmojiCatalog.choices(for: "", recent: ["🔥", "nonsense"], limit: 9)
        XCTAssertEqual(opening.count, 9)
        XCTAssertEqual(opening.first?.character, "🔥")
        XCTAssertEqual(opening.dropFirst().first?.character, "😂", "then the most used")
        XCTAssertEqual(opening.filter { $0.character == "🔥" }.count, 1)
        XCTAssertEqual(CompletionEmojiCatalog.choices(for: "lachen", recent: [], limit: 9).first?.character, "😂")
        XCTAssertTrue(CompletionEmojiCatalog.choices(for: "zzzzqq", recent: [], limit: 9).isEmpty)
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
        object.removeValue(forKey: "menuBarCount")
        var apps = object["apps"] as! [String: [String: Any]]
        apps["com.tinyspeck.slackmacgap"]?.removeValue(forKey: "leaveTab")
        object["apps"] = apps
        let decoded = CompletionPreferences.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.maxWords, 5)
        XCTAssertTrue(decoded.emoji)
        XCTAssertFalse(decoded.menuBarCount)
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
        stats.recordAccepted(" see you", first: true, app: "com.apple.mail", on: day)
        stats.recordAccepted(" soon", first: false, app: "com.apple.mail", on: day)
        stats.recordAccepted("😂", first: true, app: "com.tinyspeck.slackmacgap", on: day)
        XCTAssertEqual(stats.day(day).words, 4)
        XCTAssertEqual(stats.day(day).takes, 3)
        XCTAssertEqual(stats.totalAccepted, 2)
        XCTAssertEqual(stats.acceptance, 1)
        XCTAssertEqual(stats.recent(3, endingAt: day).count, 3)
        XCTAssertEqual(stats.topApps().map(\.bundleID), ["com.apple.mail", "com.tinyspeck.slackmacgap"])
        XCTAssertEqual(stats.apps["com.apple.mail"], CompletionStats.AppCount(takes: 2, words: 3))
        XCTAssertEqual(stats.week(endingAt: day).takes, 3)
    }

    func testStreak() {
        var stats = CompletionStats()
        let calendar = Calendar(identifier: .gregorian)
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 1...3 { stats.recordAccepted(" a", first: true, on: calendar.date(byAdding: .day, value: -offset, to: today)!) }
        XCTAssertEqual(stats.streak(endingAt: today, calendar: calendar), 3, "today has nothing yet, so the streak runs to yesterday")
        stats.recordAccepted(" b", first: true, on: today)
        XCTAssertEqual(stats.streak(endingAt: today, calendar: calendar), 4)
        XCTAssertEqual(CompletionStats().streak(endingAt: today), 0)
    }

    func testOldStatsFilesStillRead() throws {
        let old = #"{"days":{"2026-10-19":{"shown":5,"accepted":2,"words":7,"characters":30}}}"#
        let stats = try JSONDecoder().decode(CompletionStats.self, from: Data(old.utf8))
        XCTAssertEqual(stats.days["2026-10-19"]?.takes, 2, "older files counted no takes: each accepted suggestion counts once")
        XCTAssertEqual(stats.totalWords, 7)
        XCTAssertTrue(stats.apps.isEmpty)
        let again = try JSONDecoder().decode(CompletionStats.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(again, stats)
    }

    func testSmartQuotes() {
        XCTAssertEqual(CompletionTypography.smartQuotes(" \"top\" en it's", after: "s"), " “top” en it’s")
        XCTAssertEqual(CompletionTypography.smartQuotes("'s avonds", after: " "), "’s avonds")
        XCTAssertEqual(CompletionTypography.smartQuotes("'sterk'", after: " "), "‘sterk’")
    }

    func testDownloadLinks() {
        let page = CompletionCatalogModel.custom(from: " https://huggingface.co/someone/Model-GGUF/blob/main/model.Q4_K_M.gguf?download=true ")
        XCTAssertEqual(page?.url.absoluteString, "https://huggingface.co/someone/Model-GGUF/resolve/main/model.Q4_K_M.gguf")
        XCTAssertEqual(page?.fileName, "model.Q4_K_M.gguf")
        XCTAssertEqual(page?.name, "model.Q4_K_M")
        XCTAssertEqual(CompletionCatalogModel.custom(from: "https://hf.co/a/b/resolve/main/sub/x.gguf")?.url.absoluteString,
                       "https://huggingface.co/a/b/resolve/main/sub/x.gguf")
        XCTAssertEqual(CompletionCatalogModel.custom(from: "https://example.com/models/y.gguf")?.fileName, "y.gguf")
        XCTAssertNil(CompletionCatalogModel.custom(from: "http://example.com/y.gguf"), "only https")
        XCTAssertNil(CompletionCatalogModel.custom(from: "https://huggingface.co/a/b"), "a page, not a file")
        XCTAssertNil(CompletionCatalogModel.custom(from: "https://huggingface.co/a/b/blob/main/mmproj-x.gguf"), "a vision projector")
        XCTAssertNil(CompletionCatalogModel.custom(from: "hallo"))
        XCTAssertEqual(CompletionCatalogModel.catalog.first?.url.absoluteString,
                       "https://huggingface.co/mradermacher/Qwen3-0.6B-Base-i1-GGUF/resolve/main/Qwen3-0.6B-Base.i1-Q4_K_M.gguf")
    }

    func testFinishedWordsForStreaming() {
        XCTAssertEqual(CompletionStreaming.finishedWords(""), 0)
        XCTAssertEqual(CompletionStreaming.finishedWords(" in"), 0, "the model may still be writing it")
        XCTAssertEqual(CompletionStreaming.finishedWords(" in de"), 1)
        XCTAssertEqual(CompletionStreaming.finishedWords(" in de "), 2)
        XCTAssertEqual(CompletionStreaming.finishedWords(" in de input."), 3)
        // A part shown while streaming drops the word that is still being written.
        XCTAssertEqual(CompletionSuggestion.make(raw: " in de inp", before: "eroverheen", maxWords: 8, truncated: true)?.remaining, " in de")
    }

    func testPromptWindowIsShorterAndSteady() {
        let builder = PromptBuilder()
        let text = String(repeating: "woord ", count: 500)
        let a = builder.window(of: text)
        let b = builder.window(of: text + "x")
        XCTAssertLessThanOrEqual(a.count, builder.windowLength + builder.windowStep)
        XCTAssertTrue(b.hasPrefix(a), "one more letter keeps the same start, so the model's cache still fits")
    }

    // MARK: Quality

    func testHealingTakesOffTheWordAtTheCursor() {
        XCTAssertEqual(CompletionHealing.split("Header\n\nIk zie je morg").stem, "Header\n\nIk zie je")
        XCTAssertEqual(CompletionHealing.split("Header\n\nIk zie je morg").pending, " morg")
        XCTAssertEqual(CompletionHealing.split("Hoi Lisa,").pending, "", "after punctuation there is nothing to heal")
        XCTAssertEqual(CompletionHealing.split("Hallo").pending, "", "a word that is all there is stays")
        XCTAssertEqual(CompletionHealing.split("Zie je\nmorg").pending, "morg")
        XCTAssertTrue(CompletionHealing.fits(Array(" mor".utf8), Array(" morg".utf8)))
        XCTAssertTrue(CompletionHealing.fits(Array(" morgen".utf8), Array(" morg".utf8)))
        XCTAssertFalse(CompletionHealing.fits(Array(" maan".utf8), Array(" morg".utf8)))
        XCTAssertFalse(CompletionHealing.fits([], Array(" morg".utf8)))
        XCTAssertTrue(CompletionHealing.continuesWord("en"))
        XCTAssertFalse(CompletionHealing.continuesWord(" om"))
        XCTAssertFalse(CompletionHealing.continuesWord(","))
    }

    func testHalfWordsAreNeverShown() {
        XCTAssertEqual(CompletionSuggestion.make(raw: " see you tomor", before: "I'll", maxWords: 8, unfinished: true)?.remaining, " see you")
        XCTAssertNil(CompletionSuggestion.make(raw: " tomor", before: "I'll", maxWords: 8, unfinished: true))
        XCTAssertEqual(CompletionSuggestion.make(raw: " see you ", before: "I'll", maxWords: 8, unfinished: true)?.remaining, " see you",
                       "a word that ended with a space is whole")
    }

    func testCopiedTextIsNoSuggestion() {
        let before = "Thanks for the update on the project. Thanks for"
        XCTAssertNil(CompletionSuggestion.make(raw: " the update on", before: before, maxWords: 8))
        XCTAssertNotNil(CompletionSuggestion.make(raw: " your quick reply", before: before, maxWords: 8))
        XCTAssertNotNil(CompletionSuggestion.make(raw: " the update", before: before, maxWords: 8), "two words may repeat")
    }

    func testOptionsAskForASureSuggestion() {
        let careful = CompletionOptions(maxWords: 4, eagerness: 0)
        let eager = CompletionOptions(maxWords: 4, eagerness: 1)
        XCTAssertGreaterThan(careful.minSequenceProbability, eager.minSequenceProbability)
        XCTAssertGreaterThan(CompletionOptions().minFirstProbability, 0.15)
        XCTAssertFalse(CompletionOptions().heal)
    }

    func testFollowUpSuggestionsMayBeLessSure() {
        let usual = CompletionOptions(maxWords: 8, eagerness: 0.5)
        let next = usual.continuing()
        XCTAssertLessThan(next.minFirstProbability, usual.minFirstProbability)
        XCTAssertLessThan(next.minProbability, usual.minProbability)
        XCTAssertLessThan(next.minSequenceProbability, usual.minSequenceProbability)
        XCTAssertEqual(next.maxWords, usual.maxWords)
        XCTAssertGreaterThan(CompletionOptions(maxWords: 8, eagerness: 1).continuing().minFirstProbability, 0)
    }

    func testScreenTextKeepsSentencesNotButtons() {
        let text = "Inbox\nReply\nArchive\nHoi Michan, kun je morgen om tien uur langskomen?\nSend"
        XCTAssertEqual(CompletionScreenText.prose(text), "Hoi Michan, kun je morgen om tien uur langskomen?")
    }

    func testBaseModelsGoBeforeChatModels() {
        func file(_ name: String, _ source: CompletionModelFile.Source = .found) -> CompletionModelFile {
            CompletionModelFile(url: URL(fileURLWithPath: "/models/\(name)"), bytes: 1, modified: Date(), info: nil, source: source)
        }
        let chat = file("Qwen2.5-7B-Instruct-Q4_K_M.gguf")
        let coder = file("qwen2.5-coder-1.5b.gguf")
        let base = file("gemma-3-1b-pt.i1-Q4_K_M.gguf", .nook)
        XCTAssertEqual(CompletionModelLocator.resolve(storedPath: "", candidates: [chat, coder, base]), base)
        XCTAssertEqual(CompletionModelLocator.resolve(storedPath: "", candidates: [chat, coder]), chat, "otherwise the newest, as before")
        XCTAssertGreaterThan(CompletionModelLocator.suitability(file("Qwen3-1.7B-Base.i1-Q4_K_M.gguf")), CompletionModelLocator.suitability(chat))
    }
}
