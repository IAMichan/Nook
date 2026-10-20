import XCTest

/// Updating Nook from main: reading where the build came from, the merged pull requests, whether the checkout can take
/// the update, and xcodebuild's output.
final class AppUpdateTests: XCTestCase {
    private let commit = String(repeating: "ab12", count: 10)

    func testBuildSourceNeedsACommitAndAFolder() {
        let source = BuildSource(info: ["NookSourceCommit": commit.uppercased(), "NookSourceRoot": "/Users/me/nook/apps/macos",
                                        "NookSourceBranch": "main", "NookBuildConfiguration": "Release",
                                        "NookDeveloperDir": "/Applications/Xcode.app/Contents/Developer"])
        XCTAssertEqual(source?.commit, commit, "lowercased")
        XCTAssertEqual(source?.shortCommit, "ab12ab1")
        XCTAssertEqual(source?.branch, "main")
        XCTAssertEqual(source?.configuration, "Release")
        XCTAssertEqual(source?.developerDirectory, "/Applications/Xcode.app/Contents/Developer")

        XCTAssertNil(BuildSource(info: ["NookSourceRoot": "/Users/me/nook/apps/macos"]), "not built from a checkout")
        XCTAssertNil(BuildSource(info: ["NookSourceCommit": "abc", "NookSourceRoot": "/x"]), "not a full commit")
        XCTAssertNil(BuildSource(info: ["NookSourceCommit": commit, "NookSourceRoot": "$(SRCROOT)"]), "unexpanded setting")

        let plain = BuildSource(info: ["NookSourceCommit": commit, "NookSourceRoot": "/x", "NookSourceBranch": "",
                                       "NookDeveloperDir": "$(DEVELOPER_DIR)"])
        XCTAssertNil(plain?.branch, "detached")
        XCTAssertNil(plain?.developerDirectory)
        XCTAssertEqual(plain?.configuration, "Debug")
    }

    func testMergedPullRequestsAndPlainCommits() {
        let merge = UpdateLog.describe(subject: "Merge pull request #313 from IAMichan/perf/instant-autocomplete",
                                       body: "\nMake autocomplete instant\n\nLonger text")
        XCTAssertEqual(merge.title, "Make autocomplete instant")
        XCTAssertEqual(merge.pullRequest, 313)

        let bare = UpdateLog.describe(subject: "Merge pull request #7 from someone/fix-the_footer", body: "")
        XCTAssertEqual(bare.title, "fix the footer", "the branch name when the merge has no body")
        XCTAssertEqual(bare.pullRequest, 7)

        let squash = UpdateLog.describe(subject: "Add an update button (#42)", body: "")
        XCTAssertEqual(squash.title, "Add an update button")
        XCTAssertEqual(squash.pullRequest, 42)

        let direct = UpdateLog.describe(subject: "Fix typo", body: "")
        XCTAssertEqual(direct.title, "Fix typo")
        XCTAssertNil(direct.pullRequest)
    }

