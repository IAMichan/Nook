import XCTest

final class SourceControlHostTests: XCTestCase {
    private func repo(_ url: String, file: StaticString = #filePath, line: UInt = #line) throws -> RemoteRepository {
        try XCTUnwrap(SourceControlHost.detect(remoteURL: url), url, file: file, line: line)
    }

    // MARK: Detection

    func testGitHubRemotes() throws {
        for url in ["https://github.com/acme/app.git", "git@github.com:acme/app.git", "ssh://git@github.com/acme/app.git",
                    "https://GitHub.com/acme/app/", "https://user:token@github.com/acme/app", "github.com:acme/app"] {
            let r = try repo(url)
            XCTAssertEqual(r.host, .github, url)
            XCTAssertEqual(r.path, "acme/app", url)
            XCTAssertEqual(r.hostName, "github.com", url)
            XCTAssertEqual(r.displayName, "acme/app")
        }
    }

    func testCredentialsNeverReachTheOrigin() throws {
        let r = try repo("https://user:secret@github.com/acme/app.git")
        XCTAssertFalse(r.webOrigin.contains("secret"))
        XCTAssertFalse(r.compareURL(base: "main", head: "x")!.absoluteString.contains("secret"))
    }

    func testSshWithPortDropsThePortFromTheWebOrigin() throws {
        let r = try repo("ssh://git@git.example.com:2222/team/app.git")
        XCTAssertEqual(r.hostName, "git.example.com")
        XCTAssertEqual(r.webOrigin, "https://git.example.com")
        XCTAssertEqual(r.host, .unknown("git.example.com"))
    }

    func testHttpsPortIsKeptForTheWebUI() throws {
        let r = try repo("https://gitlab.corp.io:8443/a/b.git")
        XCTAssertEqual(r.webOrigin, "https://gitlab.corp.io:8443")
        XCTAssertEqual(r.hostName, "gitlab.corp.io")
    }

    func testGitLabSubgroups() throws {
        let r = try repo("git@gitlab.com:group/sub/deep/project.git")
        XCTAssertEqual(r.host, .gitlab)
        XCTAssertEqual(r.path, "group/sub/deep/project")
    }

    func testSelfHostedHints() throws {
        XCTAssertEqual(try repo("https://gitlab.mycorp.nl/a/b").host, .gitlab)
        XCTAssertEqual(try repo("https://gitea.mycorp.nl/a/b").host, .gitea)
        XCTAssertEqual(try repo("https://forgejo.mycorp.nl/a/b").host, .forgejo)
        XCTAssertEqual(try repo("https://codeberg.org/a/b").host, .forgejo)
        XCTAssertEqual(try repo("https://bitbucket.mycorp.nl/a/b").host, .bitbucket)
        XCTAssertEqual(try repo("https://bitbucket.org/a/b").host, .bitbucket)
        XCTAssertEqual(try repo("https://git.cafe/a/b").host, .gitcafe)
        XCTAssertEqual(try repo("https://acme.ghe.com/a/b").host, .github)
    }

    func testUnknownHostStaysUnknown() throws {
        XCTAssertEqual(try repo("https://git.example.org/a/b").host, .unknown("git.example.org"))
        XCTAssertNil(try repo("https://git.example.org/a/b").pullRequestURL(number: 1))
        XCTAssertNil(try repo("https://git.example.org/a/b").newPullRequestURL(base: "main", head: "x"))
    }

    func testAzureDevOpsSpellingsFoldTogether() throws {
        for url in ["https://dev.azure.com/org/proj/_git/repo", "https://org@dev.azure.com/org/proj/_git/repo",
                    "git@ssh.dev.azure.com:v3/org/proj/repo", "https://org.visualstudio.com/proj/_git/repo",
                    "https://org.visualstudio.com/DefaultCollection/proj/_git/repo", "org@vs-ssh.visualstudio.com:v3/org/proj/repo"] {
            let r = try repo(url)
            XCTAssertEqual(r.host, .azureDevOps, url)
            XCTAssertEqual(r.path, "org/proj/_git/repo", url)
            XCTAssertEqual(r.hostName, "dev.azure.com", url)
            XCTAssertEqual(r.displayName, "org/proj/repo")
        }
        XCTAssertNil(SourceControlHost.detect(remoteURL: "https://dev.azure.com/org/proj"))
    }

    func testRejectsNonRemotes() {
        for url in ["", "   ", "/Users/me/repo", "C:\\work\\repo", "https://github.com/onlyowner", "https://github.com/a/b/c",
                    "file:///tmp/x", "https://github.com/a/../b", "ftp://github.com/a/b"] {
            XCTAssertNil(SourceControlHost.detect(remoteURL: url), url)
        }
    }

    func testHostCodableRoundTripAndKeys() throws {
        let hosts: [SourceControlHost] = [.github, .gitlab, .bitbucket, .gitea, .forgejo, .azureDevOps, .gitcafe, .unknown("x.org")]
        let data = try JSONEncoder().encode(hosts)
        XCTAssertEqual(try JSONDecoder().decode([SourceControlHost].self, from: data), hosts)
        XCTAssertEqual(SourceControlHost(key: "mystery"), .unknown("mystery"))
    }

    // MARK: URLs

