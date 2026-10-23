import XCTest

/// The model manifest: parsing, validation, which copy wins, version checks, and the model menus built from it. Synthetic
/// model names throughout, so adding a model to the manifest never needs a test change.
final class ModelManifestTests: XCTestCase {
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private func json(updatedAt: String = "2026-10-01T00:00:00Z", version: Int = 1, claude: String? = nil) -> Data {
        let models = claude ?? """
        [{"id": "alpha-2", "name": "Alpha 2", "status": "current", "badge": "new", "aliases": ["alpha"],
          "adapter": {"claude": {"minVersion": "2.1.300"}}},
         {"id": "beta-1", "name": "Beta 1", "status": "current"},
         {"id": "alpha-1", "name": "Alpha 1", "status": "legacy", "adapter": {"claude": {"minVersion": "2.0.0"}}}]
        """
        return Data("""
        {"version": \(version), "updatedAt": "\(updatedAt)",
         "agents": {"claude": {"models": \(models)},
                    "codex": {"defaultModel": "gamma", "models": [
                       {"id": "gamma", "name": "Gamma", "status": "current"},
                       {"id": "delta", "name": "Delta", "status": "current", "adapter": {"codex": {"minVersion": "0.200.0"}}}]}}}
        """.utf8)
    }

    private func manifest(updatedAt: String = "2026-10-01T00:00:00Z") throws -> ModelManifest {
        try ModelManifest.parse(json(updatedAt: updatedAt))
    }

    // MARK: Parsing and validation

