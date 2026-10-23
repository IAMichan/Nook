import XCTest

final class PullRequestReviewGuideTests: XCTestCase {
    func testParsingKeepsOrderDropsUnknownFilesAndCoversTheRest() throws {
        let answer: [String: Any] = ["stops": [
            ["title": "Core change", "summary": "Adds the cache.", "attention": "close",
             "files": [["path": "Sources/Cache.swift", "note": "new type"], ["path": "nope.swift", "note": "x"]],
             "questions": ["Should entries expire?", "  "]],
            ["title": "Wiring", "summary": "Uses it.", "attention": "weird",
             "files": [["path": "Sources/App.swift", "note": "calls it"], ["path": "Sources/Cache.swift", "note": "again"]],
             "questions": []],
            ["title": "  ", "summary": "dropped", "attention": "skim", "files": [], "questions": []],
        ]]
        let files = ["Sources/Cache.swift", "Sources/App.swift", "Package.resolved"]
        let guide = try XCTUnwrap(PullRequestReviewGuide.parse(answer, files: files, headSHA: "abc"))
        XCTAssertEqual(guide.stops.map(\.title), ["Core change", "Wiring", "Other changes"])
        XCTAssertEqual(guide.stops[0].attention, .close)
        XCTAssertEqual(guide.stops[0].files.map(\.path), ["Sources/Cache.swift"])
        XCTAssertEqual(guide.stops[0].questions, ["Should entries expire?"])
        XCTAssertEqual(guide.stops[1].attention, .normal)
        XCTAssertEqual(guide.stops[1].files.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(guide.stops[2].files.map(\.path), ["Package.resolved"])
        XCTAssertEqual(guide.stops[2].attention, .skim)
        XCTAssertTrue(guide.isCurrent(for: "abc"))
        XCTAssertFalse(guide.isCurrent(for: "def"))
    }

    func testAnAnswerWithoutStopsIsNoGuide() {
        XCTAssertNil(PullRequestReviewGuide.parse([:], files: ["a"], headSHA: "x"))
        XCTAssertNil(PullRequestReviewGuide.parse(["stops": []], files: ["a"], headSHA: "x"))
    }

    func testThePromptHoldsEveryFileWithinBudget() {
        let big = String(repeating: "+line\n", count: 30_000)
        let prompt = PullRequestReviewGuide.prompt(title: "Add cache", body: "Why", base: "main", head: "feat",
                                                   commits: ["abc Add cache"],
                                                   files: [("a.swift", "modified", "+x"), ("big.json", "added", big), ("img.png", "added", nil)],
                                                   instructions: "Focus on threading")
        XCTAssertTrue(prompt.contains("### a.swift\n+x"))
        XCTAssertTrue(prompt.contains("### big.json"))
        XCTAssertTrue(prompt.contains("(no diff: binary or too large)"))
        XCTAssertTrue(prompt.contains("Focus on threading"))
        XCTAssertLessThan(prompt.count, 80_000)
    }

    func testTheSchemaIsStrict() {
        let schema = PullRequestReviewGuide.schema
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let stop = ((schema["properties"] as? [String: Any])?["stops"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(stop?["required"] as? [String], ["attention", "files", "questions", "summary", "title"])
    }

    func testGuidesAreKeptPerPullRequest() {
        let defaults = UserDefaults(suiteName: "guide-tests-\(UUID().uuidString)")!
        let guide = PullRequestReviewGuide(headSHA: "a", written: Date(), stops: [])
        PullRequestReviewGuides.save(guide, for: "acme/web#1", defaults: defaults)
        XCTAssertEqual(PullRequestReviewGuides.load("acme/web#1", defaults: defaults), guide)
        XCTAssertNil(PullRequestReviewGuides.load("acme/web#2", defaults: defaults))
    }
}