    func testParsesGitLog() {
        let other = String(repeating: "cd34", count: 10)
        let output = "\(commit)\u{1f}Michan\u{1f}1760000000\u{1f}Merge pull request #2 from a/b\u{1f}Title one\nmore\u{1e}\n"
            + "\(other)\u{1f}Bot\u{1f}1760000100\u{1f}Direct\u{1f}\u{1e}\n"
            + "garbage\u{1e}"
        let changes = UpdateLog.parse(output)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].title, "Title one")
        XCTAssertEqual(changes[0].pullRequest, 2)
        XCTAssertEqual(changes[0].author, "Michan")
        XCTAssertEqual(changes[0].date, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(changes[1].sha, other)
        XCTAssertEqual(changes[1].shortSHA, "cd34cd3")
        XCTAssertNil(changes[1].pullRequest)
    }

    func testGitHubRemotes() {
        for remote in ["https://github.com/IAMichan/nook.git", "https://github.com/IAMichan/nook", "git@github.com:IAMichan/nook.git",
                       "ssh://git@github.com/IAMichan/nook.git", "https://token@github.com/IAMichan/nook/"] {
            let repository = GitHubRepository(remoteURL: remote)
            XCTAssertEqual(repository?.owner, "IAMichan", remote)
            XCTAssertEqual(repository?.name, "nook", remote)
        }
        XCTAssertNil(GitHubRepository(remoteURL: "https://gitlab.com/IAMichan/nook.git"))
        XCTAssertNil(GitHubRepository(remoteURL: "https://github.company.com/IAMichan/nook.git"))
        XCTAssertNil(GitHubRepository(remoteURL: "/Users/me/nook"))
        let repository = GitHubRepository(remoteURL: "git@github.com:IAMichan/nook.git")
        XCTAssertEqual(repository?.compare("abc", "def")?.absoluteString, "https://github.com/IAMichan/nook/compare/abc...def")
        XCTAssertEqual(repository?.pullRequest(5)?.absoluteString, "https://github.com/IAMichan/nook/pull/5")
    }

    private func checkout(branch: String? = "main", files: Int = 0, local: Int = 0, atTarget: Bool = false) -> UpdateCheckout {
        UpdateCheckout(branch: branch, updateBranch: "main", changedFiles: Array(repeating: " M file.swift", count: files),
                       localCommits: local, atTarget: atTarget)
    }

    func testPreflight() {
        XCTAssertEqual(UpdatePreflight.check(checkout()), .ready)
        XCTAssertEqual(UpdatePreflight.check(checkout(files: 3)), .needsStash(files: 3))
        XCTAssertEqual(UpdatePreflight.check(checkout(files: 3, atTarget: true)), .ready, "nothing to merge: only a build")
        XCTAssertEqual(UpdatePreflight.check(checkout(branch: "feature")), .blocked(.otherBranch("feature")))
        XCTAssertEqual(UpdatePreflight.check(checkout(branch: nil)), .blocked(.detached))
        XCTAssertEqual(UpdatePreflight.check(checkout(local: 2)), .blocked(.diverged(2)))
        XCTAssertEqual(UpdatePreflight.check(checkout(files: 1, local: 2)), .blocked(.diverged(2)), "blocked before stash")
    }

    func testBuildActivity() {
        XCTAssertEqual(BuildActivity.parse("SwiftCompile normal arm64 /Users/me/nook/apps/macos/App/AppModel.swift (in target 'Nook' from project 'Nook')"),
                       .compiling("AppModel.swift"))
        XCTAssertEqual(BuildActivity.parse("CompileC /tmp/x.o /Users/me/pkg/llama.c normal arm64 c"), .compiling("llama.c"))
        XCTAssertEqual(BuildActivity.parse("Resolve Package Graph"), .resolvingPackages)
        XCTAssertEqual(BuildActivity.parse("Ld /Users/me/DerivedData/Nook.app/Contents/MacOS/Nook normal"), .linking)
        XCTAssertEqual(BuildActivity.parse("CodeSign /Users/me/DerivedData/Nook.app"), .signing)
        XCTAssertNil(BuildActivity.parse("    cd /Users/me/nook/apps/macos"))
    }

    func testBuildErrors() {
        let log = """
        /Users/me/nook/apps/macos/App/AppModel.swift:12:5: error: cannot find 'foo' in scope
        /Users/me/nook/apps/macos/App/AppModel.swift:12:5: error: cannot find 'foo' in scope
        /Users/me/nook/apps/macos/App/Other.swift:3:1: warning: unused
        xcodebuild: error: Unable to find a destination matching the provided destination specifier
        ** BUILD FAILED **
        """
        XCTAssertEqual(BuildActivity.errors(in: log), [
            "AppModel.swift:12: cannot find 'foo' in scope",
            "Unable to find a destination matching the provided destination specifier"
        ])
    }

    func testBuildProduct() throws {
        let json = """
        [{"action":"build","target":"NookTests","buildSettings":{"TARGET_BUILD_DIR":"/D/Debug","FULL_PRODUCT_NAME":"NookTests.xctest"}},
         {"action":"build","target":"Nook","buildSettings":{"TARGET_BUILD_DIR":"/D/Build/Products/Debug","FULL_PRODUCT_NAME":"Nook.app"}}]
        """
        XCTAssertEqual(BuildProduct.path(fromBuildSettings: Data(json.utf8)), "/D/Build/Products/Debug/Nook.app")
        XCTAssertNil(BuildProduct.path(fromBuildSettings: Data("not json".utf8)))
    }

    func testRelaunchKeepsPathOutOfTheScript() {
        let arguments = Relaunch.arguments(pid: 4242, appPath: "/Applications/My \"Nook\".app")
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertEqual(arguments[1], Relaunch.script)
        XCTAssertFalse(Relaunch.script.contains("4242"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["4242", "/Applications/My \"Nook\".app"])
    }

    func testEnvironmentDropsDebuggerInjections() {
        let env = UpdateEnvironment.make(base: ["PATH": "/usr/bin:/bin", "DYLD_INSERT_LIBRARIES": "x", "__XPC_DYLD_LIBRARY_PATH": "y",
                                                "OS_ACTIVITY_DT_MODE": "1", "HOME": "/Users/me"],
                                         developerDirectory: "/Applications/Xcode.app/Contents/Developer", home: "/Users/me")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["__XPC_DYLD_LIBRARY_PATH"])
        XCTAssertNil(env["OS_ACTIVITY_DT_MODE"])
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertTrue(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
        XCTAssertTrue(env["PATH"]?.hasSuffix(":/usr/bin:/bin") ?? false)
    }

    func testLaunchedByXcode() {
        XCTAssertTrue(BuildSource.launchedByXcode(["__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x/Build/Products/Debug",
                                                   "HOME": "/Users/me"]))
        XCTAssertFalse(BuildSource.launchedByXcode(["HOME": "/Users/me", "XCODE_VERSION": "16"]), "opened from Finder")
    }

    func testProjectPathAndAppleScriptQuoting() {
        let source = BuildSource(info: ["NookSourceCommit": commit, "NookSourceRoot": "/Users/me/nook/apps/macos"])
        XCTAssertEqual(source?.projectPath, "/Users/me/nook/apps/macos/Nook.xcodeproj")
        XCTAssertEqual(AppUpdater.appleScriptString(#"/Users/me/my "nook"\x"#), #""/Users/me/my \"nook\"\\x""#)
    }
}
