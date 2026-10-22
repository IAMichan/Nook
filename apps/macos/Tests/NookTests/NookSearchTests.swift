import XCTest

/// Search everything: the query language, ranking, filters and highlighting (`SearchQuery`, `SearchIndex`, `SearchHighlight`).
final class NookSearchTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private var documents: [SearchDocument] {
        [
            SearchDocument(id: "run:a", kind: .session, title: "Fix login bug", subtitle: "Claude Code · nook",
                           facets: ["project": "nook", "agent": "Claude Code"],
                           passages: [SearchPassage(text: "The login form crashes on submit", author: "me")]),
            SearchDocument(id: "conversation:b", kind: .conversation, title: "Dinner plans",
                           passages: [SearchPassage(text: "Use the login to the restaurant site", author: "nook")]),
            SearchDocument(id: "chat:c", kind: .chat, title: "Anna", subtitle: "Telegram", facets: ["app": "Telegram"],
                           flags: ["unread"], passages: [SearchPassage(text: "See you at dinner", author: "Anna")]),
        ]
    }

    private func ids(_ text: String, in documents: [SearchDocument]? = nil) -> [String] {
        SearchIndex(documents ?? self.documents).search(SearchQuery.parse(text, calendar: calendar)).map(\.id)
    }

    // MARK: Parsing

    func testParsesTheQueryLanguage() {
        let query = SearchQuery.parse("deploy \"pull request\" -draft in:agents from:me is:unread after:2026-10-01 project:Nook",
                                      calendar: calendar)
        XCTAssertEqual(query.groups, [[SearchQuery.Term(text: "deploy", phrase: false)], [SearchQuery.Term(text: "pull request", phrase: true)]])
        XCTAssertEqual(query.excluded, [SearchQuery.Term(text: "draft", phrase: false)])
        XCTAssertEqual(query.kinds, [.session])
        XCTAssertEqual(query.authors, ["me"])
        XCTAssertEqual(query.flags, ["unread"])
        XCTAssertEqual(query.after, date(2026, 10, 1))
        XCTAssertEqual(query.facets, ["project": ["nook"]])
    }

    func testOrJoinsAlternatives() {
        let query = SearchQuery.parse("cat OR dog | bird fish")
        XCTAssertEqual(query.groups.map { group in group.map { $0.text } }, [["cat", "dog", "bird"], ["fish"]])
    }

    func testFilterValuesInQuotesAndOtherLanguages() {
        let query = SearchQuery.parse("from:\"Anna de Vries\" van:ik is:ongelezen -in:instellingen")
        XCTAssertEqual(query.authors, ["anna de vries", "me"])
        XCTAssertEqual(query.flags, ["unread"])
        XCTAssertEqual(query.excludedKinds, [.setting])
    }

    func testUnknownKeysStayText() {
        let query = SearchQuery.parse("https://example.com foo:bar")
        XCTAssertTrue(query.facets.isEmpty)
        XCTAssertEqual(query.groups.count, 2)
        XCTAssertTrue(query.groups[0][0].phrase, "a URL is searched as its words in order")
    }

    func testDateWords() {
        let now = date(2026, 10, 22).addingTimeInterval(15 * 3600)
        let today = SearchQuery.dateRange("today", now: now, calendar: calendar)
        XCTAssertEqual(today?.start, date(2026, 10, 22))
        XCTAssertEqual(today?.end, date(2026, 10, 23))
        XCTAssertEqual(SearchQuery.dateRange("gisteren", now: now, calendar: calendar)?.start, date(2026, 10, 21))
        XCTAssertEqual(SearchQuery.dateRange("7d", now: now, calendar: calendar)?.start, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(SearchQuery.dateRange("2026-09", now: now, calendar: calendar)?.end, date(2026, 10, 1))
        XCTAssertEqual(SearchQuery.dateRange("2025", now: now, calendar: calendar)?.start, date(2025, 1, 1))
        XCTAssertNil(SearchQuery.dateRange("soon", now: now, calendar: calendar))
        let on = SearchQuery.parse("on:2026-10-05", now: now, calendar: calendar)
        XCTAssertEqual(on.after, date(2026, 10, 5))
        XCTAssertEqual(on.before, date(2026, 10, 6))
    }

    func testKindNames() {
        XCTAssertEqual(SearchKind.named("sess"), .session)
        XCTAssertEqual(SearchKind.named("mem"), .memory)
        XCTAssertEqual(SearchKind.named("Notities"), .note)
        XCTAssertNil(SearchKind.named("no"), "nook, notes and notices all start with it")
    }

    // MARK: Finding and ranking

    func testTitleRanksAboveText() {
        XCTAssertEqual(ids("login"), ["run:a", "conversation:b"])
    }

    func testTyposAndWordStarts() {
        XCTAssertEqual(ids("logn"), ["run:a", "conversation:b"], "one typo")
        XCTAssertEqual(Set(ids("dinn")), ["conversation:b", "chat:c"], "the start of a word")
        XCTAssertEqual(ids("crash"), ["run:a"], "the start of a word in a passage")
    }

    func testPhrasesExclusionsAndAlternatives() {
        XCTAssertEqual(ids("\"the login form\""), ["run:a"])
        XCTAssertEqual(ids("login -crashes"), ["conversation:b"])
        XCTAssertEqual(Set(ids("anna OR fix")), ["run:a", "chat:c"])
        XCTAssertEqual(ids("login dinner"), ["conversation:b"], "every word must match")
    }

    func testFilters() {
        XCTAssertEqual(ids("from:anna dinner"), ["chat:c"])
        XCTAssertEqual(ids("from:me login"), ["run:a"], "only what you wrote")
        XCTAssertEqual(ids("in:chats"), ["chat:c"], "a filter alone lists everything it keeps")
        XCTAssertEqual(ids("is:unread"), ["chat:c"])
        XCTAssertEqual(ids("app:telegram dinner"), ["chat:c"])
        XCTAssertEqual(ids("project:nook"), ["run:a"])
        XCTAssertEqual(ids("-in:agents login"), ["conversation:b"])
        XCTAssertEqual(ids("/cr[a-z]+es/"), ["run:a"])
        XCTAssertEqual(ids(""), [])
    }

    func testDateFilters() {
        let notes = [
            SearchDocument(id: "note:old", kind: .note, title: "Standup", date: date(2026, 9, 1)),
            SearchDocument(id: "note:new", kind: .note, title: "Standup", date: date(2026, 10, 15)),
        ]
        XCTAssertEqual(ids("standup after:2026-10-01", in: notes), ["note:new"])
        XCTAssertEqual(ids("standup before:2026-10-01", in: notes), ["note:old"])
    }

    func testRecentFirstAmongEquals() {
        let now = Date()
        let reports = [
            SearchDocument(id: "old", kind: .conversation, title: "Report", date: now.addingTimeInterval(-60 * 86_400)),
            SearchDocument(id: "new", kind: .conversation, title: "Report", date: now.addingTimeInterval(-3600)),
        ]
        XCTAssertEqual(SearchIndex(reports).search(SearchQuery.parse("report"), now: now).map(\.id), ["new", "old"])
    }

    func testIgnoresAccents() {
        let documents = [SearchDocument(id: "x", kind: .memory, title: "Café Résumé")]
        let hit = SearchIndex(documents).search(SearchQuery.parse("cafe")).first
        XCTAssertEqual(hit?.id, "x")
        XCTAssertEqual(hit?.titleRanges, [0..<4])
    }

    // MARK: Highlighting

    func testHighlightsTitleAndSnippet() {
        let hit = SearchIndex(documents).search(SearchQuery.parse("login")).first
        XCTAssertEqual(hit?.titleRanges, [4..<9])
        XCTAssertEqual(hit?.snippet, "The login form crashes on submit")
        XCTAssertEqual(hit?.snippetRanges, [4..<9])
        XCTAssertEqual(hit?.passage?.author, "me")
    }

    func testSnippetCutsAroundTheMatch() {
        let text = String(repeating: "alpha ", count: 50) + "needle " + String(repeating: "omega ", count: 50)
        let cut = SearchHighlight.snippet(text, needles: ["needle"], regexRanges: [])
        XCTAssertTrue(cut.text.hasPrefix("…"))
        XCTAssertTrue(cut.text.hasSuffix("…"))
        XCTAssertEqual(cut.ranges.count, 1)
        let range = cut.ranges[0]
        XCTAssertEqual((cut.text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)), "needle")
    }

    func testSegments() {
        let pieces = SearchHighlight.segments("Fix login bug", ranges: [4..<9])
        XCTAssertEqual(pieces.map { $0.text }, ["Fix ", "login", " bug"])
        XCTAssertEqual(pieces.map { $0.marked }, [false, true, false])
        XCTAssertEqual(SearchHighlight.merge([0..<3, 2..<5, 7..<8]), [0..<5, 7..<8])
    }
}
