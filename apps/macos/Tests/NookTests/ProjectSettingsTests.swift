import XCTest

final class ProjectSettingsTests: XCTestCase {
    private let global = SessionDefaults(provider: .claude, models: ["claude": "opus", "codex": "gpt-5"],
                                         permission: .acceptEdits, isolation: .worktree, branchPrefix: "nook")

    func testWithoutOverridesEverythingIsGlobal() {
        let overrides = ProjectOverrides()
        XCTAssertEqual(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo"), global)
        XCTAssertEqual(ProjectSettings.resolve(global: global, overrides: overrides, folder: nil), global)
    }

    func testAProjectOverridesOnlyWhatItSets() {
        var overrides = ProjectOverrides()
        overrides.set(.provider, .string("codex"), for: "/repo")
        overrides.set(.model(.codex), .string("gpt-5-codex"), for: "/repo")
        overrides.set(.isolation, .string("folder"), for: "/repo")
        overrides.set(.branchPrefix, .string(" Team/Me "), for: "/repo")
        let resolved = ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo")
        XCTAssertEqual(resolved.provider, .codex)
        XCTAssertEqual(resolved.model(for: .codex), "gpt-5-codex")
        XCTAssertEqual(resolved.model(for: .claude), "opus", "inherited")
        XCTAssertEqual(resolved.permission, .acceptEdits, "inherited")
        XCTAssertEqual(resolved.isolation, .folder)
        XCTAssertEqual(resolved.branchPrefix, "team/me", "normalized like the global prefix")
        // Another folder is not touched.
        XCTAssertEqual(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/other"), global)
    }

    func testSubfoldersAndTrailingSlashesBelongToTheProject() {
        var overrides = ProjectOverrides()
        overrides.set(.permission, .string("bypass"), for: "/work/app/")
        overrides.set(.permission, .string("ask"), for: "/work/app/packages/web")
        XCTAssertEqual(overrides.project(containing: "/work/app"), "/work/app")
        XCTAssertEqual(overrides.project(containing: "/work/app/src"), "/work/app")
        XCTAssertEqual(overrides.project(containing: "/work/app/packages/web/src"), "/work/app/packages/web", "closest wins")
        XCTAssertNil(overrides.project(containing: "/work/application"), "a sibling with the same prefix is another folder")
        XCTAssertEqual(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/work/app/src").permission, .bypass)
    }

    func testInvalidStoredValuesFallBackToGlobal() {
        var overrides = ProjectOverrides()
        overrides.set(.provider, .string("nonsense"), for: "/repo")
        overrides.set(.permission, .int(3), for: "/repo")
        let resolved = ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo")
        XCTAssertEqual(resolved.provider, .claude)
        XCTAssertEqual(resolved.permission, .acceptEdits)
    }

    func testResetMakesARowInheritedAgain() {
        var overrides = ProjectOverrides()
        overrides.set(.permission, .string("bypass"), for: "/repo")
        overrides.set(.isolation, .string("folder"), for: "/repo")
        let scope = ProjectScope.project(path: "/repo")
        XCTAssertEqual(ProjectSettings.provenance(.permission, global: global, overrides: overrides, scope: scope), .overridden)
        XCTAssertEqual(ProjectSettings.provenance(.provider, global: global, overrides: overrides, scope: scope),
                       .inherited(from: .environment))
        overrides.reset(.permission, for: "/repo")
        XCTAssertFalse(overrides.isOverridden(.permission, for: "/repo"))
        XCTAssertEqual(ProjectSettings.provenance(.permission, global: global, overrides: overrides, scope: scope),
                       .inherited(from: .environment))
        overrides.reset(.isolation, for: "/repo")
        XCTAssertEqual(overrides.projects, [], "a folder with nothing left is forgotten")
        // The global scope always edits its own values.
        XCTAssertEqual(ProjectSettings.provenance(.permission, global: global, overrides: overrides, scope: .allProjects), .overridden)
    }

    func testCodableRoundTripAndTolerantDecode() throws {
        var overrides = ProjectOverrides()
        overrides.set(.model(.claude), .string("sonnet"), for: "/repo")
        let data = try JSONEncoder().encode(overrides)
        XCTAssertEqual(try JSONDecoder().decode(ProjectOverrides.self, from: data), overrides)
        XCTAssertEqual(try JSONDecoder().decode(ProjectOverrides.self, from: Data("{}".utf8)), ProjectOverrides())
    }

    func testScopeChoicesKeepFoldersWithOverrides() {
        var overrides = ProjectOverrides()
        overrides.set(.isolation, .string("folder"), for: "/old")
        let choices = ProjectSettings.scopeChoices(recent: ["/a", "/b/", "/a", "/c"], overrides: overrides, limit: 2)
        XCTAssertEqual(choices, ["/a", "/b", "/old"])
    }

    func testPermissionFallsBackToOneTheAgentSupports() {
        XCTAssertEqual(global.permission(for: .claude), .acceptEdits)
        var bypass = global
        bypass.permission = .bypass
        XCTAssertEqual(bypass.permission(for: .codex), .bypass)
    }

    func testBranchNameMovesToTheProjectPrefix() {
        XCTAssertEqual(ProjectSettings.branchName("nook/fix-login-3fa2", globalPrefix: "nook", projectPrefix: "Team/Me"),
                       "team/me/fix-login-3fa2")
        XCTAssertEqual(ProjectSettings.branchName("nook/fix", globalPrefix: "nook", projectPrefix: "nook"), "nook/fix")
        XCTAssertEqual(ProjectSettings.branchName("feature/x", globalPrefix: "nook", projectPrefix: "team"), "feature/x")
    }
}