    func testParsesAValidManifest() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.entry(for: .claude)?.models.map(\.id), ["alpha-2", "beta-1", "alpha-1"])
        XCTAssertEqual(manifest.entry(for: .codex)?.defaultModel, "gamma")
        XCTAssertNil(manifest.entry(for: .gemini))
        XCTAssertEqual(manifest.model("ALPHA", for: .claude)?.id, "alpha-2")
        XCTAssertEqual(manifest.canonicalID("alpha", for: .claude), "alpha-2")
        XCTAssertEqual(manifest.canonicalID("custom-x", for: .claude), "custom-x")
    }

    func testTheBundledManifestValidates() throws {
        let url = Self.root.appendingPathComponent("Services/Workspace/model-manifest.json")
        let manifest = try ModelManifest.parse(Data(contentsOf: url))
        XCTAssertNotNil(manifest.entry(for: .claude))
        XCTAssertNotNil(manifest.entry(for: .codex))
        XCTAssertTrue(manifest.agents.keys.allSatisfy { RunProvider(rawValue: $0) != nil })
        XCTAssertEqual(ModelManifest.remoteURL.lastPathComponent, url.lastPathComponent)
    }

    func testRefusesWhatIsNotAManifest() {
        XCTAssertThrowsError(try ModelManifest.parse(Data("not json".utf8))) { XCTAssertEqual($0 as? ModelManifestError, .unreadable) }
        XCTAssertThrowsError(try ModelManifest.parse(json(version: 2))) {
            XCTAssertEqual($0 as? ModelManifestError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try ModelManifest.parse(json(updatedAt: "yesterday")))
        XCTAssertThrowsError(try ModelManifest.parse(Data(count: ModelManifest.maxBytes + 1))) {
            XCTAssertEqual($0 as? ModelManifestError, .tooLarge)
        }
        XCTAssertThrowsError(try ModelManifest.parse(Data(#"{"version": 1, "updatedAt": "2026-10-01T00:00:00Z", "agents": {}}"#.utf8)))
    }

    func testRefusesModelsThatAreUnsafeOrAmbiguous() {
        let cases = [
            // Read as an option by the agent.
            #"[{"id": "--dangerously-skip-permissions", "name": "X", "status": "current"}]"#,
            #"[{"id": "two words", "name": "X", "status": "current"}]"#,
            #"[{"id": "a", "name": " ", "status": "current"}]"#,
            #"[{"id": "a", "name": "A", "status": "experimental"}]"#,
            // The same name twice, as an id and as an alias.
            #"[{"id": "a", "name": "A", "status": "current"}, {"id": "b", "name": "B", "status": "current", "aliases": ["A"]}]"#,
            #"[{"id": "a", "name": "A", "status": "current", "adapter": {"claude": {"minVersion": "soon"}}}]"#,
            // Settings for another agent in Claude's entry.
            #"[{"id": "a", "name": "A", "status": "current", "adapter": {"codex": {"minVersion": "1.0.0"}}}]"#,
            "[]"
        ]
        for models in cases {
            XCTAssertThrowsError(try ModelManifest.parse(json(claude: models)), models)
        }
        let badDefault = Data(#"{"version": 1, "updatedAt": "2026-10-01T00:00:00Z", "agents": {"codex": {"defaultModel": "zeta", "models": [{"id": "a", "name": "A", "status": "current"}]}}}"#.utf8)
        XCTAssertThrowsError(try ModelManifest.parse(badDefault))
    }

    func testModelIDs() {
        for id in ["claude-x-1", "gpt-9.1", "org/model:latest", "model[1m]", "a@b"] { XCTAssertTrue(ModelManifest.isValidID(id), id) }
        for id in ["", "-x", "a b", "a;rm", "a\nb", "é", String(repeating: "a", count: 129)] {
            XCTAssertFalse(ModelManifest.isValidID(id), id)
        }
    }

    // MARK: Which copy is used

    func testANewerBundleWinsOverAnOlderCache() throws {
        let bundled = try manifest(updatedAt: "2026-10-10T00:00:00Z")
        let older = try manifest(updatedAt: "2026-10-01T00:00:00Z")
        let newer = try manifest(updatedAt: "2026-10-20T00:00:00Z")
        XCTAssertEqual(ModelManifest.preferred(bundled: bundled, cached: older), bundled)
        XCTAssertEqual(ModelManifest.preferred(bundled: bundled, cached: newer), newer)
        XCTAssertEqual(ModelManifest.preferred(bundled: bundled, cached: bundled), bundled)
        XCTAssertEqual(ModelManifest.preferred(bundled: nil, cached: older), older)
        XCTAssertEqual(ModelManifest.preferred(bundled: bundled, cached: nil), bundled)
    }

    func testAFetchKeepsTheLastValidCopy() throws {
        let current = try manifest(updatedAt: "2026-10-10T00:00:00Z")
        XCTAssertNil(ModelManifest.accepting(Data("{}".utf8), over: current))
        XCTAssertNil(ModelManifest.accepting(json(claude: "[]"), over: current))
        XCTAssertNil(ModelManifest.accepting(json(updatedAt: "2026-10-01T00:00:00Z"), over: current))
        XCTAssertEqual(ModelManifest.accepting(json(updatedAt: "2026-10-20T00:00:00Z"), over: current)?.updatedAt,
                       ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z"))
        XCTAssertNotNil(ModelManifest.accepting(json(), over: nil))
    }

    func testTheStoreKeepsOnlyAValidCopy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)/m.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ModelManifestStore(url: url)
        XCTAssertNil(store.load())
        store.save(json())
        XCTAssertEqual(store.load(), try manifest())
        store.save(Data("broken".utf8))
        XCTAssertNil(store.load())
    }

    func testRefreshIsRareAndNeverOffline() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ModelManifestRefresh.isDue(online: true, lastAttempt: nil, now: now))
        XCTAssertFalse(ModelManifestRefresh.isDue(online: false, lastAttempt: nil, now: now))
        XCTAssertFalse(ModelManifestRefresh.isDue(online: true, lastAttempt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(ModelManifestRefresh.isDue(online: true, lastAttempt: now.addingTimeInterval(-ModelManifestRefresh.interval), now: now))
        XCTAssertFalse(ModelManifestRefresh.isDue(online: false, lastAttempt: now.addingTimeInterval(-ModelManifestRefresh.interval), now: now))
        // A clock that went back does not block refreshing for hours.
        XCTAssertTrue(ModelManifestRefresh.isDue(online: true, lastAttempt: now.addingTimeInterval(3600), now: now))
    }

    // MARK: Versions

    func testReadsTheVersionsAgentsPrint() {
        XCTAssertEqual(CLIVersion("2.1.280 (Claude Code)")?.description, "2.1.280")
        XCTAssertEqual(CLIVersion("codex-cli 0.153.0")?.description, "0.153.0")
        XCTAssertEqual(CLIVersion("v1.2.3-beta.1")?.description, "1.2.3-beta.1")
        XCTAssertEqual(CLIVersion("1.4.0+build.7")?.description, "1.4.0")
        XCTAssertNil(CLIVersion("command not found"))
        XCTAssertNil(CLIVersion(""))
    }

    func testComparesVersionsNumerically() {
        func v(_ text: String) -> CLIVersion { CLIVersion(text)! }
        XCTAssertLessThan(v("2.1.99"), v("2.1.280"))
        XCTAssertLessThan(v("0.9"), v("0.10.0"))
        XCTAssertEqual(v("2.1"), v("2.1.0"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.10"))
        XCTAssertLessThan(v("1.0.0-rc.1"), v("1.0.0"))
        XCTAssertFalse(v("1.0.0") < v("1.0.0-rc.1"))
    }

    func testUpdateRequiredOnlyWhenSure() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.requiredVersion("alpha", for: .claude, installed: "2.1.250 (Claude Code)"), "2.1.300")
        XCTAssertNil(manifest.requiredVersion("alpha-2", for: .claude, installed: "2.1.300"))
        XCTAssertNil(manifest.requiredVersion("alpha-2", for: .claude, installed: nil))
        XCTAssertNil(manifest.requiredVersion("alpha-2", for: .claude, installed: "unknown"))
        XCTAssertNil(manifest.requiredVersion("beta-1", for: .claude, installed: "0.0.1"))
        XCTAssertNil(manifest.requiredVersion("alpha-2", for: .codex, installed: "0.0.1"))
    }

    // MARK: Menus

    func testChoicesFromTheManifest() throws {
        let choices = ModelChoice.list(manifest: try manifest(), provider: .claude, offered: [], installed: "2.1.250")
        XCTAssertEqual(choices.map(\.id), ["alpha-2", "beta-1", "alpha-1"])
        XCTAssertEqual(choices[0].requiredVersion, "2.1.300")
        XCTAssertTrue(choices[0].isNew && choices[0].needsUpdate)
        XCTAssertFalse(choices[1].needsUpdate)
        XCTAssertTrue(choices[2].isLegacy)
        XCTAssertFalse(choices[2].needsUpdate)
    }

    func testAnAgentsOwnListComesFirstAndOnlyUpdatesAreAdded() throws {
        let offered = [AgentModel(id: "gamma", name: "Gamma (agent)", isDefault: true), AgentModel(id: "own", name: "Own")]
        let old = ModelChoice.list(manifest: try manifest(), provider: .codex, offered: offered, installed: "codex-cli 0.150.0")
        XCTAssertEqual(old.map(\.id), ["gamma", "own", "delta"])
        XCTAssertEqual(old[0].name, "Gamma (agent)")
        XCTAssertTrue(old[0].isDefault)
        XCTAssertEqual(old[2].requiredVersion, "0.200.0")
        // Up to date: a model the agent does not list is not one this account can use.
        let fresh = ModelChoice.list(manifest: try manifest(), provider: .codex, offered: offered, installed: "0.200.0")
        XCTAssertEqual(fresh.map(\.id), ["gamma", "own"])
    }

    func testWithoutAManifestTheWellKnownNamesStay() {
        let choices = ModelChoice.list(manifest: nil, provider: .claude, offered: [], installed: nil)
        XCTAssertEqual(choices.map(\.id), RunProvider.claude.suggestedModels.filter { !$0.isEmpty })
        XCTAssertTrue(ModelChoice.list(manifest: nil, provider: .opencode, offered: [], installed: nil).isEmpty)
    }

    func testFavoritesComeFirstAfterTheDefault() {
        XCTAssertEqual(ModelOrdering.sorted(["", "a", "b", "c", "d"], favorites: ["d", "b", "zzz"]), ["", "b", "d", "a", "c"])
        XCTAssertEqual(ModelOrdering.sorted(["a", "b"], favorites: []), ["a", "b"])
    }

    func testFavoritesAndCustomModels() {
        XCTAssertEqual(ModelPreferences.toggling("a", in: []), ["a"])
        XCTAssertEqual(ModelPreferences.toggling("a", in: ["b", "a"]), ["b"])
        XCTAssertEqual(ModelPreferences.toggling("", in: ["b"]), ["b"])
        XCTAssertEqual(ModelPreferences.customID("  my-model:7b \n"), "my-model:7b")
        XCTAssertNil(ModelPreferences.customID("--yolo"))
        XCTAssertEqual(ModelPreferences.remembering("x", in: ["y", "x"]), ["x", "y"])
        XCTAssertEqual(ModelPreferences.remembering("bad id", in: ["y"]), ["y"])
        let many = (0..<20).map { "m\($0)" }
        XCTAssertEqual(ModelPreferences.remembering("new", in: many).count, ModelPreferences.customLimit)
    }
}
