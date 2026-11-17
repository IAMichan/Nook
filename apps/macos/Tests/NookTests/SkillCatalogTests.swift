import XCTest

final class SkillCatalogTests: XCTestCase {
    private let repo = SkillRepository(owner: "acme", name: "skills")
    private let sha = String(repeating: "a", count: 40)

    static func tree(_ entries: [(String, String, String, Int)], truncated: Bool = false) -> Data {
        let rows = entries.map { ["path": $0.0, "type": $0.1, "mode": $0.2, "size": $0.3] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["sha": "x", "tree": rows, "truncated": truncated])
    }

    func testRepositoryForms() {
        XCTAssertEqual(SkillRepository.parse("anthropics/skills"), SkillRepository(owner: "anthropics", name: "skills"))
        XCTAssertEqual(SkillRepository.parse(" github:openai/skills@v2 ")?.ref, "v2")
        XCTAssertEqual(SkillRepository.parse("https://github.com/acme/tools.git"), SkillRepository(owner: "acme", name: "tools"))
        let tree = SkillRepository.parse("https://github.com/openai/skills/tree/main/skills/.curated")
        XCTAssertEqual(tree, SkillRepository(owner: "openai", name: "skills", ref: "main", folder: "skills/.curated"))
        let blob = SkillRepository.parse("github.com/acme/skills/blob/dev/pdf/SKILL.md")
        XCTAssertEqual(blob, SkillRepository(owner: "acme", name: "skills", ref: "dev", folder: "pdf"))
        for bad in ["", "acme", "acme/skills/extra", "../x", "a b/c", "acme/skills@", "https://github.com/acme/skills/tree/main/../x"] {
            XCTAssertNil(SkillRepository.parse(bad), bad)
        }
    }

