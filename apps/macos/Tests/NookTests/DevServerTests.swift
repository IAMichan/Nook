import XCTest

/// Finding a session's dev servers from `lsof` output.
final class DevServerTests: XCTestCase {
    func testListenersOnePerPortSkippingDatabases() {
        let output = "p501\ncnode\nn*:5173\nn[::1]:5173\np777\ncpostgres\nn127.0.0.1:5432\np900\ncruby\nn127.0.0.1:3000\n"
        let servers = DevServerScanner.parseListeners(output)
        XCTAssertEqual(servers.map(\.port), [3000, 5173])
        XCTAssertEqual(servers.last?.command, "node")
        XCTAssertEqual(servers.last?.pid, 501)
        XCTAssertEqual(servers.first?.url.absoluteString, "http://localhost:3000")
    }

    func testFolders() {
        XCTAssertEqual(DevServerScanner.parseFolders("p501\nfcwd\nn/Users/x/app\np900\nfcwd\nn/Users/x/other\n"),
                       [501: "/Users/x/app", 900: "/Users/x/other"])
    }

    func testOnlyPagesCountAsWebServers() {
        XCTAssertTrue(DevServerProbe.isWebPage(status: 200, contentType: "text/html; charset=utf-8", location: nil))
        XCTAssertTrue(DevServerProbe.isWebPage(status: 200, contentType: "application/xhtml+xml", location: nil))
        XCTAssertTrue(DevServerProbe.isWebPage(status: 302, contentType: nil, location: "/login"))
        XCTAssertFalse(DevServerProbe.isWebPage(status: 301, contentType: nil, location: nil))
        XCTAssertFalse(DevServerProbe.isWebPage(status: 200, contentType: "application/json", location: nil))
        XCTAssertFalse(DevServerProbe.isWebPage(status: 204, contentType: "text/html", location: nil))
        XCTAssertFalse(DevServerProbe.isWebPage(status: 404, contentType: "text/html", location: nil))
    }
}
