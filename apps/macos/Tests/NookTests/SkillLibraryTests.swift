import XCTest

final class SkillLibraryTests: XCTestCase {
    private let sha = String(repeating: "c", count: 40)

    private func remote(_ folder: String, repo: String = "acme/skills", files: [String: (Int, String)]) -> RemoteSkill {
        RemoteSkill(repository: SkillRepository.parse(repo)!, commit: sha, folder: folder,
                    files: files.keys.sorted().map { SkillFile(path: $0, size: files[$0]!.0, executable: false, sha: files[$0]!.1) },
                    name: (folder as NSString).lastPathComponent, description: "", refusal: nil)
    }

    private func install(_ skill: RemoteSkill, into root: URL) throws {
        let data = Dictionary(uniqueKeysWithValues: skill.files.map { ($0.path, Data(repeating: 65, count: $0.size)) })
        _ = try SkillInstaller.install(skill, files: data, into: root)
    }

    func testEntriesGroupOneSkillOverEveryAgentFolder() throws {
        let home = URL(fileURLWithPath: try TestData.tempFolder())
        let pdf = remote("skills/pdf", files: ["SKILL.md": (3, "a")])
        // Claude Code's folder and the shared `.agents` folder (Codex and others read it).
        try install(pdf, into: SkillPlaces.root(for: .claude, scope: .user, home: home)!)
        try install(pdf, into: SkillPlaces.root(for: .codex, scope: .user, home: home)!)
        // A skill you put there yourself is not Nook's.
        let own = SkillPlaces.root(for: .claude, scope: .user, home: home)!.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("---\nname: mine\n---".utf8).write(to: own.appendingPathComponent("SKILL.md"))

        let entries = SkillLibrary.entries(scope: .user, providers: [.claude, .codex, .grok], home: home)
        XCTAssertEqual(entries.map(\.name), ["pdf"])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.places.count, 2)
        XCTAssertEqual(Set(entry.providers), [.claude, .codex])
        XCTAssertEqual(entry.source, "acme/skills/skills/pdf")
        XCTAssertEqual(entry.commit, sha)
    }

    func testChangeListsAddedRemovedChangedAndScripts() {
        let installed = SkillProvenance(repository: "acme/skills", ref: nil, folder: "skills/pdf", commit: "old",
                                        installedAt: Date(), files: 3, scripts: [],
                                        hashes: ["SKILL.md": "1", "a.txt": "2", "gone.txt": "3"])
        let now = remote("skills/pdf", files: ["SKILL.md": (1, "1"), "a.txt": (1, "9"), "run.sh": (1, "4")])
        let change = SkillLibrary.change(from: installed, to: now)
        XCTAssertEqual(change, SkillChange(added: ["run.sh"], removed: ["gone.txt"], changed: ["a.txt"], scripts: ["run.sh"]))
        XCTAssertEqual(change?.count, 3)

        var noHashes = installed
        noHashes.hashes = nil
        XCTAssertNil(SkillLibrary.change(from: noHashes, to: now), "without file ids Nook only knows a newer commit")

        let same = remote("skills/pdf", files: ["SKILL.md": (1, "1"), "a.txt": (1, "2"), "gone.txt": (1, "3")])
        XCTAssertEqual(SkillLibrary.change(from: installed, to: same)?.isEmpty, true)
    }

    func testClaudeMarketplacesKeepOnlyGitHubRepositories() {
        let json = """
        {"zeta": {"source": {"source": "github", "repo": "zeta/plugins"}},
         "alpha": {"source": {"source": "github", "repo": "Alpha/market"}},
         "local": {"source": {"source": "directory", "path": "/tmp/x"}},
         "url": {"source": {"source": "url", "url": "https://example.com/m.json"}},
         "bad": {"source": {"source": "github", "repo": "not a repo"}}}
        """
        XCTAssertEqual(SkillSources.claudeMarketplaces(Data(json.utf8)), ["Alpha/market", "zeta/plugins"])
        XCTAssertEqual(SkillSources.claudeMarketplaces(nil), [])
        XCTAssertEqual(SkillSources.claudeMarketplaces(Data("[]".utf8)), [])
    }

    func testSourcesAreDefaultsThenYoursThenClaudesEachOnce() {
        let all = SkillSources.all(added: ["me/skills", "ANTHROPICS/skills", "junk"], claude: ["me/Skills", "other/m"])
        XCTAssertEqual(all.map(\.slug), ["anthropics/skills", "openai/skills", "me/skills", "other/m"])
    }

    func testStoredKeepsRefAndFolder() {
        XCTAssertEqual(SkillSources.stored(SkillRepository.parse("me/skills")!), "me/skills")
        let tree = SkillRepository.parse("https://github.com/me/skills/tree/main/skills/.curated")!
        XCTAssertEqual(SkillSources.stored(tree), "https://github.com/me/skills/tree/main/skills/.curated")
        XCTAssertEqual(SkillRepository.parse(SkillSources.stored(tree)), tree)
    }

    func testComposerOffersTheAgentsOwnFoldersProjectFirst() {
        let home = URL(fileURLWithPath: "/Users/me")
        let project = URL(fileURLWithPath: "/work/app")
        let gemini = SkillIndex.roots(for: .gemini, home: home, project: project).map(\.path)
        XCTAssertEqual(gemini, ["/work/app/.gemini/skills", "/work/app/.claude/skills", "/work/app/.agents/skills",
                                "/Users/me/.gemini/skills", "/Users/me/.claude/skills", "/Users/me/.agents/skills",
                                "/Users/me/.codex/skills"])
        let claude = SkillIndex.roots(for: .claude, home: home, project: nil).map(\.path)
        XCTAssertEqual(claude, ["/Users/me/.claude/skills", "/Users/me/.agents/skills", "/Users/me/.codex/skills"])
        XCTAssertEqual(SkillIndex.roots(for: .acp, home: home, project: nil).map(\.path),
                       SkillIndex.defaultRoots(home: home, project: nil).map(\.path))
    }
}
