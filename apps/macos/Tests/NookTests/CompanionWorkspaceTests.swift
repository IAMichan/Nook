import XCTest

final class CompanionWorkspaceTests: XCTestCase {
    private let same: (String) -> String = { $0 }

    func testSecretsStayByName() {
        for name in [".env", ".env.local", ".git", "id_rsa", "id_ed25519.pub", "server.pem", "api.KEY", ".npmrc"] {
            XCTAssertTrue(CompanionWorkspace.isSecret(name), name)
        }
        for name in [".env.example", "README.md", "keyboard.swift", "environment.ts"] {
            XCTAssertFalse(CompanionWorkspace.isSecret(name), name)
        }
    }

    func testAPathStaysInItsFolder() {
        XCTAssertEqual(CompanionWorkspace.path("src/a.swift", in: "/repo", resolve: same), "/repo/src/a.swift")
        XCTAssertEqual(CompanionWorkspace.path("", in: "/repo", resolve: same), "/repo")
        XCTAssertNil(CompanionWorkspace.path("../etc/passwd", in: "/repo", resolve: same))
        XCTAssertNil(CompanionWorkspace.path("/etc/passwd", in: "/repo", resolve: same))
        XCTAssertNil(CompanionWorkspace.path("config/.env", in: "/repo", resolve: same))
        XCTAssertNil(CompanionWorkspace.path(".git/config", in: "/repo", resolve: same))
    }

    func testALinkCannotLeaveOrHideASecret() {
        let out: (String) -> String = { $0 == "/repo/link" ? "/etc/passwd" : $0 }
        XCTAssertNil(CompanionWorkspace.path("link", in: "/repo", resolve: out))
        let hidden: (String) -> String = { $0 == "/repo/config" ? "/repo/.env" : $0 }
        XCTAssertNil(CompanionWorkspace.path("config", in: "/repo", resolve: hidden))
        XCTAssertNil(CompanionWorkspace.path("x", in: "/repo2", resolve: { $0 == "/repo2/x" ? "/repo2-other/x" : $0 }))
    }

    func testFiles() {
        XCTAssertEqual(CompanionWorkspace.digest(path: "a", data: Data("hi".utf8)).text, "hi")
        XCTAssertEqual(CompanionWorkspace.digest(path: "a", data: Data([0, 1, 2])).binary, true)
        let big = CompanionWorkspace.digest(path: "a", data: Data(count: 0) + Data(repeating: 65, count: CompanionWorkspace.maxTextBytes + 1))
        XCTAssertEqual(big.truncated, true)
        XCTAssertEqual(big.text?.utf8.count, CompanionWorkspace.maxTextBytes)
    }

    func testListingsPutFoldersFirstAndDropSecrets() {
        let digest = CompanionWorkspace.listing(path: "", entries: [
            .init(name: "b.txt", isFolder: false, size: 1), .init(name: "src", isFolder: true, size: nil),
            .init(name: ".env", isFolder: false, size: 1), .init(name: "a.txt", isFolder: false, size: 1)
        ])
        XCTAssertEqual(digest.entries?.map(\.name), ["src", "a.txt", "b.txt"])
    }

    func testASecretFolderIsNoSessionRoot() {
        XCTAssertNil(CompanionWorkspace.path("credentials", in: "/Users/a/.aws", resolve: same))
        XCTAssertNil(CompanionWorkspace.path("", in: "/Users/a/.ssh", resolve: same))
    }

    func testAnswersFitAFrame() throws {
        let tabs = String(repeating: "\t", count: CompanionWorkspace.maxTextBytes)
        let digest = CompanionWorkspace.digest(path: "a", data: Data(tabs.utf8))
        XCTAssertEqual(digest.truncated, true)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(digest.text ?? "").count, CompanionWorkspace.maxEncodedBytes)
        // A cut inside a four-byte character still reads as text.
        let emoji = String(repeating: "😀", count: CompanionWorkspace.maxTextBytes / 4 + 2)
        XCTAssertNotNil(CompanionWorkspace.digest(path: "a", data: Data(("a" + emoji).utf8)).text)
        let many = (0..<5).map { TerminalDigest(id: "\($0)", title: "t", running: true, output: String(repeating: "x", count: 150_000)) }
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(CompanionWorkspace.fitting(many)).count, CompanionWorkspace.maxEncodedBytes + 64)
    }

    func testBothNeedTheRightToOperate() {
        XCTAssertEqual(CompanionScopes.table[.files], .scope(.operate))
        XCTAssertEqual(CompanionScopes.table[.terminals], .scope(.operate))
    }

    func testTheyAreRedactedWithoutThatRight() {
        var response = CompanionResponse(id: "a", ok: true)
        response.terminals = []
        response.folder = FolderDigest(path: "")
        let redacted = CompanionScopes.redact(response, granted: [.read])
        XCTAssertNil(redacted.terminals)
        XCTAssertNil(redacted.folder)
    }
}
