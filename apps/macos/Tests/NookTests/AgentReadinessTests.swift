import XCTest

final class AgentReadinessTests: XCTestCase {
    typealias R = AgentReadiness

    func testClassification() {
        XCTAssertEqual(R.classify(scanned: false, installed: false, signedIn: false, connecting: false), .checking)
        XCTAssertEqual(R.classify(scanned: true, installed: false, signedIn: false, connecting: false), .missing)
        XCTAssertEqual(R.classify(scanned: true, installed: false, signedIn: true, connecting: false), .missing,
                       "a sign-in without the program still needs the program")
        XCTAssertEqual(R.classify(scanned: true, installed: true, signedIn: false, connecting: false), .signIn)
        XCTAssertEqual(R.classify(scanned: true, installed: true, signedIn: true, connecting: false), .ready)
        XCTAssertEqual(R.classify(scanned: true, installed: false, signedIn: false, connecting: true), .connecting)
        // Found before the full scan finished: what is there counts.
        XCTAssertEqual(R.classify(scanned: false, installed: true, signedIn: true, connecting: false), .ready)
    }

    func testActions() {
        XCTAssertEqual(R.action(for: .missing), .install)
        XCTAssertEqual(R.action(for: .signIn), .signIn)
        for state: R.State in [.checking, .connecting, .ready] { XCTAssertEqual(R.action(for: state), .none) }
        XCTAssertTrue(R.anyReady([.missing, .ready]))
        XCTAssertFalse(R.anyReady([.missing, .signIn]))
    }

    func testGitRootWalksUp() {
        let repos: Set<String> = ["/Users/me/app/.git", "/Users/me/app/vendor/lib/.git"]
        let exists: (String) -> Bool = { repos.contains($0) }
        XCTAssertEqual(R.gitRoot(of: "/Users/me/app/src/ui", fileExists: exists), "/Users/me/app")
        XCTAssertEqual(R.gitRoot(of: "/Users/me/app/", fileExists: exists), "/Users/me/app")
        XCTAssertEqual(R.gitRoot(of: "/Users/me/app/vendor/lib/x", fileExists: exists), "/Users/me/app/vendor/lib")
        XCTAssertNil(R.gitRoot(of: "/Users/me/notes", fileExists: exists))
        XCTAssertNil(R.gitRoot(of: "relative/path", fileExists: { _ in true }))
    }

    func testProjectCandidatesGroupByRepositoryAndSkipOldOrPlainFolders() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let day: TimeInterval = 24 * 3600
        let roots = ["/Users/me/app": "/Users/me/app", "/Users/me/app/web": "/Users/me/app", "/Users/me/api": "/Users/me/api",
                     "/Users/me/old": "/Users/me/old", "/Users/me": "/Users/me"]
        let sessions: [(folder: String, date: Date)] = [
            ("/Users/me/app/web", now.addingTimeInterval(-2 * day)),
            ("/Users/me/app", now.addingTimeInterval(-5 * day)),
            ("/Users/me/api/", now.addingTimeInterval(-1 * day)),
            ("/Users/me/old", now.addingTimeInterval(-40 * day)),
            ("/Users/me/notes", now.addingTimeInterval(-1 * day)),
            ("/Users/me", now.addingTimeInterval(-1 * day)),
            ("", now),
        ]
        let result = R.projectCandidates(sessions: sessions, known: ["/Users/me/api/"], home: "/Users/me", now: now,
                                         gitRoot: { roots[$0] })
        XCTAssertEqual(result.map(\.path), ["/Users/me/api", "/Users/me/app"])
        XCTAssertEqual(result.map(\.sessions), [1, 2])
        XCTAssertEqual(result.map(\.added), [true, false])
        XCTAssertEqual(result.last?.name, "app")
        XCTAssertEqual(result.last?.parent, "/Users/me/")
        XCTAssertEqual(result.last?.lastActive, now.addingTimeInterval(-2 * day))
    }

    func testProjectCandidatesAreLimited() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let sessions = (0..<20).map { (folder: "/r/p\($0)", date: now.addingTimeInterval(-Double($0) * 60)) }
        let result = R.projectCandidates(sessions: sessions, known: [], home: "/Users/me", now: now, limit: 3, gitRoot: { $0 })
        XCTAssertEqual(result.map(\.path), ["/r/p0", "/r/p1", "/r/p2"])
    }

    func testSplitPath() {
        XCTAssertEqual(R.splitPath("/Users/me/Developer/app/").name, "app")
        XCTAssertEqual(R.splitPath("/Users/me/Developer/app").parent, "/Users/me/Developer/")
        XCTAssertEqual(R.splitPath("app").name, "app")
    }
}
