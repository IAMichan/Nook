import XCTest

final class AddProjectSourceTests: XCTestCase {
    func testGitHubOwnerRepoBecomesItsHTTPSAddress() {
        XCTAssertEqual(AddProjectSource.githubURL("octocat/hello-world"), "")
        XCTAssertEqual(AddProjectSource.githubURL(" github.com/a-b/c_d.e "), "https://github.com/a-b/c_d.e.git")
        XCTAssertEqual(AddProjectSource.githubURL("http://www.github.com/a/b.git"), "https://github.com/a/b.git")
        XCTAssertEqual(AddProjectSource.githubURL("https://github.com/a/b/tree/main"), "https://github.com/a/b")
    }

    func testNotAGitHubRepository() {
        XCTAssertNil(AddProjectSource.githubURL(""))
        XCTAssertNil(AddProjectSource.githubURL("just-a-name"))
        XCTAssertNil(AddProjectSource.githubURL("a/b/c"))
        XCTAssertNil(AddProjectSource.githubURL("../etc"))
        XCTAssertNil(AddProjectSource.githubURL("a b/c"))
        XCTAssertNil(AddProjectSource.githubURL("https://gitlab.com/a/b"))
    }

    func testDefaultProjectBadgeIsStableInitialsOnATint() {
        XCTAssertEqual(ProjectIcon.defaultTint("Nook"), ProjectIcon.defaultTint("nook"))
        XCTAssertEqual(ProjectIcon.defaultIcon("Infaris-monorepo"),
                       .monogram("IM", ProjectIcon.defaultTint("Infaris-monorepo")))
        // Not every project the same color.
        let tints = Set(["Nook", "WhoBench", "Stemmen", "Stakavo", "Taggerd", "iPsalm", "Ditto-Social"].map(ProjectIcon.defaultTint))
        XCTAssertGreaterThan(tints.count, 2)
    }
}
