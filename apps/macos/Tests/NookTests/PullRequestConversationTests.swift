import XCTest

final class PullRequestConversationTests: XCTestCase {
    private func list(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private func event(_ id: String, _ kind: PullRequestEvent.Kind = .comment, author: String = "ada", minute: Int,
                       replyTo: String? = nil, resolved: Bool = false, body: String = "Hi") -> PullRequestEvent {
        var event = PullRequestEvent(id: id, kind: kind, author: author, body: body,
                                     date: Date(timeIntervalSince1970: Double(minute * 60)), url: nil)
        event.replyTo = replyTo
        event.resolved = resolved
        return event
    }

    func testParsesRepliesOutdatedLinesAndReactions() throws {
        let lineComments = try list("""
        [{"id": 1, "path": "a.swift", "line": 4, "position": 2, "user": {"login": "ada"}, "body": "Why?",
          "created_at": "2026-10-01T10:00:00Z", "reactions": {"+1": 2, "-1": 0, "heart": 1, "total_count": 3}},
         {"id": 2, "in_reply_to_id": 1, "path": "a.swift", "line": 4, "position": 2, "user": {"login": "bob"}, "body": "Because.",
          "created_at": "2026-10-01T11:00:00Z"},
         {"id": 3, "path": "b.swift", "line": null, "original_line": 9, "position": null, "user": {"login": "ada"}, "body": "Old",
          "created_at": "2026-10-01T12:00:00Z"},
         {"id": 4, "path": "c.swift", "line": null, "position": null, "subject_type": "file", "user": {"login": "ada"},
          "body": "Whole file", "created_at": "2026-10-01T13:00:00Z"}]
        """)
        let events = PullRequestDetailParser.events(reviews: [], comments: [], lineComments: lineComments)
        XCTAssertEqual(events.map(\.id), ["line-1", "line-2", "line-3", "line-4"])
        XCTAssertNil(events[0].replyTo)
        XCTAssertEqual(events[1].replyTo, "line-1")
        XCTAssertEqual(events[0].reactions, [PullRequestReaction(content: "+1", count: 2), PullRequestReaction(content: "heart", count: 1)])
        XCTAssertEqual(events[0].reactions.map(\.emoji), ["👍", "❤️"])
        XCTAssertFalse(events[0].outdated)
        XCTAssertTrue(events[2].outdated)
        XCTAssertEqual(events[2].kind, .lineComment(path: "b.swift", line: 9))
        XCTAssertFalse(events[3].outdated, "a comment on the whole file never had a line")
    }

    func testAppliesResolvedThreadsFromGraphQL() throws {
        let answer = try JSONSerialization.jsonObject(with: Data("""
        {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
          {"isResolved": true, "isOutdated": false, "comments": {"nodes": [{"databaseId": 1}]}},
          {"isResolved": false, "isOutdated": true, "comments": {"nodes": [{"databaseId": 5}]}}
        ]}}}}}
        """.utf8))
        let threads = PullRequestDetailParser.reviewThreads(answer)
        XCTAssertEqual(threads["line-1"], PullRequestThreadState(resolved: true, outdated: false))
        let events = PullRequestDetailParser.applying(threads, to: [
            event("line-1", .lineComment(path: "a", line: 1), minute: 1),
            event("line-2", .lineComment(path: "a", line: 1), minute: 2, replyTo: "line-1"),
            event("line-5", .lineComment(path: "b", line: 3), minute: 3),
            event("comment-9", minute: 4),
        ])
        XCTAssertEqual(events.map(\.resolved), [true, false, false, false])
        XCTAssertEqual(events.map(\.outdated), [false, false, true, false])
        XCTAssertNotNil(PullRequestDetailParser.reviewThreadsBody(repo: "acme/app", number: 12))
        XCTAssertNil(PullRequestDetailParser.reviewThreadsBody(repo: "nope", number: 12))
    }

    func testGroupsRepliesUnderTheirThread() {
        let items = PullRequestConversation.items([
            event("comment-1", minute: 1),
            event("line-2", .lineComment(path: "a", line: 1), minute: 2),
            event("commit-x", .commit(sha: "x"), minute: 3),
            event("line-3", .lineComment(path: "a", line: 1), author: "bob", minute: 4, replyTo: "line-2"),
            event("review-4", .review("COMMENTED"), minute: 5, body: ""),
            event("review-5", .review("APPROVED"), minute: 6, body: ""),
            event("line-6", .lineComment(path: "a", line: 1), minute: 7, replyTo: "line-404"),
        ])
        XCTAssertEqual(items.map(\.id), ["comment-1", "line-2", "review-5", "line-6"])
        XCTAssertEqual(items[1].replies.map(\.id), ["line-3"])
        XCTAssertTrue(items[1].isThread)
        XCTAssertEqual(PullRequestConversation.commentCount(items), 5)
    }

    func testFilterHidesBotsAndFinishedThreads() {
        let items = PullRequestConversation.items([
            event("comment-1", author: "ci[bot]", minute: 1),
            event("line-2", .lineComment(path: "a", line: 1), author: "lint[bot]", minute: 2),
            event("line-3", .lineComment(path: "a", line: 1), author: "ada", minute: 3, replyTo: "line-2"),
            event("line-4", .lineComment(path: "b", line: 1), minute: 4, resolved: true),
            event("review-5", .review("DISMISSED"), minute: 5, body: "Old review"),
            event("comment-6", minute: 6),
        ])
        XCTAssertEqual(items.filter(\.finished).map(\.id), ["line-4", "review-5"])
        let open = PullRequestConversation.filtered(items, bots: false, finished: false)
        XCTAssertEqual(open.map(\.id), ["line-2", "comment-6"], "a person's reply keeps the bot's thread")
        XCTAssertEqual(PullRequestConversation.filtered(items, bots: true, finished: true).count, items.count)
        XCTAssertEqual(PullRequestConversation.filtered(items, bots: true, finished: false).map(\.id), ["comment-1", "line-2", "comment-6"])
    }

    func testShowsTheMostRecentPage() {
        let items = (1...12).map { PullRequestConversationItem(root: event("comment-\($0)", minute: $0)) }
        let page = PullRequestConversation.recent(items, count: 10)
        XCTAssertEqual(page.hidden, 2)
        XCTAssertEqual(page.shown.first?.id, "comment-3")
        XCTAssertEqual(PullRequestConversation.recent(items, count: 20).hidden, 0)
    }

    func testPreviewIsOnePlainLine() {
        let body = "<!-- bot -->\n> [!NOTE]\n## Title\n- **Use** `let` and [docs](https://x.y)\n\nThanks"
        XCTAssertEqual(PullRequestConversation.preview(body), "Title Use let and docs Thanks")
    }
}
