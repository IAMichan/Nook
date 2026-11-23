import XCTest

final class PullRequestMentionsTests: XCTestCase {
    private func refs(_ command: String) -> [String] {
        PullRequestMentions.inCommand([command]).map { $0.ref.url?.absoluteString ?? $0.ref.reference }
    }

    private func folders(_ command: String) -> [String?] {
        PullRequestMentions.inCommand([command]).map(\.directory)
    }

    func testCommandNamesThePullRequestItWorksOn() {
        XCTAssertEqual(refs("gh pr checks 3877"), ["#3877"])
        XCTAssertEqual(refs("gh pr checks --watch 3878"), ["#3878"])
        XCTAssertEqual(refs("cd repo && gh pr checkout 12 && npm test"), ["#12"])
        XCTAssertEqual(folders("gh pr checks 3877"), [nil])
        XCTAssertEqual(refs("gh pr view 3877 --json statusCheckRollup; gh pr view 3878 --json statusCheckRollup"), ["#3877", "#3878"])
        XCTAssertEqual(refs("gh pr view 5 -R acme/app"), ["acme/app#5"])
        XCTAssertEqual(refs("gh pr diff --repo=acme/app 7"), ["acme/app#7"])
        XCTAssertEqual(refs("gh pr view https://github.com/acme/app/pull/9"), ["https://github.com/acme/app/pull/9"])
        XCTAssertEqual(refs("glab mr view 4"), ["#4"])
    }

    /// An agent in one project's worktree that checks a pull request of another project with `cd`: the number is that
    /// project's, not the session's (a session in a monorepo linked its own old "#34" next to the other project's #34).
    func testNumberAfterCdBelongsToThatFolder() {
        XCTAssertEqual(folders("cd /Users/me/Code/WhoBench && gh pr view 34 --json mergedAt"), ["/Users/me/Code/WhoBench"])
        XCTAssertEqual(refs("cd /Users/me/Code/WhoBench && gh pr view 34 --json mergedAt"), ["#34"])
        XCTAssertEqual(folders("cd \"/Users/me/My App\" && gh pr checks 5"), ["/Users/me/My App"])
        XCTAssertEqual(folders("cd ../app; ls; gh pr diff 7"), ["../app"])
        XCTAssertEqual(folders("pushd -P ~/app && gh pr view 8"), [("~/app" as NSString).expandingTildeInPath])
        // The last move before the command counts, and a command before any move stays in the session's folder.
        XCTAssertEqual(folders("gh pr view 1; cd /a && gh pr view 2; cd /b && gh pr view 3"), [nil, "/a", "/b"])
        // The same number in two folders is two pull requests.
        XCTAssertEqual(folders("cd /a && gh pr view 2; cd /b && gh pr view 2"), ["/a", "/b"])
        // A repository or link the command names itself needs no folder.
        XCTAssertEqual(folders("cd /a && gh pr view 5 -R acme/app"), [nil])
        XCTAssertEqual(folders("cd /a && gh pr view https://github.com/acme/app/pull/9"), [nil])
    }

    /// Codex, Gemini CLI and Antigravity can run a command in another folder without `cd`: that folder counts too.
    func testToolCallFolderCounts() {
        XCTAssertEqual(PullRequestMentions.folder(in: ["cmd": "gh pr view 34", "workdir": "/Users/me/WhoBench"]), "/Users/me/WhoBench")
        XCTAssertEqual(PullRequestMentions.folder(in: ["command": "gh pr view 34", "dir_path": "/a"]), "/a")
        XCTAssertEqual(PullRequestMentions.folder(in: ["CommandLine": "gh pr view 34", "Cwd": "/b"]), "/b")
        XCTAssertNil(PullRequestMentions.folder(in: ["command": "gh pr view 34"]))
        XCTAssertEqual(PullRequestMentions.inCommand(["gh pr view 34"], directory: "/w").map(\.directory), ["/w"])
        XCTAssertEqual(PullRequestMentions.inCommand(["cd sub && gh pr view 34"], directory: "/w").map(\.directory), ["/w/sub"])
        XCTAssertEqual(PullRequestMentions.inCommand(["gh pr view 5 -R acme/app"], directory: "/w").map(\.directory), [nil])
    }

    func testNumberAfterCdToAnUnknownFolderNamesNone() {
        XCTAssertEqual(refs("cd - && gh pr view 34"), [])
        XCTAssertEqual(refs("cd \"$REPO\" && gh pr view 34"), [])
        XCTAssertEqual(refs("cd $(git rev-parse --show-toplevel) && gh pr view 34"), [])
        XCTAssertEqual(refs("cd $REPO && gh pr view 5 -R acme/app"), ["acme/app#5"])
    }

    func testCommandWithoutOneNamesNone() {
        XCTAssertEqual(refs("gh pr list --state open"), [])
        XCTAssertEqual(refs("gh pr create --title Fix --body 12"), [])
        XCTAssertEqual(refs("gh pr view"), [])
        XCTAssertEqual(refs("gh pr comment --body 12"), [])
        XCTAssertEqual(refs("git log -n 12"), [])
        XCTAssertEqual(refs("gh run view 12345"), [])
    }

    func testMessageNamesHashesAndLinks() {
        let found = PullRequestMentions.inMessage("Fix the CI of #3878 and https://github.com/acme/app/pull/3877.")
            .map { $0.url?.absoluteString ?? $0.reference }
        XCTAssertEqual(found, ["https://github.com/acme/app/pull/3877", "#3878"])
        XCTAssertEqual(PullRequestMentions.inMessage("color #fff, a#12, # 3, see https://example.com/x").count, 0)
        XCTAssertEqual(PullRequestMentions.inMessage("#12 and #12 again").count, 1)
    }
}
