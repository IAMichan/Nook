import XCTest

/// Single git action button: chooses the action per branch state and runs the git workflow behind it.
final class GitQuickActionTests: XCTestCase {
    private func state(changes: Bool = false, branch: String? = "feat", isDefault: Bool = false, upstream: Bool = true,
                       remote: Bool = true, ahead: Int = 0, behind: Int = 0, aheadOfBase: Int = 0, pr: Bool = false) -> GitQuickState {
        GitQuickState(hasChanges: changes, branch: branch, isDefaultBranch: isDefault, hasUpstream: upstream, hasRemote: remote,
                      ahead: ahead, behind: behind, aheadOfBase: aheadOfBase, hasOpenPullRequest: pr)
    }

    private func action(_ state: GitQuickState) -> GitQuickAction? { try? GitQuickResolver.resolve(state).get() }
    private func reason(_ state: GitQuickState) -> String? {
        if case .failure(let reason) = GitQuickResolver.resolve(state) { return reason.key }
        return nil
    }

    func testChanges() {
        XCTAssertEqual(action(state(changes: true)), .commitPushPR)
        XCTAssertEqual(action(state(changes: true, pr: true)), .commitPush, "an open pull request only needs the push")
        XCTAssertEqual(action(state(changes: true, isDefault: true)), .commitPush)
        XCTAssertEqual(action(state(changes: true, upstream: false, remote: false)), .commit, "nowhere to push")
        XCTAssertEqual(reason(state(changes: true, branch: nil)), "ws.quick.detached")
    }

    func testCleanBranch() {
        XCTAssertEqual(action(state(ahead: 2)), .pushPR)
        XCTAssertEqual(action(state(ahead: 2, pr: true)), .push)
        XCTAssertEqual(action(state(upstream: false, aheadOfBase: 3)), .pushPR, "a branch that was never pushed")
        XCTAssertEqual(action(state(behind: 1)), .pull)
        XCTAssertEqual(reason(state(ahead: 1, behind: 1)), "ws.quick.diverged")
        XCTAssertEqual(action(state(aheadOfBase: 2)), .createPR, "pushed, but no pull request yet")
        XCTAssertEqual(reason(state(aheadOfBase: 2, pr: true)), "ws.quick.upToDate")
        XCTAssertEqual(reason(state(upstream: false)), "ws.quick.nothingToPush")
        XCTAssertEqual(reason(state(remote: false, ahead: 0)), "ws.quick.noRemote")
        XCTAssertTrue(GitQuickAction.commitPushPR.commits && GitQuickAction.commitPushPR.pushes && GitQuickAction.commitPushPR.proposes)
        XCTAssertFalse(GitQuickAction.pull.pushes)
    }

    func testCommitContextAndCommitAll() throws {
        guard let git = GitService.locate() else { throw XCTSkip("git not available") }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("nook-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["config", "user.name", "T"], in: repo.path)
        try git.run(["config", "user.email", "t@t"], in: repo.path)
        try "een\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], in: repo.path)
        try git.run(["commit", "-q", "-m", "start"], in: repo.path)
        try git.run(["checkout", "-q", "-b", "feat"], in: repo.path)

        try "twee\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nieuw\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let context = try git.commitContext(repo.path)
        XCTAssertTrue(context.files.contains("M\ta.txt") && context.files.contains("A\tb.txt"), "untracked files count too")
        XCTAssertTrue(context.patch.contains("+twee"))
        XCTAssertEqual(try git.run(["diff", "--cached", "--name-only"], in: repo.path), "", "your own staging stays as it was")

        let sha = try git.commitAll(repo.path, subject: "Update a and add b", body: "- a\n- b")
        XCTAssertFalse(sha.isEmpty)
        XCTAssertEqual(try git.run(["log", "-1", "--format=%s%n%b"], in: repo.path).trimmingCharacters(in: .whitespacesAndNewlines), "Update a and add b\n- a\n- b")
        XCTAssertEqual(git.commitsAhead(repo.path, of: "main"), 1)
        XCTAssertEqual(git.defaultBranch(repo.path, remote: "origin"), "main", "on a feature branch without origin/HEAD: main, never the branch itself")
        XCTAssertEqual(git.comparisonBase(repo.path, base: "main", remote: "origin"), "main", "no remote branch: the local one")
        let pr = try git.pullRequestContext(repo.path, base: "main")
        XCTAssertTrue(pr.commits.contains("Update a and add b"))
        XCTAssertTrue(pr.stat.contains("b.txt"))
    }

    func testPullRequestTemplate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-tpl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(GitService.pullRequestTemplate(root.path))
        try "## Wat\n".write(to: root.appendingPathComponent(".github/pull_request_template.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitService.pullRequestTemplate(root.path), "## Wat\n")
    }
}
