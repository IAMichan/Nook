import XCTest

final class WorkspaceModelsTests: XCTestCase {
    // MARK: States

    func testStatusTransitions() {
        XCTAssertTrue(RunStatus.preparing.canMove(to: .running))
        XCTAssertTrue(RunStatus.running.canMove(to: .waitingApproval))
        XCTAssertTrue(RunStatus.waitingApproval.canMove(to: .running))
        XCTAssertTrue(RunStatus.running.canMove(to: .completed))
        XCTAssertTrue(RunStatus.completed.canMove(to: .preparing), "continuing after a completed turn")
        XCTAssertTrue(RunStatus.failed.canMove(to: .preparing), "retrying after an error")
        XCTAssertFalse(RunStatus.completed.canMove(to: .waitingApproval), "without an active process nothing can wait")
        XCTAssertFalse(RunStatus.preparing.canMove(to: .completed))
        XCTAssertFalse(RunStatus.stopped.canMove(to: .failed))
    }

    func testActiveRunsBecomeStoppedAfterRelaunch() {
        XCTAssertEqual(RunStatus.running.afterRelaunch, .stopped)
        XCTAssertEqual(RunStatus.waitingApproval.afterRelaunch, .stopped)
        XCTAssertEqual(RunStatus.preparing.afterRelaunch, .stopped)
        XCTAssertEqual(RunStatus.completed.afterRelaunch, .completed)
        XCTAssertEqual(RunStatus.failed.afterRelaunch, .failed)
    }

    func testMoveRejectsInvalidTransitionAndTracksTurnStart() {
        var run = TestData.run(status: .preparing)
        XCTAssertFalse(run.move(to: .completed))
        XCTAssertEqual(run.status, .preparing)
        XCTAssertTrue(run.move(to: .running))
        XCTAssertNotNil(run.turnStartedAt)
        XCTAssertTrue(run.move(to: .failed, detail: "boom"))
        XCTAssertNil(run.turnStartedAt)
        XCTAssertEqual(run.statusDetail, "boom")
        XCTAssertTrue(run.canContinue)
    }

    // MARK: Input Validation

    func testConfigValidation() {
        var config = NewRunConfig()
        XCTAssertEqual(config.problem, .missingTask)
        config.task = "Fix de login"
        XCTAssertEqual(config.problem, .missingWorkspace)
        config.projectPath = "/tmp/project"
        XCTAssertNil(config.problem)

        config.provider = .gemini
        config.permission = .ask
        XCTAssertEqual(config.problem, .unsupportedPolicy, "headless Gemini CLI cannot ask for confirmation")
        config.provider = .codex
        XCTAssertNil(config.problem, "Codex over app-server asks for approval in Nook")
        config.permission = .acceptEdits

        config.isolation = .worktree
        XCTAssertEqual(config.problem, .missingBaseBranch)
        config.baseBranch = "main"
        config.branchName = "bad name"
        XCTAssertEqual(config.problem, .invalidBranchName)
        config.branchName = "nook/fix-login-1a2b"
        XCTAssertNil(config.problem)
    }

    // MARK: Naming

    func testSlugAndTitle() {
        XCTAssertEqual(WorktreeNaming.slug("Fix de login-bug in Safari!"), "fix-de-login-bug-in-safari")
        XCTAssertEqual(WorktreeNaming.slug("Één café"), "een-cafe")
        XCTAssertEqual(WorktreeNaming.slug("!!!"), "sessie")
        XCTAssertLessThanOrEqual(WorktreeNaming.slug(String(repeating: "abc ", count: 40), limit: 20).count, 20)
        XCTAssertEqual(WorktreeNaming.title(from: "Korte taak\nmet details"), "Korte taak")
        XCTAssertEqual(WorktreeNaming.title(from: "   "), "Nieuwe sessie")
        XCTAssertTrue(WorktreeNaming.title(from: String(repeating: "woord ", count: 30)).hasSuffix("…"))
    }

    /// A question with a question mark or other punctuation still gives a branch name Git accepts.
    func testBranchNameFromPunctuatedTask() {
        for task in ["Is de ci gefaald?", "Fix: login [urgent] *nu*", "~weg^ @{x} \\"] {
            let name = WorktreeNaming.branchName(task: task, id: UUID())
            XCTAssertTrue(WorktreeNaming.isPlausibleBranchName(name), name)
        }
        var config = NewRunConfig()
        config.task = "Is de ci gefaald?"
        config.projectPath = "/tmp/project"
        config.isolation = .worktree
        config.baseBranch = "main"
        config.branchName = WorktreeNaming.branchName(task: config.task, id: UUID())
        XCTAssertNil(config.problem)
    }

    func testBranchNameIsUniqueAndValid() {
        let id = UUID(uuidString: "3FA2C1D0-0000-0000-0000-000000000000")!
        let name = WorktreeNaming.branchName(task: "Add archive button", id: id)
        XCTAssertEqual(name, "nook/add-archive-button-3fa2")
        XCTAssertTrue(WorktreeNaming.isPlausibleBranchName(name))
    }

