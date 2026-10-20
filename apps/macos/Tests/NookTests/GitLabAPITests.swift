import XCTest

final class GitLabAPITests: XCTestCase {
    private func repo(_ url: String) throws -> RemoteRepository { try XCTUnwrap(RemoteRepository.detect(remoteURL: url)) }

    func testProjectIDEncodesEverySlash() throws {
        XCTAssertEqual(GitLabAPI.projectID(try repo("git@gitlab.com:group/sub/project.git")), "group%2Fsub%2Fproject")
    }

    func testListURLKeepsTheEncodedProjectAndTheBranch() throws {
        let url = try XCTUnwrap(GitLabAPI.listURL(repo: try repo("https://gitlab.com/g/p.git"), sourceBranch: "nook/fix a"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://gitlab.com/api/v4/projects/g%2Fp/merge_requests?"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("source_branch=nook/fix%20a"))
    }

    func testTokensAreNeverUsedOverHttpOrOnOtherForges() throws {
        XCTAssertNil(GitLabAPI.apiBase(try repo("http://gitlab.example.com/g/p.git")))
        XCTAssertNil(GitLabAPI.apiBase(try repo("https://github.com/a/b.git")))
        XCTAssertEqual(GitLabAPI.apiBase(try repo("https://gitlab.example.com:8443/g/p.git")), "https://gitlab.example.com:8443/api/v4")
    }

    func testDraftBecomesATitlePrefixOnce() {
        XCTAssertEqual(GitLabAPI.createBody(title: "Fix", description: "", source: "a", target: "main", draft: true)["title"] as? String, "Draft: Fix")
        XCTAssertEqual(GitLabAPI.createBody(title: "draft: Fix", description: "", source: "a", target: "main", draft: true)["title"] as? String, "draft: Fix")
        XCTAssertEqual(GitLabAPI.createBody(title: "Fix", description: "", source: "a", target: "main", draft: false)["title"] as? String, "Fix")
    }

    func testParseListMapsStates() throws {
        let json = """
        [{"iid":7,"web_url":"https://gitlab.com/g/p/-/merge_requests/7","title":"A","state":"merged","target_branch":"main","updated_at":"2026-01-02T03:04:05.123Z"},
         {"iid":8,"web_url":"https://gitlab.com/g/p/-/merge_requests/8","title":"B","state":"opened","draft":true},
         {"iid":9,"web_url":"https://gitlab.com/g/p/-/merge_requests/9","state":"closed"},
         {"iid":10,"state":"opened"}]
        """
        let links = try XCTUnwrap(GitLabAPI.parseList(Data(json.utf8), repository: try repo("https://gitlab.com/g/p.git"), sourceBranch: "b"))
        XCTAssertEqual(links.map(\.number), [7, 8, 9])
        XCTAssertEqual(links.map(\.state), [.merged, .draft, .closed])
        XCTAssertNotNil(links[0].updatedAt)
        XCTAssertEqual(links[0].repository, "g/p")
        XCTAssertNil(GitLabAPI.parseList(Data("{}".utf8), repository: try repo("https://gitlab.com/g/p.git"), sourceBranch: "b"))
    }

    func testErrorMessageShapes() {
        XCTAssertEqual(GitLabAPI.errorMessage(Data(#"{"message":"401 Unauthorized"}"#.utf8)), "401 Unauthorized")
        XCTAssertEqual(GitLabAPI.errorMessage(Data(#"{"error":"insufficient_scope"}"#.utf8)), "insufficient_scope")
        XCTAssertEqual(GitLabAPI.errorMessage(Data(#"{"message":{"base":["Another open merge request already exists"]}}"#.utf8)),
                       "base Another open merge request already exists")
        XCTAssertNil(GitLabAPI.errorMessage(Data("[]".utf8)))
    }

    func testCreatedLink() {
        XCTAssertEqual(GitLabAPI.parseCreated(Data(#"{"web_url":"https://gitlab.com/g/p/-/merge_requests/1"}"#.utf8))?.absoluteString,
                       "https://gitlab.com/g/p/-/merge_requests/1")
        XCTAssertNil(GitLabAPI.parseCreated(Data("{}".utf8)))
    }

    func testTokenCheckReadsTheUser() {
        XCTAssertEqual(GitLabTokenCheck.from(status: 200, body: Data(#"{"id":1,"username":"michan"}"#.utf8)), .valid(username: "michan"))
        XCTAssertEqual(GitLabTokenCheck.from(status: 401, body: Data(#"{"message":"401 Unauthorized"}"#.utf8)), .rejected)
        XCTAssertEqual(GitLabTokenCheck.from(status: 403, body: Data(#"{"error":"insufficient_scope"}"#.utf8)), .rejected)
        // Not GitLab, a login page in front of it, or a server error: Nook cannot tell, so it does not call the token bad.
        XCTAssertEqual(GitLabTokenCheck.from(status: 200, body: Data("<html></html>".utf8)), .unreachable)
        XCTAssertEqual(GitLabTokenCheck.from(status: 502, body: Data()), .unreachable)
        XCTAssertTrue(GitLabTokenCheck.valid(username: "a").isValid)
        XCTAssertFalse(GitLabTokenCheck.rejected.isValid)
    }
}
