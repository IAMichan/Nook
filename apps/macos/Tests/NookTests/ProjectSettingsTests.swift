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

    func testBrowserSignInsStayOffUntilAProjectAsks() {
        var overrides = ProjectOverrides()
        XCTAssertFalse(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo").browserSignIns)
        overrides.set(.browserSignIns, .string("on"), for: "/repo")
        XCTAssertTrue(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo").browserSignIns)
        XCTAssertFalse(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/other").browserSignIns)
    }

    func testAProjectCanSwitchWorktreeCleanupOff() {
        var overrides = ProjectOverrides()
        XCTAssertTrue(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo").worktreeCleanup, "inherited")
        overrides.set(.worktreeCleanup, .string("off"), for: "/repo")
        XCTAssertFalse(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/repo/app").worktreeCleanup)
        XCTAssertTrue(ProjectSettings.resolve(global: global, overrides: overrides, folder: "/other").worktreeCleanup)
    }

    func testTitleInstructionsComeFromTheProjectOrAllProjects() {
        var withRules = global
        withRules.titleInstructions = "English titles"
        var overrides = ProjectOverrides()
        XCTAssertEqual(ProjectSettings.resolve(global: withRules, overrides: overrides, folder: "/repo").titleInstructions,
                       "English titles", "inherited from all projects")
        overrides.set(.titleInstructions, .string("Start with the ticket number"), for: "/repo")
        XCTAssertEqual(ProjectSettings.resolve(global: withRules, overrides: overrides, folder: "/repo/sub").titleInstructions,
                       "Start with the ticket number")
        overrides.set(.titleInstructions, .string(""), for: "/repo")
        XCTAssertEqual(ProjectSettings.resolve(global: withRules, overrides: overrides, folder: "/repo").titleInstructions, "",
                       "a project can switch the global rules off with an empty text")
        XCTAssertEqual(global.titleInstructions, "", "none by default")
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
        let choices = ProjectSettings.scopeChoices(favorites: ["/fav/"], recent: ["/a", "/b/", "/fav", "/a", "/c"], overrides: overrides, limit: 3)
        XCTAssertEqual(choices, ["/fav", "/a", "/b", "/old"])
    }

    func testFavoriteFoldersToggleAndStayOnTopOfTheMenu() {
        var favorites: [String] = []
        favorites = ProjectSettings.togglingFavorite("/work/nook/", in: favorites)
        favorites = ProjectSettings.togglingFavorite("/work/infaris", in: favorites)
        XCTAssertEqual(favorites, ["/work/nook", "/work/infaris"])
        XCTAssertTrue(ProjectSettings.isFavorite("/work/nook", in: favorites))
        XCTAssertTrue(ProjectSettings.isFavorite("/work/nook/", in: favorites))
        XCTAssertFalse(ProjectSettings.isFavorite("/work/other", in: favorites))

        let existing: Set<String> = ["/work/nook", "/work/infaris", "/work/wt1", "/work/wt2", "/work/wt3", "/work/wt4"]
        let menu = ProjectSettings.projectMenu(
            favorites: favorites + ["/work/missing"],
            recent: ["/work/wt1", "/work/nook/", "/work/wt2", "/work/wt3", "/work/wt4", "/work/missing"],
            exists: { existing.contains($0) },
            normalize: ProjectOverrides.normalize,
            limit: 5
        )
        XCTAssertEqual(menu.favorites, ["/work/nook", "/work/infaris"], "existing favorites come first, in order")
        XCTAssertEqual(menu.recent, ["/work/wt1", "/work/wt2", "/work/wt3"], "favorites are not repeated under recent")

        // Unstarring removes the folder from favorites and keeps the rest in order.
        favorites = ProjectSettings.togglingFavorite("/work/nook", in: favorites)
        XCTAssertEqual(favorites, ["/work/infaris"])
        XCTAssertEqual(ProjectSettings.togglingFavorite("   ", in: favorites), ["/work/infaris"])
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

    // MARK: Choices per folder

    private func defaults(_ choices: FolderChoicesStore, folder: String?, overrides: ProjectOverrides = ProjectOverrides(),
                          efforts: [String: String] = [:]) -> ComposerDefaults {
        ProjectSettings.composerDefaults(global: global, mode: .agent, profiles: ["claude": "personal"], efforts: efforts,
                                         overrides: overrides, choices: choices.choices(for: folder), folder: folder)
    }

    private func config(_ provider: RunProvider = .codex, folder: String = "/repo") -> NewRunConfig {
        var config = NewRunConfig()
        config.provider = provider
        config.profileID = "work"
        config.model = "gpt-5-codex"
        config.mode = .plan
        config.permission = .bypass
        config.isolation = .folder
        config.projectPath = folder
        return config
    }

    func testAFolderStartsWithWhatWasLastChosenThere() {
        var store = FolderChoicesStore()
        store.remember(config(folder: "/repo/"))
        let resolved = defaults(store, folder: "/repo")
        XCTAssertEqual(resolved.provider, .codex)
        XCTAssertEqual(resolved.model(for: .codex), "gpt-5-codex")
        XCTAssertEqual(resolved.profile(for: .codex, connected: ["other", "work"]), "work")
        XCTAssertEqual(resolved.mode, .plan)
        XCTAssertEqual(resolved.permission(for: .codex), .bypass)
        XCTAssertEqual(resolved.isolation, .folder)
    }

    func testAnotherFolderKeepsTheGlobalChoices() {
        var store = FolderChoicesStore()
        store.remember(config())
        for folder in ["/other", "/repo/sub", nil] as [String?] {
            let resolved = defaults(store, folder: folder)
            XCTAssertEqual(resolved.provider, .claude)
            XCTAssertEqual(resolved.model(for: .claude), "opus")
            XCTAssertEqual(resolved.mode, .agent)
            XCTAssertEqual(resolved.isolation, .worktree)
            XCTAssertEqual(resolved.profile(for: .claude, connected: ["work", "personal"]), "personal")
        }
    }

    func testAFolderKeepsItsChoicesForEveryAgent() {
        var store = FolderChoicesStore()
        var claude = config(.claude)
        claude.model = "sonnet"
        claude.profileID = "client"
        store.remember(claude)
        store.remember(config(.codex))
        let resolved = defaults(store, folder: "/repo")
        XCTAssertEqual(resolved.provider, .codex, "the agent used last")
        XCTAssertEqual(resolved.model(for: .claude), "sonnet")
        XCTAssertEqual(resolved.profile(for: .claude, connected: ["personal", "client"]), "client")
    }

    func testAFolderCanKeepTheAgentsOwnEffort() {
        let level = EffortLevels.levels(for: .claude, model: nil).first ?? ""
        var store = FolderChoicesStore()
        var withoutEffort = config(.claude)
        withoutEffort.effort = nil
        store.remember(withoutEffort)
        XCTAssertNil(defaults(store, folder: "/repo", efforts: ["claude": level]).effort(for: .claude),
                     "the folder's own default, not the level chosen elsewhere")
        XCTAssertEqual(defaults(store, folder: "/other", efforts: ["claude": level]).effort(for: .claude), level)
    }

    func testAnAccountThatIsGoneFallsBack() {
        var store = FolderChoicesStore()
        store.remember(config(.claude))
        let resolved = defaults(store, folder: "/repo")
        XCTAssertEqual(resolved.profile(for: .claude, connected: ["first", "personal"]), "personal", "the global account")
        XCTAssertEqual(resolved.profile(for: .claude, connected: ["first"]), "first")
        XCTAssertNil(resolved.profile(for: .claude, connected: []))
    }

    func testWhatAFolderSetsInSettingsWinsOverItsLastChoices() {
        var store = FolderChoicesStore()
        store.remember(config())
        var overrides = ProjectOverrides()
        overrides.set(.provider, .string("claude"), for: "/repo")
        overrides.set(.model(.codex), .string("from-settings"), for: "/repo")
        overrides.set(.isolation, .string("worktree"), for: "/repo")
        let resolved = defaults(store, folder: "/repo", overrides: overrides)
        XCTAssertEqual(resolved.provider, .claude)
        XCTAssertEqual(resolved.model(for: .codex), "from-settings")
        XCTAssertEqual(resolved.isolation, .worktree)
        XCTAssertEqual(resolved.permission(for: .codex), .bypass, "not set in Settings, so the folder's last choice")
    }

    func testScratchFoldersAndNoFolderKeepNothing() {
        var store = FolderChoicesStore()
        store.remember(config(folder: ""))
        store.remember(config(folder: NookPaths.scratchDirectory.appendingPathComponent("2026-11-05-idea-abc123").path))
        XCTAssertEqual(store, FolderChoicesStore())
    }

    func testUnknownStoredValuesFallBackAndChoicesSurviveARoundTrip() throws {
        var store = FolderChoicesStore()
        store.remember(config())
        store.byFolder["/repo"]?.provider = "gone"
        store.byFolder["/repo"]?.mode = "gone"
        let back = try JSONDecoder().decode(FolderChoicesStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(back, store)
        let resolved = defaults(back, folder: "/repo")
        XCTAssertEqual(resolved.provider, .claude)
        XCTAssertEqual(resolved.mode, .agent)
        XCTAssertEqual(resolved.model(for: .codex), "gpt-5-codex", "the rest stays")
    }

    func testForgettingAFolderDropsItsChoices() {
        var store = FolderChoicesStore()
        store.remember(config())
        store.forget("/repo/")
        XCTAssertNil(store.choices(for: "/repo"))
    }
}
