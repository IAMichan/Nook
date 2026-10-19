import XCTest

/// Antigravity over ACP.
final class AntigravityTests: XCTestCase {
    private let goodURL = "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&response_type=code&state=abc123&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2F&scope=openid"

    func testReleasePins() throws {
        let arm = try XCTUnwrap(AntigravityRelease.asset(arch: "arm64"))
        XCTAssertEqual(arm.url.host, "dl.google.com")
        XCTAssertEqual(arm.sha256.count, 64)
        XCTAssertEqual(arm.archiveBytes, 111_456_962)
        XCTAssertNotNil(AntigravityRelease.asset(arch: "x86_64"))
        XCTAssertNil(AntigravityRelease.asset(arch: "ppc"))
        XCTAssertTrue(AntigravityRelease.verify([arm.executable, arm.harness], asset: arm))
        XCTAssertFalse(AntigravityRelease.verify([arm.executable], asset: arm), "both files must be there")
        XCTAssertFalse(AntigravityRelease.verify([arm.executable, .init(name: arm.harness.name, bytes: 1)], asset: arm), "sizes must match")
        XCTAssertFalse(AntigravityRelease.verify([arm.executable, arm.harness, .init(name: "extra", bytes: 1)], asset: arm))
    }

    func testSignInURLChecks() {
        XCTAssertEqual(AntigravityAcp.signInURL(inLine: AntigravityAcp.signInPrefix + goodURL)?.host, "accounts.google.com")
        XCTAssertNil(AntigravityAcp.signInURL(inLine: "something else " + goodURL), "only the server's own sign-in line")
        XCTAssertNil(AntigravityAcp.validSignInURL(goodURL.replacingOccurrences(of: "accounts.google.com", with: "evil.example")))
        XCTAssertNil(AntigravityAcp.validSignInURL(goodURL.replacingOccurrences(of: "127.0.0.1%3A50123", with: "example.com")),
                     "the answer must go to the server's loopback port")
        XCTAssertNil(AntigravityAcp.validSignInURL(goodURL.replacingOccurrences(of: "50123", with: "80")), "no privileged port")
        XCTAssertNil(AntigravityAcp.validSignInURL(goodURL.replacingOccurrences(of: "response_type=code", with: "response_type=token")))
        XCTAssertNil(AntigravityAcp.validSignInURL(goodURL + "&state=two"), "exactly one state")
    }

    func testEnvironmentAndMode() {
        let env = AntigravityAcp.environment(profile: "/p", harness: "/h/localharness_external", browserHelper: "/Users/a b/open.sh", temp: "/t")
        XCTAssertEqual(env["GEMINI_HOME"], "/p")
        XCTAssertEqual(env["AGY_ACP_FORCE_FILE_STORAGE"], "1")
        XCTAssertEqual(env["ANTIGRAVITY_HARNESS_PATH"], "/h/localharness_external")
        XCTAssertEqual(env["BROWSER"], "'/Users/a b/open.sh' %s", "a path with a space stays one command")
        XCTAssertTrue(AntigravityAcp.removedEnvironment.contains("GEMINI_API_KEY"))
        XCTAssertEqual(AntigravityAcp.mode(.agent, permission: .bypass), "yolo")
        XCTAssertEqual(AntigravityAcp.mode(.agent, permission: .acceptEdits), "auto_edit")
        XCTAssertEqual(AntigravityAcp.mode(.agent, permission: .ask), "default")
        XCTAssertEqual(AntigravityAcp.mode(.plan, permission: .bypass), "plan")
        XCTAssertTrue(AntigravityAcp.looksInstalled(["agentInfo": ["name": "antigravity-acp", "version": "1.3.0"],
                                                     "authMethods": [["id": "oauth-personal", "name": "Google"]]]))
        XCTAssertFalse(AntigravityAcp.looksInstalled(["agentInfo": ["name": "other"], "authMethods": [["id": "oauth-personal"]]]))
        XCTAssertEqual(RunProvider.antigravity.usesACP, true)
        XCTAssertEqual(AcpLaunch.arguments(.antigravity, permission: .bypass), [])
    }

    func testInstalledOnlyWhenComplete() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("nook-agy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AntigravityPaths(support: support)
        let asset = try XCTUnwrap(AntigravityRelease.asset(arch: "arm64"))
        XCTAssertNil(paths.installed(asset))
        let folder = paths.release(asset)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent(asset.executable.name)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: ["releaseId": asset.sha256]).write(to: paths.active(asset))
        XCTAssertNil(paths.installed(asset), "the harness is missing")
        try Data().write(to: folder.appendingPathComponent(asset.harness.name))
        XCTAssertEqual(paths.installed(asset)?.executable, executable.path)
        try JSONSerialization.data(withJSONObject: ["releaseId": "other"]).write(to: paths.active(asset))
        XCTAssertNil(paths.installed(asset), "another release is not this one")
        XCTAssertTrue(paths.profile("antigravity:werk/x").lastPathComponent == "antigravity_werk_x")
    }

    func testRemovedEnvironmentReachesTheProcess() throws {
        var spec = LaunchSpec(executable: "/usr/bin/env", arguments: [], extraEnvironment: ["KEEP": "1"], workingDirectory: "/tmp",
                              initialInput: [], keepsInputOpen: false)
        spec.removedEnvironment = ["GEMINI_API_KEY"]
        let process = AgentProcess(spec: spec)
        let output = LinesBox()
        let done = expectation(description: "exit")
        process.onLines = { output.add($0) }
        process.onExit = { _, _ in done.fulfill() }
        try process.start(baseEnvironment: ["GEMINI_API_KEY": "geheim", "PATH": "/usr/bin:/bin"])
        wait(for: [done], timeout: 10)
        XCTAssertTrue(output.lines.contains("KEEP=1"))
        XCTAssertFalse(output.lines.contains { $0.hasPrefix("GEMINI_API_KEY=") }, "another Google key never reaches Antigravity")
    }
}

private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ more: [String]) { lock.withLock { storage += more } }
    var lines: [String] { lock.withLock { storage } }
}