    func testGitHubURLs() throws {
        let r = try repo("git@github.com:acme/app.git")
        XCTAssertEqual(r.compareURL(base: "main", head: "feature/x")?.absoluteString, "https://github.com/acme/app/compare/main...feature/x")
        XCTAssertEqual(r.newPullRequestURL(base: "main", head: "feature/x")?.absoluteString,
                       "https://github.com/acme/app/compare/main...feature/x?expand=1")
        XCTAssertEqual(r.pullRequestURL(number: 12)?.absoluteString, "https://github.com/acme/app/pull/12")
        XCTAssertEqual(r.branchURL("feature/x")?.absoluteString, "https://github.com/acme/app/tree/feature/x")
        XCTAssertNil(r.pullRequestURL(number: 0))
    }

    func testPrefilledTitleAndBodyAreEscaped() throws {
        let r = try repo("https://github.com/acme/app")
        let url = r.newPullRequestURL(base: "main", head: "x", title: "Fix #12 & more: één", body: "line1\nline2 100%")?.absoluteString
        XCTAssertEqual(url, "https://github.com/acme/app/compare/main...x?expand=1&title=Fix%20%2312%20%26%20more%3A%20%C3%A9%C3%A9n&body=line1%0Aline2%20100%25")
    }

    func testBranchWithHashAndSpaceStaysInThePath() throws {
        let r = try repo("https://github.com/acme/app")
        XCTAssertEqual(r.compareURL(base: "main", head: "fix#1 a")?.absoluteString, "https://github.com/acme/app/compare/main...fix%231%20a")
    }

    func testGitLabURLs() throws {
        let r = try repo("https://gitlab.com/g/sub/p.git")
        XCTAssertEqual(r.compareURL(base: "main", head: "x")?.absoluteString, "https://gitlab.com/g/sub/p/-/compare/main...x")
        XCTAssertEqual(r.newPullRequestURL(base: "main", head: "feat/x", title: "T t", body: "B")?.absoluteString,
                       "https://gitlab.com/g/sub/p/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat%2Fx&merge_request%5Btarget_branch%5D=main&merge_request%5Btitle%5D=T%20t&merge_request%5Bdescription%5D=B")
        XCTAssertTrue(r.newPullRequestURL(base: "main", head: "x", title: "T", draft: true)!.absoluteString.contains("Draft%3A%20T"))
        XCTAssertEqual(r.pullRequestURL(number: 3)?.absoluteString, "https://gitlab.com/g/sub/p/-/merge_requests/3")
        XCTAssertEqual(r.branchURL("x")?.absoluteString, "https://gitlab.com/g/sub/p/-/tree/x")
    }

    func testBitbucketURLs() throws {
        let r = try repo("git@bitbucket.org:ws/repo.git")
        XCTAssertEqual(r.newPullRequestURL(base: "main", head: "feat/x")?.absoluteString,
                       "https://bitbucket.org/ws/repo/pull-requests/new?source=feat%2Fx&dest=main")
        XCTAssertEqual(r.compareURL(base: "main", head: "x")?.absoluteString, "https://bitbucket.org/ws/repo/branches/compare/x%0Dmain")
        XCTAssertEqual(r.pullRequestURL(number: 4)?.absoluteString, "https://bitbucket.org/ws/repo/pull-requests/4")
        XCTAssertEqual(r.branchURL("a/b")?.absoluteString, "https://bitbucket.org/ws/repo/src/a/b")
    }

    func testGiteaForgejoGitcafeURLs() throws {
        for (url, base) in [("https://gitea.example.com/o/r", "https://gitea.example.com/o/r"),
                            ("https://codeberg.org/o/r", "https://codeberg.org/o/r"), ("https://git.cafe/o/r", "https://git.cafe/o/r")] {
            let r = try repo(url)
            XCTAssertEqual(r.compareURL(base: "main", head: "x")?.absoluteString, base + "/compare/main...x")
            XCTAssertEqual(r.newPullRequestURL(base: "main", head: "x", title: "A B", body: "c")?.absoluteString,
                           base + "/compare/main...x?title=A%20B&body=c")
            XCTAssertEqual(r.newPullRequestURL(base: "main", head: "x", title: "A", draft: true)?.absoluteString,
                           base + "/compare/main...x?title=WIP%3A%20A")
            XCTAssertEqual(r.pullRequestURL(number: 9)?.absoluteString, base + "/pulls/9")
            XCTAssertEqual(r.branchURL("x")?.absoluteString, base + "/src/branch/x")
        }
    }

    func testAzureURLs() throws {
        let r = try repo("git@ssh.dev.azure.com:v3/org/my%20proj/repo")
        XCTAssertEqual(r.newPullRequestURL(base: "main", head: "feat/x")?.absoluteString,
                       "https://dev.azure.com/org/my%2520proj/_git/repo/pullrequestcreate?sourceRef=feat%2Fx&targetRef=main")
        XCTAssertEqual(r.pullRequestURL(number: 5)?.absoluteString, "https://dev.azure.com/org/my%2520proj/_git/repo/pullrequest/5")
        let plain = try repo("https://dev.azure.com/org/proj/_git/repo")
        XCTAssertEqual(plain.compareURL(base: "main", head: "x")?.absoluteString,
                       "https://dev.azure.com/org/proj/_git/repo/branchCompare?baseVersion=GBmain&targetVersion=GBx")
        XCTAssertEqual(plain.branchURL("x")?.absoluteString, "https://dev.azure.com/org/proj/_git/repo?version=GBx")
    }
}
