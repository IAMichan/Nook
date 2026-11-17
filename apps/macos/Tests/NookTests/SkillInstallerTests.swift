import XCTest

final class SkillInstallerTests: XCTestCase {
    private let repo = SkillRepository(owner: "acme", name: "skills")
    private let sha = String(repeating: "b", count: 40)

    private func skill(_ folder: String = "skills/pdf", files: [String: String], repository: SkillRepository? = nil,
                       executable: Set<String> = []) -> (RemoteSkill, [String: Data]) {
        let list = files.keys.sorted().map { SkillFile(path: $0, size: files[$0]!.utf8.count, executable: executable.contains($0)) }
        let skill = RemoteSkill(repository: repository ?? repo, commit: sha, folder: folder, files: list,
                                name: (folder as NSString).lastPathComponent, description: "", refusal: nil)
        return (skill, files.mapValues { Data($0.utf8) })
    }

    private func root() throws -> URL { URL(fileURLWithPath: try TestData.tempFolder()).appendingPathComponent("skills") }

    private func visible(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    func testInstallWritesFilesRecordAndNothingExecutable() throws {
        let root = try root()
        let (s, data) = skill(files: ["SKILL.md": "---\nname: pdf\ndescription: PDFs\n---", "scripts/fill.py": "print(1)"],
                              executable: ["scripts/fill.py"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try SkillInstaller.install(s, files: data, into: root, now: now)
        XCTAssertEqual(url.lastPathComponent, "pdf")
        XCTAssertEqual(visible(root), ["pdf"], "the hidden staging folder is gone")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("scripts/fill.py"), encoding: .utf8), "print(1)")
        let mode = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("scripts/fill.py").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644, "Nook never marks a downloaded file executable")
        let record = try XCTUnwrap(SkillInstaller.provenance(at: url))
        XCTAssertEqual(record, SkillProvenance(repository: "acme/skills", ref: nil, folder: "skills/pdf", commit: sha,
                                               installedAt: now, files: 2, scripts: ["scripts/fill.py"]))
        XCTAssertEqual(SkillInstaller.installed(in: root).map(\.name), ["pdf"])
        XCTAssertEqual(SkillIndex.scan(roots: [root]).map(\.description), ["PDFs"], "the composer's `$` list finds it")
    }

    func testRefusesWhatWasNotPreviewed() throws {
        let root = try root()
        let (s, data) = skill(files: ["SKILL.md": "x", "a.txt": "abc"])
        var missing = data
        missing["a.txt"] = nil
        XCTAssertThrowsError(try SkillInstaller.install(s, files: missing, into: root)) { XCTAssertEqual($0 as? SkillInstaller.InstallError, .missingFile("a.txt")) }
        var changed = data
        changed["a.txt"] = Data("abcd".utf8)
        XCTAssertThrowsError(try SkillInstaller.install(s, files: changed, into: root)) { XCTAssertEqual($0 as? SkillInstaller.InstallError, .sizeMismatch("a.txt")) }
        var refused = s
        refused.refusal = .link("x")
        XCTAssertThrowsError(try SkillInstaller.install(refused, files: data, into: root)) { XCTAssertEqual($0 as? SkillInstaller.InstallError, .refused(.link("x"))) }
        var traversal = s
        traversal.files.append(SkillFile(path: "../evil", size: 0, executable: false))
        var withEvil = data
        withEvil["../evil"] = Data()
        XCTAssertThrowsError(try SkillInstaller.install(traversal, files: withEvil, into: root)) { XCTAssertEqual($0 as? SkillInstaller.InstallError, .refused(.unsafePath("../evil"))) }
        let (noSkillFile, files) = skill(files: ["README.md": "x"])
        XCTAssertThrowsError(try SkillInstaller.install(noSkillFile, files: files, into: root)) { XCTAssertEqual($0 as? SkillInstaller.InstallError, .missingFile("SKILL.md")) }
        XCTAssertEqual(visible(root), [], "nothing was left behind")
    }

