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

    func testWellKnownPlacesInsOrder() throws {
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

    func testNothingAndLinksOutsideTheProject() throws {
        XCTAssertNil(ProjectFavicon.find(in: root.path))
        XCTAssertNil(ProjectFavicon.iconHref(in: #"<link rel="icon" href="https://cdn.example.com/f.ico">"#))
        XCTAssertEqual(ProjectFavicon.iconHref(in: #"<link href="/f.png" rel="shortcut icon">"#), "/f.png")
        XCTAssertEqual(ProjectFavicon.iconHref(in: #"links: [{ rel: "icon", href: "/favicon.svg" }]"#), "/favicon.svg")
    }
}
