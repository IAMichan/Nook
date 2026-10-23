import XCTest

final class CommitStyleTests: XCTestCase {
    func testStandardAddsNothing() {
        XCTAssertEqual(CommitStyle.standard.commitRules(recentSubjects: ["fix: a"], instructions: "x"), [])
    }

    func testConventionalAsksForATypeAndScope() {
        let rules = CommitStyle.conventional.commitRules(recentSubjects: [], instructions: "").joined()
        XCTAssertTrue(rules.contains("Conventional Commits"))
        XCTAssertTrue(rules.contains("scope"))
    }

    func testRepositoryStyleShowsCleanExamples() {
        let rules = CommitStyle.repository.commitRules(
            recentSubjects: ["Add a thing", "Merge pull request #3 from x/y", "Add a thing", "Revert \"Add a thing\"", "  Fix the other  "],
            instructions: "")
        XCTAssertTrue(rules.contains("- Add a thing"))
        XCTAssertTrue(rules.contains("- Fix the other"))
        XCTAssertFalse(rules.contains { $0.contains("Merge pull request") || $0.contains("Revert") })
        XCTAssertEqual(rules.filter { $0 == "- Add a thing" }.count, 1)
        // Without history there is no style to follow.
        XCTAssertEqual(CommitStyle.repository.commitRules(recentSubjects: [], instructions: ""), [])
    }

    func testCustomUsesYourInstructions() {
        XCTAssertEqual(CommitStyle.custom.commitRules(recentSubjects: [], instructions: "  "), [])
        XCTAssertTrue(CommitStyle.custom.commitRules(recentSubjects: [], instructions: "Start with a ticket number").contains("Start with a ticket number"))
        XCTAssertFalse(CommitStyle.custom.pullRequestRules(recentSubjects: [], instructions: "Mention the ticket").isEmpty)
    }

    func testExamplesAreCapped() {
        XCTAssertEqual(CommitStyle.examples((1...40).map { "Change \($0)" }).count, 15)
    }
}