    func testSafePaths() {
        for good in ["SKILL.md", "scripts/run.py", ".hidden/file", "a/b/c.txt"] { XCTAssertTrue(SkillPaths.isSafe(good), good) }
        for bad in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a/.git/config", ".GIT/x", "a\\b", "a\nb"] {
            XCTAssertFalse(SkillPaths.isSafe(bad), bad)
        }
    }

    func testSearchHitsFromSkillsSh() throws {
        let json = """
        {"query":"pdf","skills":[
          {"id":"anthropics/skills/pdf","source":"anthropics/skills","skillId":"pdf","name":"pdf","installs":231296},
          {"id":"smithery.ai/frontend-design","source":"smithery.ai","skillId":"frontend-design","name":"frontend-design","installs":6378},
          {"id":"openai/skills/pdf","source":"openai/skills","skillId":"pdf","name":"pdf"}
        ],"count":3}
        """
        let hits = try SkillCatalog.searchHits(Data(json.utf8))
        XCTAssertEqual(hits.map(\.id), ["anthropics/skills/pdf", "openai/skills/pdf"], "a source that is not owner/repo is left out")
        XCTAssertEqual(hits[0].installs, 231296)
        XCTAssertEqual(hits[1].installs, 0)
        XCTAssertEqual(hits[0].repository.slug, "anthropics/skills")
        XCTAssertThrowsError(try SkillCatalog.searchHits(Data("<html>".utf8)))
        XCTAssertEqual(try SkillCatalog.searchHits(Data("{}".utf8)), [])
    }

    func testTreeFindsSkillsAnywhereAndGivesFilesToTheClosestOne() throws {
        let data = Self.tree([
            ("README.md", "blob", "100644", 10),
            ("skills", "tree", "040000", 0),
            ("skills/pdf/SKILL.md", "blob", "100644", 100),
            ("skills/pdf/scripts/fill.py", "blob", "100755", 50),
            ("skills/pdf/forms/FORMS.md", "blob", "100644", 20),
            ("skills/.curated/review/SKILL.md", "blob", "100644", 30),
            ("skills/.curated/review/tools/run", "blob", "100755", 5),
            ("skills/.curated/review/nested/SKILL.md", "blob", "100644", 7),
            ("skills/.curated/review/nested/x.txt", "blob", "100644", 1),
            ("other/notes.txt", "blob", "100644", 1),
        ])
        let skills = try SkillCatalog.skills(inTree: data, repository: repo, commit: sha)
        XCTAssertEqual(skills.map(\.folder), ["skills/.curated/review", "skills/.curated/review/nested", "skills/pdf"])
        let pdf = skills[2]
        XCTAssertEqual(pdf.files.map(\.path), ["SKILL.md", "forms/FORMS.md", "scripts/fill.py"])
        XCTAssertEqual(pdf.scripts.map(\.path), ["scripts/fill.py"])
        XCTAssertEqual(pdf.totalBytes, 170)
        XCTAssertEqual(pdf.name, "pdf")
        XCTAssertNil(pdf.refusal)
        XCTAssertEqual(skills[0].files.map(\.path), ["SKILL.md", "tools/run"], "the nested skill keeps its own files")
        XCTAssertEqual(skills[0].scripts.map(\.path), ["tools/run"], "executable without an extension is a script")
        XCTAssertEqual(skills[1].files.map(\.path), ["SKILL.md", "x.txt"])
    }

    func testRootSkillAndFolderScope() throws {
        let data = Self.tree([("SKILL.md", "blob", "100644", 9), ("a/SKILL.md", "blob", "100644", 9), ("ab/SKILL.md", "blob", "100644", 9)])
        let all = try SkillCatalog.skills(inTree: data, repository: repo, commit: sha)
        XCTAssertEqual(all.map(\.folder), ["", "a", "ab"])
        XCTAssertEqual(all[0].name, "skills", "a SKILL.md at the root is named after the repository")
        XCTAssertEqual(all[0].files.map(\.path), ["SKILL.md"])
        var scoped = repo
        scoped.folder = "a"
        XCTAssertEqual(try SkillCatalog.skills(inTree: data, repository: scoped, commit: sha).map(\.folder), ["a"], "`ab` is not inside `a`")
    }

    func testLinksSubmodulesAndSizesAreRefused() throws {
        let data = Self.tree([
            ("link/SKILL.md", "blob", "100644", 1), ("link/escape", "blob", "120000", 11),
            ("sub/SKILL.md", "blob", "100644", 1), ("sub/vendor", "commit", "160000", 0),
            ("big/SKILL.md", "blob", "100644", 1), ("big/model.bin", "blob", "100644", SkillLimits.maxFileBytes + 1),
            ("fine/SKILL.md", "blob", "100644", 1),
        ])
        let byFolder = Dictionary(uniqueKeysWithValues: try SkillCatalog.skills(inTree: data, repository: repo, commit: sha).map { ($0.folder, $0) })
        XCTAssertEqual(byFolder["link"]?.refusal, .link("escape"))
        XCTAssertEqual(byFolder["sub"]?.refusal, .submodule("vendor"))
        XCTAssertEqual(byFolder["big"]?.refusal, .fileTooLarge("model.bin", SkillLimits.maxFileBytes + 1))
        XCTAssertNil(byFolder["fine"]?.refusal)
        XCTAssertThrowsError(try SkillCatalog.skills(inTree: Self.tree([], truncated: true), repository: repo, commit: sha)) {
            XCTAssertEqual($0 as? SkillCatalog.ParseError, .truncated)
        }
    }

    func testDescribeAndMatch() throws {
        let data = Self.tree([("skills/design-v2/SKILL.md", "blob", "100644", 1), ("skills/pdf/SKILL.md", "blob", "100644", 1)])
        var skills = try SkillCatalog.skills(inTree: data, repository: repo, commit: sha)
        skills[0].describe(skillFile: "---\nname: \"taste\"\ndescription: >\n  Picks a look\n  on purpose\n---\nbody")
        XCTAssertEqual(skills[0].name, "taste")
        XCTAssertEqual(skills[0].description, "Picks a look on purpose")
        func hit(_ id: String) -> SkillSearchHit { SkillSearchHit(id: "x", repository: repo, skillID: id, name: id, installs: 0) }
        XCTAssertEqual(SkillCatalog.match(hit("PDF"), in: skills)?.folder, "skills/pdf", "by folder name first")
        XCTAssertEqual(SkillCatalog.match(hit("taste"), in: skills)?.folder, "skills/design-v2", "else by the front matter's name")
        XCTAssertNil(SkillCatalog.match(hit("none"), in: skills))
    }

    func testCommitSHA() {
        XCTAssertEqual(SkillCatalog.commitSHA(Data(#"{"sha":"\#(String(repeating: "A", count: 40))"}"#.utf8)), String(repeating: "a", count: 40))
        XCTAssertNil(SkillCatalog.commitSHA(Data(#"{"sha":"main"}"#.utf8)))
        XCTAssertNil(SkillCatalog.commitSHA(Data("[]".utf8)))
    }

    func testInstallName() {
        var skill = RemoteSkill(repository: repo, commit: sha, folder: "skills/My Skill!", files: [], name: "x", description: "", refusal: nil)
        XCTAssertEqual(SkillPaths.installName(skill), "My-Skill")
        skill.folder = "skills/..."
        XCTAssertEqual(SkillPaths.installName(skill), "x", "a folder name that cleans to nothing falls back to the name")
    }
}
