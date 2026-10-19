import XCTest

/// The pull request list in one GraphQL request per account.
final class PullRequestGraphQLTests: XCTestCase {
    func testQueryAsksForEverythingAtOnce() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: PullRequestGraphQL.body()) as? [String: Any])
        let query = try XCTUnwrap(body["query"] as? String)
        XCTAssertTrue(query.contains("viewer { login }"), "no separate /user request")
        XCTAssertTrue(query.contains("statusCheckRollup { state }"), "CI comes with the row, not per pull request")
        let variables = try XCTUnwrap(body["variables"] as? [String: String])
        XCTAssertEqual(variables["mine"], "is:pr is:open archived:false author:@me sort:updated-desc")
        XCTAssertTrue(variables["reviews"]?.contains("review-requested:@me") == true)
        XCTAssertEqual(variables["mineClosed"], "is:pr is:closed archived:false author:@me sort:updated-desc")
        XCTAssertTrue(variables["reviewsClosed"]?.contains("reviewed-by:@me") == true)
        XCTAssertTrue(query.contains("isDraft updatedAt state"), "open, closed or merged comes with the row")
    }

    func testParse() throws {
        let answer = #"""
        {"data":{"viewer":{"login":"michan"},
          "mine":{"nodes":[{"number":119,"title":"Agents-tab","url":"https://github.com/IAMichan/nook/pull/119","isDraft":false,
            "updatedAt":"2026-10-18T19:00:00Z","author":{"login":"michan"},"repository":{"nameWithOwner":"IAMichan/nook"},
            "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
            {"number":7,"title":"Concept","url":"https://github.com/a/b/pull/7","isDraft":true,"updatedAt":"2026-10-17T10:00:00Z",
            "author":{"login":"michan"},"repository":{"nameWithOwner":"a/b"},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
            {}]},
          "reviews":{"nodes":[{"number":3,"title":"Fix","url":"https://github.com/c/d/pull/3","isDraft":false,"updatedAt":"2026-10-16T08:00:00Z",
            "author":{"login":"anna"},"repository":{"nameWithOwner":"c/d"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}}]},
          "mineClosed":{"nodes":[{"number":100,"title":"Old","state":"MERGED","isDraft":false,"author":{"login":"michan"},
            "repository":{"nameWithOwner":"IAMichan/nook"}}]},
          "reviewsClosed":{"nodes":[{"number":4,"title":"Nope","state":"CLOSED","isDraft":false,"author":{"login":"anna"},
            "repository":{"nameWithOwner":"c/d"}}]}}}
        """#
        let list = try PullRequestGraphQL.parse(Data(answer.utf8))
        XCTAssertEqual(list.login, "michan")
        XCTAssertEqual(list.mine.map(\.id), ["IAMichan/nook#119", "a/b#7", "IAMichan/nook#100"],
                       "a node that is not a pull request is skipped; closed ones come after the open ones")
        XCTAssertEqual(list.mine.map(\.state), [.open, .open, .merged])
        XCTAssertEqual(list.reviews.map(\.state), [.open, .closed])
        XCTAssertEqual(list.mine.map(\.ci), [.failing, .unknown, .unknown])
        XCTAssertTrue(list.mine[1].draft)
        XCTAssertNotNil(list.mine[0].updated)
        XCTAssertEqual(list.reviews.first?.author, "anna")
        XCTAssertEqual(list.reviews.first?.ci, .pending)
    }

    func testErrorsAndStates() {
        XCTAssertThrowsError(try PullRequestGraphQL.parse(Data(#"{"errors":[{"message":"Bad credentials"}]}"#.utf8))) { error in
            XCTAssertEqual((error as? NookError)?.message, "GitHub: Bad credentials")
        }
        XCTAssertEqual(PullRequestGraphQL.ci("SUCCESS"), .passing)
        XCTAssertEqual(PullRequestGraphQL.ci("ERROR"), .failing)
        XCTAssertEqual(PullRequestGraphQL.ci("EXPECTED"), .pending)
        XCTAssertEqual(PullRequestGraphQL.state("MERGED"), .merged)
        XCTAssertEqual(PullRequestGraphQL.state(nil), .open)
    }

    func testSavedListWithoutStatesIsOpen() throws {
        let saved = #"{"repo":"a/b","number":1,"title":"T","draft":false,"author":"ada","ci":"passing"}"#
        let item = try JSONDecoder().decode(PullRequestItem.self, from: Data(saved.utf8))
        XCTAssertEqual(item.state, .open)
        XCTAssertEqual(item.ci, .passing)
        let again = try JSONDecoder().decode(PullRequestItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again, item)
    }
}
