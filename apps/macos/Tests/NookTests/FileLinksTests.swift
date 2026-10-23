import XCTest

final class FileLinksTests: XCTestCase {
    func testPathWithLineAndColumn() {
        XCTAssertEqual(FileLink.parse("src/app.swift:12:3"), FileTarget(path: "src/app.swift", line: 12, column: 3))
        XCTAssertEqual(FileLink.parse("README.md:4"), FileTarget(path: "README.md", line: 4, column: nil))
        XCTAssertEqual(FileLink.parse("./a/b.ts"), FileTarget(path: "./a/b.ts", line: nil, column: nil))
    }

    func testGitHubAnchorsAndFileURLs() {
        XCTAssertEqual(FileLink.parse("/repo/a.swift#L20"), FileTarget(path: "/repo/a.swift", line: 20, column: nil))
        XCTAssertEqual(FileLink.parse("a.swift#L20C5"), FileTarget(path: "a.swift", line: 20, column: 5))
        XCTAssertEqual(FileLink.parse("a.swift#L20-L30"), FileTarget(path: "a.swift", line: 20, column: nil))
        XCTAssertEqual(FileLink.parse("file:///Users/me/My%20App/x.swift"), FileTarget(path: "/Users/me/My App/x.swift"))
    }

    func testWebAndOtherLinksAreNotFiles() {
        XCTAssertNil(FileLink.parse("https://example.com/a.swift"))
        XCTAssertNil(FileLink.parse("mailto:me@example.com"))
        XCTAssertNil(FileLink.parse("localhost:3000"))
        XCTAssertNil(FileLink.parse("#section"))
        XCTAssertNil(FileLink.parse(""))
        XCTAssertNil(FileLink.parse("a.swift:0"))
    }

    func testResolvingAgainstTheSessionFolder() {
        let target = FileLink.parse("../lib/x.swift:3")!
        XCTAssertEqual(FileLink.resolve(target, base: "/repo/app")?.path, "/repo/lib/x.swift")
        XCTAssertEqual(FileLink.resolve(target, base: "/repo/app")?.line, 3)
        XCTAssertNil(FileLink.resolve(target, base: nil))
        XCTAssertEqual(FileLink.resolve(FileTarget(path: "~/n.txt"), base: nil, home: "/Users/me")?.path, "/Users/me/n.txt")
        XCTAssertEqual(FileLink.resolve(FileTarget(path: "/abs/y"), base: nil)?.path, "/abs/y")
    }

    func testEditorLaunchStyles() {
        let target = FileTarget(path: "/r/a.swift", line: 12, column: 3)
        XCTAssertEqual(EditorLaunch.plan(bundleID: "com.microsoft.VSCode", appPath: "/Applications/Visual Studio Code.app",
                                         executable: "Electron", target: target),
                       .process(executable: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                                arguments: ["--goto", "/r/a.swift:12:3"]))
        XCTAssertEqual(EditorLaunch.plan(bundleID: "dev.zed.Zed", appPath: "/Applications/Zed.app", executable: "zed", target: target),
                       .process(executable: "/Applications/Zed.app/Contents/MacOS/cli", arguments: ["/r/a.swift:12:3"]))
        XCTAssertEqual(EditorLaunch.plan(bundleID: "com.apple.dt.Xcode", appPath: "/Applications/Xcode.app", executable: "Xcode", target: target),
                       .process(executable: "/usr/bin/xed", arguments: ["--line", "12", "/r/a.swift"]))
        // JetBrains counts columns from 0.
        XCTAssertEqual(EditorLaunch.plan(bundleID: "com.jetbrains.intellij", appPath: "/Applications/IntelliJ IDEA.app/",
                                         executable: "idea", target: target),
                       .process(executable: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea",
                                arguments: ["--line", "12", "--column", "2", "/r/a.swift"]))
    }

    func testEditorWithoutPositionOrToolOpensTheApp() {
        XCTAssertEqual(EditorLaunch.plan(bundleID: "com.microsoft.VSCode", appPath: "/A.app", executable: nil,
                                         target: FileTarget(path: "/r/a.swift")), .open)
        XCTAssertEqual(EditorLaunch.plan(bundleID: "com.example.Unknown", appPath: "/A.app", executable: "x",
                                         target: FileTarget(path: "/r/a.swift", line: 2)), .open)
    }
}