    func testBranchNameRules() {
        for bad in ["", "-x", "a..b", "a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "x.lock", "x/", "/x", "@", "a@{b", "x."] {
            XCTAssertFalse(WorktreeNaming.isPlausibleBranchName(bad), bad)
        }
        for good in ["main", "feature/x", "nook/fix-1", "release-1.2"] {
            XCTAssertTrue(WorktreeNaming.isPlausibleBranchName(good), good)
        }
    }

    func testWorktreePathAvoidsExistingFolders() {
        var existing: Set<String> = []
        let first = WorktreeNaming.worktreePath(root: "/r", repoName: "My Repo", slug: "task", exists: { existing.contains($0) })
        XCTAssertEqual(first, "/r/my-repo/task")
        existing.insert(first)
        let second = WorktreeNaming.worktreePath(root: "/r", repoName: "My Repo", slug: "task", exists: { existing.contains($0) })
        XCTAssertEqual(second, "/r/my-repo/task-2")
    }

    // MARK: Paths

    func testPathPolicy() throws {
        let folder = try TestData.tempFolder()
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: folder), .ok)
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: "/"), .forbidden)
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: "/System/Library"), .forbidden)
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: "/usr/bin"), .forbidden)
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: NSHomeDirectory()), .forbidden, "never the entire home directory")
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: folder + "/bestaat-niet"), .missing)
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: ""), .missing)
        let file = folder + "/bestand.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspacePathPolicy.verdict(for: file), .notDirectory)
    }

    // MARK: Usage

    func testUsageKeepsUnknownFieldsNil() {
        var usage = RunUsage()
        XCTAssertNil(usage.totalTokens)
        usage.add(TurnUsage(inputTokens: 100, outputTokens: 20, durationSeconds: 3))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertNil(usage.cacheReadTokens, "unreported stays nil")
        XCTAssertNil(usage.reportedCostUSD, "never fabricate costs")
        usage.add(TurnUsage(inputTokens: 50, outputTokens: 5, cacheReadTokens: 1000, reportedCostUSD: 0.12,
                            contextTokens: 1200, contextWindow: 200_000, durationSeconds: 2))
        XCTAssertEqual(usage.inputTokens, 150)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.cacheReadTokens, 1000)
        XCTAssertEqual(usage.reportedCostUSD ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.activeSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(usage.contextFraction ?? 0, 0.006, accuracy: 0.0001)
        XCTAssertEqual(usage.totalTokens, 1175)
    }

    func testUnreviewedChanges() {
        var run = TestData.run(status: .completed)
        XCTAssertFalse(run.hasUnreviewedChanges)
        run.lastChangeAt = Date()
        XCTAssertTrue(run.hasUnreviewedChanges)
        run.reviewedAt = Date().addingTimeInterval(1)
        XCTAssertFalse(run.hasUnreviewedChanges)
        run.lastChangeAt = Date().addingTimeInterval(5)
        run.changedFiles = 0
        XCTAssertFalse(run.hasUnreviewedChanges, "no changed files remaining: nothing to review")
    }

    func testToolSummary() {
        XCTAssertEqual(ToolSummary.describe(tool: "Bash", input: ["command": "npm test\n--watch"]), "Bash · npm test --watch")
        XCTAssertEqual(ToolSummary.describe(tool: "Edit", input: ["file_path": "/a/b/Login.swift"]), "Edit · Login.swift")
        XCTAssertEqual(ToolSummary.command(["command": ["bash", "-lc", "ls -la"]]), "ls -la")
        XCTAssertEqual(ToolSummary.fileChanges(tool: "Write", input: ["file_path": "/x/y.txt"]).first?.kind, "written")
        XCTAssertTrue(ToolSummary.fileChanges(tool: "Read", input: ["file_path": "/x/y.txt"]).isEmpty)
    }
}

enum TestData {
    static func run(status: RunStatus, provider: RunProvider = .claude, model: String = "", project: String = "/tmp/p",
                    usage: RunUsage = RunUsage(), updated: Date = Date()) -> WorkspaceRun {
        WorkspaceRun(id: UUID(), title: "Taak", task: "Doe iets", provider: provider, profileID: provider.rawValue, model: model,
                     resolvedModel: nil, mode: .agent, permission: .acceptEdits, isolation: .folder, projectPath: project,
                     workingDirectory: project, repoRoot: nil, branch: nil, baseBranch: nil, worktreePath: nil, instructions: "",
                     status: status, statusDetail: nil, providerSessionID: nil, createdAt: updated, updatedAt: updated,
                     archived: false, usage: usage, turnStartedAt: nil, reviewedAt: nil, lastChangeAt: nil, changedFiles: nil)
    }

    static func tempFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return WorkspacePathPolicy.normalize(url.path)
    }
}