    func testUpdateReplacesOtherSourceAsksAndOwnSkillsStay() throws {
        let root = try root()
        let (v1, d1) = skill(files: ["SKILL.md": "one", "old.txt": "gone"])
        try SkillInstaller.install(v1, files: d1, into: root)
        var (v2, d2) = skill(files: ["SKILL.md": "two"])
        v2.commit = String(repeating: "c", count: 40)
        let url = try SkillInstaller.install(v2, files: d2, into: root)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("old.txt").path), "an update replaces the whole folder")
        XCTAssertEqual(SkillInstaller.provenance(at: url)?.commit, v2.commit)
        XCTAssertEqual(visible(root), ["pdf"])

        let (other, d3) = skill(files: ["SKILL.md": "fork"], repository: SkillRepository(owner: "someone", name: "fork"))
        XCTAssertThrowsError(try SkillInstaller.install(other, files: d3, into: root)) {
            guard case .otherSource("pdf", let record)? = $0 as? SkillInstaller.InstallError else { return XCTFail("\($0)") }
            XCTAssertEqual(record.repository, "acme/skills")
        }
        try SkillInstaller.install(other, files: d3, into: root, replace: true)
        XCTAssertEqual(SkillInstaller.provenance(at: url)?.repository, "someone/fork")

        let own = root.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("hand made".utf8).write(to: own.appendingPathComponent("SKILL.md"))
        let (clash, d4) = skill("x/mine", files: ["SKILL.md": "z"])
        XCTAssertThrowsError(try SkillInstaller.install(clash, files: d4, into: root, replace: true)) {
            XCTAssertEqual($0 as? SkillInstaller.InstallError, .notFromNook("mine"), "even replace never touches the user's own skill")
        }
        XCTAssertThrowsError(try SkillInstaller.remove("mine", from: root))
        XCTAssertEqual(SkillInstaller.installed(in: root).map(\.name), ["pdf"])
        try SkillInstaller.remove("pdf", from: root)
        XCTAssertEqual(visible(root), ["mine"])
        XCTAssertThrowsError(try SkillInstaller.remove("../skills", from: root))
    }

    func testLinkedSkillFolderIsNotNooks() throws {
        let root = try root()
        let (s, data) = skill(files: ["SKILL.md": "x"])
        let elsewhere = try SkillInstaller.install(s, files: data, into: root.appendingPathComponent("../elsewhere").standardizedFileURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("pdf"), withDestinationURL: elsewhere)
        XCTAssertNil(SkillInstaller.provenance(at: root.appendingPathComponent("pdf")))
        XCTAssertThrowsError(try SkillInstaller.install(s, files: data, into: root)) { XCTAssertEqual($0 as? SkillInstaller.InstallError, .notFromNook("pdf")) }
        XCTAssertThrowsError(try SkillInstaller.remove("pdf", from: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("SKILL.md").path))
    }

    func testEveryAgentHasAPlaceOrSaysWhy() {
        let home = URL(fileURLWithPath: "/Users/me"), project = URL(fileURLWithPath: "/code/app")
        for provider in RunProvider.allCases {
            let user = SkillPlaces.root(for: provider, scope: .user, home: home)
            let local = SkillPlaces.root(for: provider, scope: .project(project), home: home)
            switch provider {
            case .acp:
                XCTAssertNil(user)
                XCTAssertNil(local)
            case .claude, .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi:
                XCTAssertTrue(user?.path.hasPrefix("/Users/me/.") == true, "\(provider)")
                XCTAssertTrue(local?.path.hasPrefix("/code/app/.") == true, "\(provider)")
                XCTAssertEqual(user?.lastPathComponent, "skills")
            }
        }
        XCTAssertEqual(SkillPlaces.root(for: .claude, scope: .user, home: home)?.path, "/Users/me/.claude/skills")
        XCTAssertEqual(SkillPlaces.root(for: .codex, scope: .project(project), home: home)?.path, "/code/app/.agents/skills")
        let shared = SkillPlaces.roots(for: [.claude, .grok, .codex, .antigravity, .acp], scope: .project(project), home: home)
        XCTAssertEqual(shared.map(\.path), ["/code/app/.claude/skills", "/code/app/.agents/skills"], "agents that read one folder share one copy")
    }
}
