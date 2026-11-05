import XCTest

final class BrowserSessionTests: XCTestCase {
    private let one = UUID()
    private let other = UUID()

    func testTwoRunsInOneFolderHaveTheirOwnBrowser() {
        let first = BrowserSession(run: one, directory: "/tmp/project")
        let second = BrowserSession(run: other, directory: "/tmp/project")
        XCTAssertEqual(first.own, .run(one))
        XCTAssertEqual(second.own, .run(other))
        XCTAssertNotEqual(first.own, second.own)
    }

    func testARunNeverShowsTheBrowserOfAnotherRun() {
        let session = BrowserSession(run: one, directory: "/tmp/project")
        XCTAssertNil(session.key(among: [.run(other)]))
    }

    func testARunPrefersItsOwnBrowserOverItsFolders() {
        let session = BrowserSession(run: one, directory: "/tmp/project")
        let folder = BrowserSession(run: nil, directory: "/tmp/project").own!
        XCTAssertEqual(session.key(among: [folder, .run(one)]), .run(one))
        XCTAssertEqual(session.key(among: [folder]), folder)
    }

    func testAFolderDoesNotShowTheBrowserOfARunInIt() {
        let session = BrowserSession(run: nil, directory: "/tmp/project")
        XCTAssertNil(session.key(among: [.run(one)]))
    }

    func testNoSessionMeansNooksOwnBrowser() {
        XCTAssertNil(BrowserSession(run: nil, directory: "").own)
        XCTAssertEqual(BrowserSession(run: one, directory: "").keys, [.run(one)])
    }

    func testTheSameFolderWrittenDifferentlyIsOneSession() {
        XCTAssertEqual(BrowserSession(run: nil, directory: "/tmp/project/").own,
                       BrowserSession(run: nil, directory: "/tmp/project").own)
    }
}
