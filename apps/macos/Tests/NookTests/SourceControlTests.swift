import XCTest

/// The pure rules of source control: auto-pull guards, clone layout and SSH fallback, publishing, commit references, and
/// the project settings that hold them.
final class SourceControlRuleTests: XCTestCase {
    private func facts(branch: String? = "main", dirty: Bool = false, busy: Bool = false, working: Bool = false,
                       ahead: Int = 0, behind: Int = 2) -> AutoPull.Facts {
        AutoPull.Facts(branch: branch, defaultBranch: "main", dirty: dirty, operationInProgress: busy,
                       sessionWorking: working, ahead: ahead, behind: behind)
    }

    func testAutoPullOnlyFastForwardsACleanDefaultBranch() {
        XCTAssertEqual(AutoPull.decide(facts()), .fastForward)
        XCTAssertEqual(AutoPull.decide(facts(behind: 0)), .upToDate)
        XCTAssertEqual(AutoPull.decide(facts(ahead: 3, behind: 0)), .upToDate)
        XCTAssertEqual(AutoPull.decide(facts(ahead: 1, behind: 1)), .skip(.diverged))
        XCTAssertEqual(AutoPull.decide(facts(dirty: true)), .skip(.dirty))
        XCTAssertEqual(AutoPull.decide(facts(busy: true)), .skip(.operationInProgress))
        XCTAssertEqual(AutoPull.decide(facts(working: true)), .skip(.sessionWorking))
        XCTAssertEqual(AutoPull.decide(facts(branch: "feature")), .skip(.notOnDefaultBranch))
        XCTAssertEqual(AutoPull.decide(facts(branch: nil)), .skip(.notOnDefaultBranch))
        var none = facts()
        none.defaultBranch = nil
        XCTAssertEqual(AutoPull.decide(none), .skip(.noDefaultBranch))
    }

    func testAutoPullCounts() {
        XCTAssertEqual(AutoPull.parseCounts("2\t5\n")?.ahead, 2)
        XCTAssertEqual(AutoPull.parseCounts("2\t5\n")?.behind, 5)
        XCTAssertNil(AutoPull.parseCounts("fatal"))
    }

    func testCloneAddressParsing() {
        XCTAssertEqual(CloneLayout.parse("git@github.com:IAMichan/nook.git"), .init(host: "github.com", owner: "IAMichan", name: "nook"))
        XCTAssertEqual(CloneLayout.parse("https://GitHub.com/IAMichan/nook"), .init(host: "github.com", owner: "IAMichan", name: "nook"))
        XCTAssertEqual(CloneLayout.parse("ssh://git@gitlab.com:2222/group/sub/app.git"),
                       .init(host: "gitlab.com", owner: "group/sub", name: "app"))
        XCTAssertNil(CloneLayout.parse("https://github.com/only"))
        XCTAssertNil(CloneLayout.parse("https://github.com/../etc"))
        XCTAssertNil(CloneLayout.parse("not a url"))
    }

    func testCloneTargetWithAndWithoutHostLayout() {
        XCTAssertEqual(CloneLayout.target(url: "git@github.com:me/app.git", parent: "/src", hostLayout: false, folderName: "app"),
                       "/src/app")
        XCTAssertEqual(CloneLayout.target(url: "git@github.com:me/app.git", parent: "/src", hostLayout: true, folderName: "app"),
                       "/src/github.com/me/app")
        XCTAssertNil(CloneLayout.target(url: "weird", parent: "/src", hostLayout: true, folderName: "weird"))
        XCTAssertEqual(CloneLayout.layoutRoot(of: "/Users/me/src/github.com/me/app"), "/Users/me/src")
        XCTAssertNil(CloneLayout.layoutRoot(of: "/Users/me/Developer/app"))
    }

    func testSSHFallsBackToHTTPSOnlyWhenSSHIsRefused() {
        XCTAssertTrue(CloneLayout.isSSH("git@github.com:me/app.git"))
        XCTAssertTrue(CloneLayout.isSSH("ssh://git@host/me/app"))
        XCTAssertFalse(CloneLayout.isSSH("https://github.com/me/app"))
        XCTAssertEqual(CloneLayout.httpsFallback("git@github.com:me/app.git"), "https://github.com/me/app.git")
        XCTAssertEqual(CloneLayout.httpsFallback("ssh://git@host.example:2222/me/app.git"), "https://host.example/me/app.git")
        XCTAssertNil(CloneLayout.httpsFallback("https://github.com/me/app"))
        XCTAssertTrue(CloneLayout.sshRefused("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."))
        XCTAssertTrue(CloneLayout.sshRefused("Host key verification failed."))
        XCTAssertTrue(CloneLayout.sshRefused("ssh: connect to host github.com port 22: Connection refused"))
        XCTAssertFalse(CloneLayout.sshRefused("fatal: destination path 'app' already exists"))
    }

