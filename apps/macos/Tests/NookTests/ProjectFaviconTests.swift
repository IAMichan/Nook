import XCTest

final class ProjectFaviconTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("favicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func touch(_ relative: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testWellKnownPlacesInOrder() throws {
        try touch("public/favicon.png")
        try touch("assets/logo.svg")
        XCTAssertEqual(ProjectFavicon.find(in: root.path), root.appendingPathComponent("public/favicon.png").path)
    }

    func testIconLinkedFromIndexHTML() throws {
        try touch("index.html", #"<head><link rel="icon" type="image/svg+xml" href="/brand/mark.svg"></head>"#)
        try touch("public/brand/mark.svg")
        XCTAssertEqual(ProjectFavicon.find(in: root.path), root.appendingPathComponent("public/brand/mark.svg").path)
    }

    func testMonorepoWebAppAndXcodeAppIcon() throws {
        try touch("apps/web/public/favicon.ico")
        XCTAssertEqual(ProjectFavicon.find(in: root.path), root.appendingPathComponent("apps/web/public/favicon.ico").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("apps"))
        try touch("App/Assets.xcassets/AppIcon.appiconset/icon-16.png", "a")
        try touch("App/Assets.xcassets/AppIcon.appiconset/icon-128.png", String(repeating: "a", count: 500))
        try touch("node_modules/x/AppIcon.appiconset/big.png", String(repeating: "a", count: 900))
        XCTAssertEqual(ProjectFavicon.find(in: root.path),
                       root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset/icon-128.png").path)
    }

    func testMonorepoPrefersTheAppNamedAfterTheRepository() throws {
        let repo = root.appendingPathComponent("Infaris-monorepo")
        try touch("Infaris-monorepo/apps/calendar/web/public/favicon.png")
        try touch("Infaris-monorepo/apps/infaris/web/public/favicon.ico")
        XCTAssertEqual(ProjectFavicon.find(in: repo.path), repo.appendingPathComponent("apps/infaris/web/public/favicon.ico").path)
        // A worktree of it: named after its branch, but under `worktrees/<repository>`.
        let worktree = URL(fileURLWithPath: "/x/worktrees/infaris-monorepo/fix-dashboard-12ab")
        XCTAssertTrue(ProjectFavicon.repositoryNames(of: worktree).contains("infaris-monorepo"))
        XCTAssertFalse(ProjectFavicon.matches("qr", ["qr-monorepo"]))
    }

    func testSitesSideBySide() throws {
        try touch("bettr-finance/favicon.svg")
        try touch("node_modules/a/favicon.svg")
        XCTAssertEqual(ProjectFavicon.find(in: root.path), root.appendingPathComponent("bettr-finance/favicon.svg").path)
    }

    func testMacAppIconAndLargeAppIconSet() throws {
        try touch("apps/ios/Companion/Assets.xcassets/AppIcon.appiconset/AppIcon.png", String(repeating: "a", count: 300 * 1024))
        XCTAssertEqual(ProjectFavicon.find(in: root.path),
                       root.appendingPathComponent("apps/ios/Companion/Assets.xcassets/AppIcon.appiconset/AppIcon.png").path)
        // The Mac app's icon is nearer than the companion's set, so it wins.
        try touch("apps/macos/App/AppIcon.icns")
        XCTAssertEqual(ProjectFavicon.find(in: root.path), root.appendingPathComponent("apps/macos/App/AppIcon.icns").path)
    }

    func testNothingAndLinksOutsideTheProject() throws {
        XCTAssertNil(ProjectFavicon.find(in: root.path))
        XCTAssertNil(ProjectFavicon.iconHref(in: #"<link rel="icon" href="https://cdn.example.com/f.ico">"#))
        XCTAssertEqual(ProjectFavicon.iconHref(in: #"<link href="/f.png" rel="shortcut icon">"#), "/f.png")
        XCTAssertEqual(ProjectFavicon.iconHref(in: #"links: [{ rel: "icon", href: "/favicon.svg" }]"#), "/favicon.svg")
    }
}
