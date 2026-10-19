import XCTest

final class SkillIndexTests: XCTestCase {
    private func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testScanReadsFrontMatterVariants() throws {
        let root = try TestData.tempFolder()
        try write(root + "/alpha/SKILL.md", "---\nname: \"Alpha\"\ndescription: 'Does a'\n---\nbody")
        try write(root + "/beta/SKILL.md", "---\nname: beta\ndescription: >\n  folded one\n  folded two\n---\n")
        try write(root + "/gamma/SKILL.md", "no front matter")
        try write(root + "/delta/SKILL.md", "---\nname: delta\ndescription: never closed")
        try write(root + "/single.md", "---\ndescription: one file\n---")
        try write(root + "/README.md", "ignore")
        try write(root + "/.hidden/SKILL.md", "---\nname: hidden\n---")
        try write(root + "/empty/other.txt", "x")
        let skills = SkillIndex.scan(roots: [URL(fileURLWithPath: root)])
        XCTAssertEqual(skills.map(\.name), ["Alpha", "beta", "delta", "gamma", "single"])
        XCTAssertEqual(skills[0].description, "Does a")
        XCTAssertEqual(skills[1].description, "folded one folded two")
        XCTAssertEqual(skills[2].description, "", "unclosed front matter is ignored")
        XCTAssertEqual(skills[4].description, "one file")
    }

    func testProjectBeatsUserAndEmptyRoots() throws {
        let home = try TestData.tempFolder(), project = try TestData.tempFolder()
        try write(project + "/.claude/skills/x/SKILL.md", "---\nname: x\ndescription: project\n---")
        try write(home + "/.claude/skills/x/SKILL.md", "---\nname: x\ndescription: user\n---")
        let roots = SkillIndex.defaultRoots(home: URL(fileURLWithPath: home), project: URL(fileURLWithPath: project))
        XCTAssertEqual(roots.count, 5)
        XCTAssertEqual(SkillIndex.scan(roots: roots).map(\.description), ["project"])
        XCTAssertEqual(SkillIndex.defaultRoots(home: URL(fileURLWithPath: home), project: nil).count, 3)
        XCTAssertEqual(SkillIndex.scan(roots: []), [])
        XCTAssertEqual(SkillIndex.scan(roots: [URL(fileURLWithPath: home + "/missing")]), [])
    }

    func testHugeFileOnlyHeadIsRead() throws {
        let root = try TestData.tempFolder()
        try write(root + "/big/SKILL.md", "---\nname: big\ndescription: ok\n---\n" + String(repeating: "x", count: 500_000))
        XCTAssertEqual(SkillIndex.scan(roots: [URL(fileURLWithPath: root)]).first?.description, "ok")
    }

    func testFilterRanking() {
        func s(_ n: String, _ d: String = "") -> Skill { Skill(name: n, description: d, path: "", source: "") }
        let list = [s("review", "check code"), s("pre-review"), s("deploy", "ships review output"), s("rev-x")]
        XCTAssertEqual(SkillIndex.filter(list, query: "$rev").map(\.name), ["review", "rev-x", "pre-review", "deploy"])
        XCTAssertEqual(SkillIndex.filter(list, query: "").count, 4)
        XCTAssertEqual(SkillIndex.filter(list, query: "", limit: 2).count, 2)
        XCTAssertEqual(SkillIndex.filter(list, query: "zzz"), [])
    }
}