    func testRepositoryPagesCloneTheirRepository() {
        let page = CloneLayout.repositoryURL(fromPage:)
        XCTAssertEqual(page(" https://github.com/owner/repo/tree/main "), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://github.com/owner/repo/blob/main/src/a.swift#L12"), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://github.com/owner/repo/pull/12/files"), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://github.com/owner/repo/issues"), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://github.com/owner/repo/"), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://github.com/owner/repo?tab=readme-ov-file"), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://bitbucket.org/team/app/src/main/README.md"), "https://bitbucket.org/team/app")
        XCTAssertEqual(page("https://gitlab.com/group/sub/app/-/tree/main?ref_type=heads"), "https://gitlab.com/group/sub/app")
        XCTAssertEqual(page("https://git.example.com/group/app/-/merge_requests/3"), "https://git.example.com/group/app")
        // Gitea and Forgejo on any host.
        XCTAssertEqual(page("https://gitea.example.com/me/app/src/branch/main"), "https://gitea.example.com/me/app")
        XCTAssertEqual(page("https://gitea.example.com/me/app/commits"), "https://gitea.example.com/me/app")
        XCTAssertEqual(page("https://user@gitea.example.com:3000/me/app/pulls/4"), "https://user@gitea.example.com:3000/me/app")
        // Already a clone URL, or not a page: as typed.
        XCTAssertEqual(page("https://github.com/owner/repo"), "https://github.com/owner/repo")
        XCTAssertEqual(page("https://github.com/owner/repo.git"), "https://github.com/owner/repo.git")
        XCTAssertEqual(page("https://git.example.com/group/sub/tree.git"), "https://git.example.com/group/sub/tree.git")
        XCTAssertEqual(page("https://git.example.com/group/sub/tree"), "https://git.example.com/group/sub/tree",
                       "a GitLab project named tree in a subgroup")
        XCTAssertEqual(page("git@github.com:owner/repo.git"), "git@github.com:owner/repo.git")
        XCTAssertEqual(page("ssh://git@host.example:2222/me/app.git"), "ssh://git@host.example:2222/me/app.git")
        XCTAssertEqual(page("https://github.com/owner"), "https://github.com/owner")
        XCTAssertEqual(GitService.cloneFolderName(page("https://github.com/owner/repo/tree/main")), "repo")
        XCTAssertTrue(GitService.isCloneURL(page("https://github.com/owner/repo/tree/main")))
    }

    func testCloneReusesAnEmptyFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("nook-clone-target-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let target = base.appendingPathComponent("app").path
        XCTAssertTrue(CloneLayout.prepareCloneTarget(target), "nothing there yet")
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: target + "/.DS_Store"))
        XCTAssertTrue(CloneLayout.prepareCloneTarget(target), "an empty folder left by a failed clone")
        XCTAssertFalse(fm.fileExists(atPath: target + "/.DS_Store"))
        try "x".write(toFile: target + "/notes.md", atomically: true, encoding: .utf8)
        XCTAssertFalse(CloneLayout.prepareCloneTarget(target))
        try "x".write(toFile: base.path + "/file", atomically: true, encoding: .utf8)
        XCTAssertFalse(CloneLayout.prepareCloneTarget(base.path + "/file"), "a file is never a clone folder")
    }

    func testRacyIndexRefreshWaitsOutTheCheckoutSecond() {
        let now = Date(timeIntervalSince1970: 1000.4)
        XCTAssertEqual(GitService.racyRefreshDelay(indexSecond: 1000, now: now) ?? -1, 0.65, accuracy: 0.001)
        XCTAssertEqual(GitService.racyRefreshDelay(indexSecond: 999, now: now), 0, "that second is already over")
        XCTAssertNil(GitService.racyRefreshDelay(indexSecond: 1002, now: now), "file stamps that do not follow this clock")
    }

    func testRepositoryNames() {
        XCTAssertTrue(RepositoryPublish.isValidName("my-app_2.0"))
        XCTAssertFalse(RepositoryPublish.isValidName("my app"))
        XCTAssertFalse(RepositoryPublish.isValidName(".."))
        XCTAssertFalse(RepositoryPublish.isValidName(""))
        XCTAssertEqual(RepositoryPublish.suggestedName("My App (2)"), "My-App-2")
        XCTAssertEqual(RepositoryPublish.suggestedName("—"), "project")
        XCTAssertEqual(RepositoryPublish.requestPath(owner: nil), "/user/repos")
        XCTAssertEqual(RepositoryPublish.requestPath(owner: "acme"), "/orgs/acme/repos")
        XCTAssertEqual(RepositoryPublish.requestBody(name: "a", isPrivate: true)["private"] as? Bool, true)
        XCTAssertTrue(RepositoryPublish.canPublish(isRepository: false, remotes: []))
        XCTAssertTrue(RepositoryPublish.canPublish(isRepository: true, remotes: []))
        XCTAssertFalse(RepositoryPublish.canPublish(isRepository: true, remotes: ["origin"]))
    }

    func testCommitReferences() throws {
        XCTAssertTrue(CommitReference.isHash("34bb86b4"))
        XCTAssertFalse(CommitReference.isHash("1234567"), "digits only is a number")
        XCTAssertFalse(CommitReference.isHash("deadbeef"), "letters only is a word")
        XCTAssertFalse(CommitReference.isHash("34bb86"), "too short")
        let link = try XCTUnwrap(CommitReference.link("34bb86b4"))
        XCTAssertEqual(CommitReference.hash(in: link), "34bb86b4")
        XCTAssertEqual(CommitReference.hash(in: URL(string: "https://github.com/o/r/commit/0356d555abc")!), "0356d555abc")
        XCTAssertEqual(CommitReference.hash(in: URL(string: "https://github.com/o/r/pull/3/commits/0356d555abc")!), "0356d555abc")
        XCTAssertNil(CommitReference.hash(in: URL(string: "https://github.com/o/r/pull/3")!))
        let text = "Committed 34bb86b4 and 0356d555, not src/a1b2c3d4 or 1234567."
        XCTAssertEqual(CommitReference.hashes(in: text).map { String(text[$0]) }, ["34bb86b4", "0356d555"])
    }

    func testProjectSettingsEncodeSourceControl() {
        var overrides = ProjectOverrides()
        let global = SessionDefaults(provider: .claude, models: [:], permission: .acceptEdits, isolation: .worktree, branchPrefix: "nook")
        XCTAssertEqual(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/p").submodules, .recursive)
        overrides.set(.submodules, .string("topLevel"), for: "/p")
        overrides.set(.autoPull, .string("on"), for: "/p")
        let resolved = ProjectSettings.resolve(global: global, overrides: overrides, folder: "/p/sub")
        XCTAssertEqual(resolved.submodules, .topLevel)
        XCTAssertTrue(resolved.autoPull)
        // Agents off: a list, emptied back to unset.
        let off = ProjectSettings.togglingAgent("codex", on: false, in: [])
        XCTAssertEqual(off, .list([.string("codex")]))
        overrides.set(.agentsOff, off!, for: "/p")
        XCTAssertEqual(ProjectSettings.agentsOff(overrides: overrides, folder: "/p/sub"), ["codex"])
        XCTAssertNil(ProjectSettings.togglingAgent("codex", on: true, in: ["codex"]))
        // Archive: the folder itself only.
        overrides.set(.archived, .string("on"), for: "/p")
        XCTAssertTrue(ProjectSettings.isArchived("/p/", overrides: overrides))
        XCTAssertFalse(ProjectSettings.isArchived("/p/sub", overrides: overrides))
        XCTAssertEqual(ProjectSettings.withoutArchived(["/p", "/q"], overrides: overrides), ["/q"])
        // Round trip through JSON, as UserDefaults keeps it.
        let data = try! JSONEncoder().encode(overrides)
        XCTAssertEqual(try! JSONDecoder().decode(ProjectOverrides.self, from: data), overrides)
    }

    func testProjectIcons() {
        XCTAssertEqual(ProjectIcon(stored: "emoji:🚀"), .emoji("🚀"))
        XCTAssertEqual(ProjectIcon(stored: "monogram:nk:violet"), .monogram("NK", .violet))
        XCTAssertEqual(ProjectIcon(stored: "monogram:AB:nope"), .monogram("AB", .mint))
        XCTAssertEqual(ProjectIcon(stored: "image:/tmp/a.png"), .image("/tmp/a.png"))
        XCTAssertNil(ProjectIcon(stored: "image:relative.png"))
        XCTAssertNil(ProjectIcon(stored: "emoji:a"))
        XCTAssertNil(ProjectIcon(stored: "garbage"))
        for icon in [ProjectIcon.emoji("🚀"), .monogram("NK", .blue), .image("/x.png")] {
            XCTAssertEqual(ProjectIcon(stored: icon.stored), icon)
        }
        XCTAssertEqual(ProjectIcon.initials("my-app"), "MA")
        XCTAssertEqual(ProjectIcon.initials("nook"), "NO")
    }

    func testCheckoutCacheDecisions() {
        XCTAssertNil(WorktreeCheckoutCache.fingerprint(config: "core.sparsecheckout true"))
        XCTAssertNil(WorktreeCheckoutCache.fingerprint(config: "extensions.objectformat sha256"))
        XCTAssertEqual(WorktreeCheckoutCache.fingerprint(config: "core.autocrlf false\ncore.filemode true"),
                       WorktreeCheckoutCache.fingerprint(config: "core.filemode true\ncore.autocrlf false"))
        XCTAssertNotEqual(WorktreeCheckoutCache.fingerprint(config: "core.autocrlf true"),
                          WorktreeCheckoutCache.fingerprint(config: "core.autocrlf false"))
        XCTAssertTrue(WorktreeCheckoutCache.namesFilter(attributes: "*.psd filter=lfs diff=lfs merge=lfs -text"))
        XCTAssertFalse(WorktreeCheckoutCache.namesFilter(attributes: "# filter=lfs\n*.swift diff=swift"))
        let name = String(repeating: "a", count: 40) + "-" + String(repeating: "b", count: 16)
        XCTAssertEqual(WorktreeCheckoutCache.parseEntryName(name)?.fingerprint, String(repeating: "b", count: 16))
        XCTAssertNil(WorktreeCheckoutCache.parseEntryName(".staging-x"))
        let changes = WorktreeCheckoutCache.parseChanges("M\0a.txt\0A\0sub/.gitattributes\0")
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.attributes)
        XCTAssertTrue(WorktreeCheckoutCache.dependenciesMatch(main: ["yarn.lock": Data([1])], worktree: ["yarn.lock": Data([1])]))
        XCTAssertFalse(WorktreeCheckoutCache.dependenciesMatch(main: [:], worktree: [:]))
    }
}

