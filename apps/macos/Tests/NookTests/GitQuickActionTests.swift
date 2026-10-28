import XCTest

/// Single git action button: chooses the action per branch state and runs the git workflow behind it.
final class GitQuickActionTests: XCTestCase {
    private func state(changes: Bool = false, branch: String? = "feat", isDefault: Bool = false, upstream: Bool = true,
                       remote: Bool = true, ahead: Int = 0, behind: Int = 0, aheadOfBase: Int = 0, pr: Bool = false,
                       landed: Bool = false) -> GitQuickState {
        GitQuickState(hasChanges: changes, branch: branch, isDefaultBranch: isDefault, hasUpstream: upstream, hasRemote: remote,
                      ahead: ahead, behind: behind, aheadOfBase: aheadOfBase, hasOpenPullRequest: pr, pullRequestLanded: landed)
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

    func testAfterAMergedPullRequest() {
        XCTAssertEqual(action(state(changes: true, aheadOfBase: 3, landed: true)), .branchCommitPushPR, "new work gets its own branch")
        XCTAssertEqual(action(state(ahead: 1, aheadOfBase: 3, landed: true)), .branchPushPR, "a commit made after the merge too")
        XCTAssertEqual(reason(state(aheadOfBase: 3, landed: true)), "ws.quick.landed", "a squash-merged branch is never proposed again")
        XCTAssertEqual(action(state(changes: true, pr: true, landed: true)), .commitPush, "an open pull request wins over an old merged one")
        XCTAssertEqual(action(state(changes: true, upstream: false, remote: false, landed: true)), .commit)
        XCTAssertEqual(action(state(behind: 1, landed: true)), .pull)
        XCTAssertTrue(GitQuickAction.branchCommitPushPR.commits && GitQuickAction.branchCommitPushPR.proposes && GitQuickAction.branchCommitPushPR.startsBranch)
        XCTAssertFalse(GitQuickAction.branchPushPR.commits)
        XCTAssertEqual(GitQuickResolver.destinationKey(state(changes: true, landed: true), action: .branchCommitPushPR), "ws.quick.landedNewBranch")
    }

    func testNewBranchBesideAnOpenPullRequest() {
        XCTAssertEqual(GitQuickResolver.alternatives(state(changes: true, pr: true)), [.branchCommitPushPR])
        XCTAssertEqual(GitQuickResolver.alternatives(state(changes: true, isDefault: true)), [.branchCommitPushPR], "instead of pushing to main")
        XCTAssertEqual(GitQuickResolver.alternatives(state(changes: true)), [], "no pull request yet: the main action already opens one")
        XCTAssertEqual(GitQuickResolver.alternatives(state(changes: true, landed: true)), [], "already the main action")
        XCTAssertEqual(GitQuickResolver.alternatives(state(ahead: 1, pr: true)), [])
        XCTAssertEqual(GitQuickResolver.destinationKey(state(changes: true, pr: true), action: .commitPush), "ws.quick.addsToPR")
        XCTAssertNil(GitQuickResolver.destinationKey(state(changes: true), action: .commitPushPR))
    }

    /// A squash-merged branch: the new branch holds only the new commit, on top of the base.
    func testNewBranchAfterSquashMerge() throws {
        guard let git = GitService.locate() else { throw XCTSkip("git not available") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-branch-\(UUID().uuidString)")
        let origin = root.appendingPathComponent("origin.git").path, repo = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ text: String) throws {
            try text.write(toFile: (repo as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try git.run(["init", "-q", "--bare", "-b", "main", origin], in: root.path)
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try git.run(["config", "user.name", "T"], in: repo)
        try git.run(["config", "user.email", "t@t"], in: repo)
        try git.run(["remote", "add", "origin", origin], in: repo)
        try write("a.txt", "start\n")
        try git.run(["add", "-A"], in: repo)
        try git.run(["commit", "-q", "-m", "start"], in: repo)
        try git.run(["push", "-q", "origin", "main"], in: repo)
        try git.run(["switch", "-q", "-c", "feat"], in: repo)
        try write("a.txt", "start\nfeature\n")
        try git.run(["commit", "-qam", "feature"], in: repo)
        try git.push(repo, remote: "origin", branch: "feat")
        // The pull request is squash-merged on the remote: main gets the same change as one new commit.
        try git.run(["switch", "-q", "main"], in: repo)
        try git.run(["merge", "-q", "--squash", "feat"], in: repo)
        try git.run(["commit", "-qm", "feature (#1)"], in: repo)
        try git.run(["push", "-q", "origin", "main"], in: repo)
        try git.run(["switch", "-q", "feat"], in: repo)

        try write("b.txt", "more\n")
        let cut = try git.startBranch(repo, name: "nook/more-1234", remote: "origin")
        XCTAssertEqual(cut, "origin/feat")
        XCTAssertEqual(git.currentBranch(repo), "nook/more-1234")
        _ = try git.commitAll(repo, subject: "More", body: "")
        XCTAssertTrue(git.moveOntoBase(repo, base: "main", remote: "origin", cut: "origin/feat"))
        XCTAssertEqual(try git.run(["log", "--format=%s", "origin/main..HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines), "More")
        XCTAssertEqual(try String(contentsOfFile: (repo as NSString).appendingPathComponent("a.txt"), encoding: .utf8), "start\nfeature\n")
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
