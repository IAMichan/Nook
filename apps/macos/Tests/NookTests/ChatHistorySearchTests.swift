import XCTest

/// Search everything through every chat app's whole history: which words the apps are asked for, how found messages
/// come back as chats (`ChatHistorySearch`), and how they join the index's hits (`SearchMerge`).
final class ChatHistorySearchTests: XCTestCase {
    private func message(_ id: String, _ text: String, _ day: Double, sender: String = "") -> InboxMessage {
        InboxMessage(id: id, sender: sender, text: text, date: Date(timeIntervalSince1970: day * 86_400))
    }

    // MARK: Words

    func testAsksForEveryWordLongestFirst() {
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("michan bierdienst")), ["bierdienst", "michan"])
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("\"bier dienst\" OR koffiepauze")), ["koffiepauze", "dienst", "bier"])
    }

    func testSkipsShortWordsAndCapsTheCount() {
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("a bier")), ["bier"])
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("een twee drie vier vijf zes")).count, ChatHistorySearch.maxWords)
    }

    func testAsksNothingWhenChatsAreLeftOut() {
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("bierdienst in:agents")), [])
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("bierdienst -in:chats")), [])
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("bierdienst in:chats")), ["bierdienst"])
        XCTAssertEqual(ChatHistorySearch.words(SearchQuery.parse("is:unread")), [])
    }

    // MARK: Found messages as chats

    func testGroupsFoundMessagesByChatWithoutRepeats() {
        let group = BridgedChat(app: "whatsapp", name: "VVB Senioren 9", messages: [], unread: 3)
        let anna = BridgedChat(app: "telegram", name: "Anna", messages: [], unread: nil)
        let post = message("1", "Bierdienst: Michan", 2)
        let chats = ChatHistorySearch.chats([
            (group, [post]),
            (anna, [message("2", "bier?", 1)]),
            (group, [message("3", "Michan rijdt", 1), post]),
        ])
        XCTAssertEqual(chats.map(\.name), ["VVB Senioren 9", "Anna"])
        XCTAssertEqual(chats[0].messages.map(\.id), ["3", "1"], "oldest first, the repeated message once")
        XCTAssertNil(chats[0].unread, "a search says nothing about what is unread")
    }

    func testMatchesTextAndSenderIgnoringCaseAndAccents() {
        XCTAssertTrue(ChatHistorySearch.matches(message("1", "Wie heeft BIERDIENST?", 0), ["bierdienst"]))
        XCTAssertTrue(ChatHistorySearch.matches(message("1", "ok", 0, sender: "Michan"), ["michan"]))
        XCTAssertTrue(ChatHistorySearch.matches(message("1", "Café om acht", 0), ["cafe"]))
        XCTAssertFalse(ChatHistorySearch.matches(message("1", "Koffie", 0), ["bier"]))
    }

    // MARK: Joining the index

    private let inboxChat = SearchDocument(
        id: "chat:whatsapp|vvb senioren 9", kind: .chat, title: "VVB Senioren 9", subtitle: "WhatsApp",
        passages: [SearchPassage(text: "Training donderdag", author: "Noah", date: Date(timeIntervalSince1970: 10 * 86_400), anchor: "new")])

    func testFoundPassagesJoinTheChatTheIndexHas() {
        let index = SearchIndex([inboxChat])
        XCTAssertTrue(index.search(SearchQuery.parse("michan bierdienst")).isEmpty, "the inbox keeps only the newest messages")
        let found = SearchDocument(id: inboxChat.id, kind: .chat, title: "VVB Senioren 9",
                                   passages: [SearchPassage(text: "🍺 bierdienst: Michan", author: "Lead", date: Date(timeIntervalSince1970: 86_400), anchor: "old"),
                                              SearchPassage(text: "Training donderdag", author: "Noah", date: Date(timeIntervalSince1970: 10 * 86_400), anchor: "new")])
        let documents = SearchMerge.documents([found], in: index)
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0].passages.compactMap(\.anchor), ["old", "new"], "every passage once")
        let hits = SearchMerge.hits(index.search(SearchQuery.parse("michan bierdienst")),
                                    adding: SearchIndex(documents).search(SearchQuery.parse("michan bierdienst")), limit: 10)
        XCTAssertEqual(hits.map(\.id), [inboxChat.id])
        XCTAssertEqual(hits.first?.passage?.anchor, "old", "the hit opens on the message that matched")
    }

    func testWordsMatchAcrossTheWholeChat() {
        // The matchday post names the user; the word "bierdienst" was in another message of the same group.
        let found = SearchDocument(id: inboxChat.id, kind: .chat, title: "VVB Senioren 9",
                                   passages: [SearchPassage(text: "🍺 Michan", anchor: "post"),
                                              SearchPassage(text: "Wie heeft er bierdienst zaterdag?", anchor: "ask")])
        let documents = SearchMerge.documents([found], in: SearchIndex([inboxChat]))
        XCTAssertEqual(SearchIndex(documents).search(SearchQuery.parse("michan bierdienst")).map(\.id), [inboxChat.id])
    }

    func testAChatTheIndexDoesNotHaveIsAHitOfItsOwn() {
        let other = SearchDocument(id: "chat:telegram|oud team", kind: .chat, title: "Oud team",
                                   passages: [SearchPassage(text: "bierdienst lijst", anchor: "x")])
        let index = SearchIndex([inboxChat])
        let documents = SearchMerge.documents([other], in: index)
        XCTAssertEqual(documents.map(\.id), [other.id])
    }

    func testMergedHitsKeepTheBetterScoreAndOrder() {
        func hit(_ id: String, _ score: Double, _ snippet: String = "") -> SearchHit {
            SearchHit(document: SearchDocument(id: id, kind: .chat, title: id), score: score, titleRanges: [],
                      snippet: snippet, snippetRanges: [], passage: nil, matches: 1)
        }
        let merged = SearchMerge.hits([hit("a", 5), hit("b", 3)], adding: [hit("b", 1, "found"), hit("c", 4)], limit: 10)
        XCTAssertEqual(merged.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(merged.last?.score, 3, "the better of the two scores")
        XCTAssertEqual(merged.last?.snippet, "found", "the found hit holds more, so it shows")
        XCTAssertEqual(SearchMerge.hits([hit("a", 5), hit("b", 3)], adding: [hit("c", 4)], limit: 2).map(\.id), ["a", "c"])
    }

    func testOneMessageFromTwoAppsIsOnePassage() {
        let minute = Date(timeIntervalSince1970: 1_000_000)
        let phone = SearchPassage(text: "Bierdienst: Michan", date: minute, anchor: "wa-1")
        let mac = SearchPassage(text: "Bierdienst: Michan", date: minute.addingTimeInterval(1), anchor: "wadesktop-9")
        let other = SearchPassage(text: "Bierdienst: Noah", date: minute.addingTimeInterval(-86_400), anchor: "wadesktop-3")
        XCTAssertEqual(SearchMerge.passages([phone], adding: [mac, other, other]).compactMap(\.anchor), ["wadesktop-3", "wa-1"])
    }
}