/// The same rules against real repositories in a temporary folder: auto-pull's guards, the commits the Changes tab
/// lists, the clone fallback's first attempt, and a fast worktree that must equal a plain one.
final class SourceControlGitTests: XCTestCase {
    private var root: URL!
    private var git: GitService!

    override func setUpWithError() throws {
        guard let service = GitService.locate() else { throw XCTSkip("git not available") }
        git = service
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-sc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func commit(_ dir: String, _ file: String, _ text: String, _ message: String) throws {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], in: dir)
        try git.run(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", message], in: dir)
    }

    /// An "upstream" repository and a clone of it, the clone one commit behind.
    private func upstreamAndClone() throws -> (upstream: String, clone: String) {
        let upstream = root.appendingPathComponent("up").path
        try FileManager.default.createDirectory(atPath: upstream, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: upstream)
        try commit(upstream, "a.txt", "one", "first")
        let clone = root.appendingPathComponent("clone").path
        try git.run(["clone", "-q", upstream, clone], in: root.path)
        try commit(upstream, "a.txt", "two", "second")
        return (upstream, clone)
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    func testAutoPullFastForwardsACleanCheckout() throws {
        let (_, clone) = try upstreamAndClone()
        XCTAssertEqual(try git.autoPull(clone, sessionWorking: false), .fastForward)
        XCTAssertEqual(read(clone + "/a.txt"), "two")
        XCTAssertEqual(try git.autoPull(clone, sessionWorking: false), .upToDate)
    }

    func testAutoPullLeavesADirtyTreeAlone() throws {
        let (_, clone) = try upstreamAndClone()
        try "mine".write(toFile: clone + "/a.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try git.autoPull(clone, sessionWorking: false), .skip(.dirty))
        XCTAssertEqual(read(clone + "/a.txt"), "mine")
    }

    func testAutoPullNeverMergesOrMovesAnotherBranch() throws {
        let (_, clone) = try upstreamAndClone()
        try commit(clone, "b.txt", "local", "local work")
        XCTAssertEqual(try git.autoPull(clone, sessionWorking: false), .skip(.diverged))
        try git.run(["checkout", "-q", "-b", "feature"], in: clone)
        XCTAssertEqual(try git.autoPull(clone, sessionWorking: false), .skip(.notOnDefaultBranch))
    }

    func testAutoPullWaitsForASessionInTheCheckout() throws {
        let (_, clone) = try upstreamAndClone()
        XCTAssertEqual(try git.autoPull(clone, sessionWorking: true), .skip(.sessionWorking))
        XCTAssertEqual(read(clone + "/a.txt"), "one")
    }

    func testCommitScopeListsNewestCommitsAndFindsOneByHash() throws {
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo)
        for index in 0..<5 { try commit(repo, "f.txt", "\(index)", "change \(index)") }
        let commits = git.commits(repo, count: 3)
        XCTAssertEqual(commits.map(\.subject), ["change 4", "change 3", "change 2"])
        let oldest = git.commits(repo, count: 10).last!
        XCTAssertEqual(oldest.subject, "change 0")
        XCTAssertNil(oldest.parent)
        let found = git.commit(repo, named: String(oldest.id.prefix(10)))
        XCTAssertEqual(found?.id, oldest.id)
        XCTAssertNil(git.commit(repo, named: "abc1234def"))
        XCTAssertNil(git.commit(repo, named: "--all"))
    }

    func testCloneWithHostLayoutAndHTTPSAddressDoesNotFallBack() throws {
        let (upstream, _) = try upstreamAndClone()
        // A local path is not a clone URL: refused before git runs.
        XCTAssertThrowsError(try git.clone(url: upstream, into: root.path, hostLayout: true))
    }

    func testPublishPreparesAFolderWithoutRepository() throws {
        let folder = root.appendingPathComponent("scratch").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "hi".write(toFile: folder + "/notes.md", atomically: true, encoding: .utf8)
        let env = ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
        for key in env { setenv(key, "T", 1) }
        defer { for key in env { unsetenv(key) } }
        let branch = try git.preparePublish(folder)
        XCTAssertFalse(branch.isEmpty)
        XCTAssertTrue(git.hasCommits(folder))
        XCTAssertEqual(git.commits(folder).first?.subject, "Initial commit")
        // A bare repository stands in for GitHub; no token, nothing stored.
        let bare = root.appendingPathComponent("remote.git").path
        try git.run(["init", "-q", "--bare", bare], in: root.path)
        try git.publish(folder, remoteURL: bare, branch: branch, token: nil)
        XCTAssertEqual(git.remotes(folder), ["origin"])
        XCTAssertThrowsError(try git.publish(folder, remoteURL: bare, branch: branch, token: nil), "a second remote is refused")
    }

    func testNewWorktreeIndexIsNotRacilyClean() throws {
        let repo = root.appendingPathComponent("racy").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try commit(repo, "a.txt", "one", "first")
        let worktree = root.appendingPathComponent("wt/racy").path
        try git.addWorktree(repo: repo, path: worktree, branch: "racy", base: "main", refreshBase: false)
        let index = try git.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func second(_ path: String) throws -> Int {
            Int((try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date).timeIntervalSince1970)
        }
        // Git re-hashes a file stamped in the index's own second or later; the refresh moves the index past it.
        XCTAssertGreaterThan(try second(index), try second(worktree + "/a.txt"))
        XCTAssertEqual(try git.run(["status", "--porcelain"], in: worktree), "")
    }

    func testFastWorktreeEqualsAPlainOne() throws {
        #if !canImport(Darwin)
        throw XCTSkip("APFS clones (clonefile) are the Mac's")
        #endif
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try commit(repo, "src/a.swift", "let a = 1\n", "first")
        try commit(repo, ".gitignore", "build/\n", "ignore")
        let cache = WorktreeCheckoutCache(git: git, root: root.appendingPathComponent("cache"), minimumFiles: 0)
        let first = root.appendingPathComponent("wt/one").path
        let cloned = try git.addWorktree(repo: repo, path: first, branch: "one", base: "main", refreshBase: false, checkoutCache: cache)
        XCTAssertFalse(cloned, "an empty cache: git checks out")
        cache.build(worktree: first, repo: repo)
        try commit(repo, "src/b.swift", "let b = 2\n", "second")
        let second = root.appendingPathComponent("wt/two").path
        let fast = try git.addWorktree(repo: repo, path: second, branch: "two", base: "main", refreshBase: false, checkoutCache: cache)
        XCTAssertTrue(fast, "the temporary folder is on APFS: the second worktree comes from the cache")
        XCTAssertEqual(read(second + "/src/b.swift"), "let b = 2\n")
        XCTAssertEqual(try git.run(["status", "--porcelain", "--untracked-files=all"], in: second), "")
        XCTAssertEqual(git.currentBranch(second), "two")
        XCTAssertTrue(try git.run(["worktree", "list", "--porcelain"], in: repo).contains("wt/two"))
    }
}

/// Fast worktrees against a real repository: `NOOK_BENCH_REPO=/path/to/clone scripts/core-tests.sh --filter
/// FastWorktreeBenchmark`. Skipped otherwise. Prints the time of a plain `git worktree add` and of a cached clone.
final class FastWorktreeBenchmark: XCTestCase {
    func testPlainVersusCachedWorktree() throws {
        guard let repo = ProcessInfo.processInfo.environment["NOOK_BENCH_REPO"], let git = GitService.locate() else {
            throw XCTSkip("set NOOK_BENCH_REPO to a clone to measure")
        }
        let base = URL(fileURLWithPath: repo).deletingLastPathComponent().appendingPathComponent("bench-\(UUID().uuidString.prefix(6))")
        let cache = WorktreeCheckoutCache(git: git, root: base.appendingPathComponent("cache"))
        defer {
            for name in ["plain", "warm", "fast", "fast2"] {
                _ = try? git.run(["worktree", "remove", "--force", base.appendingPathComponent(name).path], in: repo)
                _ = try? git.run(["branch", "-D", "bench-" + name], in: repo)
            }
            try? FileManager.default.removeItem(at: base)
        }
        func timed(_ name: String, _ work: () throws -> Bool) rethrows -> (Double, Bool) {
            let start = Date()
            let cloned = try work()
            return (Date().timeIntervalSince(start), cloned)
        }
        let head = try git.run(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = try timed("plain") {
            try git.addWorktree(repo: repo, path: base.appendingPathComponent("plain").path, branch: "bench-plain", base: head,
                                refreshBase: false)
        }
        let status = { (path: String) -> Double in
            let start = Date()
            _ = try? git.run(["status", "--porcelain"], in: path)
            return Date().timeIntervalSince(start)
        }
        let plainStatus = status(base.appendingPathComponent("plain").path)
        let startBuild = Date()
        cache.build(worktree: base.appendingPathComponent("plain").path, repo: repo)
        let buildTime = Date().timeIntervalSince(startBuild)
        let fast = try timed("fast") {
            try git.addWorktree(repo: repo, path: base.appendingPathComponent("fast").path, branch: "bench-fast", base: head,
                                refreshBase: false, checkoutCache: cache)
        }
        let fastStatus = status(base.appendingPathComponent("fast").path)
        let older = try git.run(["rev-parse", "HEAD~20"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = try timed("fast2") {
            try git.addWorktree(repo: repo, path: base.appendingPathComponent("fast2").path, branch: "bench-fast2", base: older,
                                refreshBase: false, checkoutCache: cache)
        }
        let files = try git.run(["ls-files"], in: repo).split(separator: "\n").count
        print(String(format: "BENCH files=%d plain=%.2fs (status %.2fs) cacheBuild=%.2fs fast=%.2fs cloned=%@ (status %.2fs) fast20back=%.2fs cloned=%@",
                     files, plain.0, plainStatus, buildTime, fast.0, String(fast.1), fastStatus, moved.0, String(moved.1)))
        if files >= WorktreeCheckoutCache.standardMinimumFiles { XCTAssertTrue(fast.1) } else { XCTAssertFalse(fast.1) }
    }
}
