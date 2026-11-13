import XCTest

/// Secrets agents use without reading them: private files and their cleanup, the sudo helper's protocol, pasted secrets
/// in a composer, and 1Password references (with a fake `op`, so no process starts and nothing leaves this Mac).
final class SecretsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-secrets-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: Private files

    func testAFileHoldsExactlyTheValueAndOnlyYouCanReadIt() throws {
        let files = SecretFiles(root: root)
        let url = try files.write("sk-test-123", name: "STRIPE_KEY", scope: "run-1")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "sk-test-123", "no newline added")
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(root), 0o700)
        XCTAssertTrue(url.path.hasPrefix(root.path), "never outside Nook's own folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".partial"))
    }

    func testASecondDeliveryReplacesTheFirst() throws {
        let files = SecretFiles(root: root)
        _ = try files.write("old", name: "KEY", scope: "s")
        let url = try files.write("new", name: "KEY", scope: "s")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
    }

    func testANameOrScopeCannotClimbOutOfItsFolder() throws {
        let files = SecretFiles(root: root)
        for bad in ["../x", ".hidden", "a/b", "", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try files.write("v", name: bad, scope: "s"), bad)
        }
        XCTAssertEqual(SecretFiles.scope("../../etc"), "______etc")
        XCTAssertEqual(SecretFiles.scope(""), "_")
        let url = try files.write("v", name: "KEY", scope: "../../etc")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().path, root.path)
    }

    func testAFolderThatIsALinkIsRefused() throws {
        let files = SecretFiles(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("nook-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("planted"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try files.write("v", name: "KEY", scope: "planted")) { error in
            XCTAssertEqual(error as? SecretFiles.Failure, .unsafeFolder)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testFilesGoWithTheirSessionAtQuitAndAfterADay() throws {
        let files = SecretFiles(root: root)
        let a = try files.write("1", name: "A", scope: "run-a")
        let b = try files.write("2", name: "B", scope: "run-b")
        files.remove(scope: "run-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))

        // Not yet a day old: kept, and the sweep says when it runs out.
        let next = files.sweep(now: Date())
        XCTAssertNotNil(next)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        let later = Date().addingTimeInterval(SecretFiles.lifetime + 60)
        XCTAssertNil(files.sweep(now: later))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path), "empty folder goes too")

        _ = try files.write("3", name: "C", scope: "run-c")
        files.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testTheAgentGetsThePathNeverTheValue() {
        let text = SecretFiles.instructions(name: "OPENAI_API_KEY", path: "/Users/me/Library/Application Support/Nook/agent-secrets/x/OPENAI_API_KEY")
        XCTAssertTrue(text.contains("$(cat '/Users/me/Library/Application Support/Nook/agent-secrets/x/OPENAI_API_KEY')"))
        XCTAssertTrue(text.contains("OPENAI_API_KEY"))
        let quoted = SecretFiles.instructions(name: "K", path: "/tmp/it's")
        XCTAssertTrue(quoted.contains(#"'/tmp/it'\''s'"#), "a quote in the path stays inside the shell word")
    }

    func testAFolderScopeIsStableAndHidesThePath() {
        XCTAssertEqual(SecretFiles.folderScope("/Users/me/project"), SecretFiles.folderScope("/Users/me/project"))
        XCTAssertNotEqual(SecretFiles.folderScope("/Users/me/a"), SecretFiles.folderScope("/Users/me/b"))
        XCTAssertFalse(SecretFiles.folderScope("/Users/me/project").contains("project"))
    }

    func testAPastedSecretReachesTheAgentAsAPath() {
        let path = "/Users/me/Library/Application Support/Nook/agent-secrets/composer/GITHUB_TOKEN"
        let link = ContextRefs.link(ContextRef(kind: .secret, id: path, label: "GITHUB_TOKEN"))
        let sent = ContextRefs.project("Use \(link) to push", excerpts: [:])
        XCTAssertTrue(sent.hasPrefix("Use [GITHUB_TOKEN] to push"))
        XCTAssertTrue(sent.contains("<ref kind=\"secret\""))
        XCTAssertTrue(sent.contains("$(cat '\(path)')"))
        XCTAssertEqual(ContextRefs.plainText(ContextRef(kind: .secret, id: path, label: "GITHUB_TOKEN")), "GITHUB_TOKEN")
    }

    // MARK: request_secret arguments

    func testDeliveryIsAFileUnlessTheValueIsAskedFor() {
        XCTAssertEqual(BridgeSecret.delivery(nil), .file)
        XCTAssertEqual(BridgeSecret.delivery(""), .file)
        XCTAssertEqual(BridgeSecret.delivery("file"), .file)
        XCTAssertEqual(BridgeSecret.delivery("VALUE"), .value)
        XCTAssertNil(BridgeSecret.delivery("env"))
        XCTAssertNil(BridgeSecret.delivery(1))
    }

    func testASignInLinkIsAPlainWebAddress() {
        XCTAssertEqual(BridgeSecret.signInURL("https://dashboard.stripe.com/apikeys")?.host, "dashboard.stripe.com")
        XCTAssertNotNil(BridgeSecret.signInURL("http://localhost:3000/keys"))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pw@example.com", "ftp://x.com", "not a url",
                    "https://" + String(repeating: "a", count: 2_001)] {
            XCTAssertNil(BridgeSecret.signInURL(bad), bad)
        }
        XCTAssertNil(BridgeSecret.signInURL(nil))
    }

    // MARK: sudo helper

    func testTheHelperRequestIsReadAndFlattened() {
        let request = SudoAskpass.request(in: ["agent": "askpass", "askpass": ["prompt": "Password:\nfake", "command": "sudo -A make install"]])
        XCTAssertEqual(request, SudoAskpass.Request(prompt: "Password: fake", command: "sudo -A make install"))
        XCTAssertNil(SudoAskpass.request(in: ["message": [:]]), "an MCP message is not a sudo request")
        let long = SudoAskpass.request(in: ["askpass": ["command": String(repeating: "x", count: 5_000)]])
        XCTAssertEqual(long?.command.count, 2_001)
    }

    func testTheCardSaysWhatThePasswordIsFor() {
        XCTAssertEqual(SudoAskpass.purpose(of: "sudo -A make install").command, "make install")
        XCTAssertEqual(SudoAskpass.purpose(of: "/usr/bin/sudo -A -u root -E brew services start x").command,
                       "brew services start x")
        XCTAssertEqual(SudoAskpass.purpose(of: "sudo -A -- rm -rf /tmp/x").command, "rm -rf /tmp/x")
        for check in ["sudo -A true", "sudo -A -v", "sudo -A -l", "sudo -A", ""] {
            XCTAssertTrue(SudoAskpass.purpose(of: check).isCheck, check)
        }
        XCTAssertEqual(SudoAskpass.purpose(of: "make install").command, "make install", "not sudo: shown as it is")
    }

    func testTheReplyCarriesTheValueOrADecline() {
        XCTAssertEqual(SudoAskpass.value(inReply: SudoAskpass.reply("hunter2")), "hunter2")
        XCTAssertNil(SudoAskpass.value(inReply: SudoAskpass.reply(nil)))
        XCTAssertNil(SudoAskpass.value(inReply: Data(#"{"ok":true,"value":""}"#.utf8)))
        XCTAssertNil(SudoAskpass.value(inReply: Data("garbage".utf8)))
    }

    func testTheHelperIsInstalledPrivatelyAndGivenToSessions() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("nook-askpass")
        XCTAssertEqual(SudoAskpass.launchEnvironment(at: url), [:], "no helper, no variable")
        try SudoAskpass.install(at: url)
        XCTAssertEqual(try mode(url), 0o700)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), SudoAskpass.contents)
        XCTAssertEqual(SudoAskpass.launchEnvironment(at: url), ["SUDO_ASKPASS": url.path])
    }

    func testTheHelperFailsLikeAWrongPasswordWithoutNook() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try SudoAskpass.install(at: root.appendingPathComponent("nook-askpass"))
        let process = Process()
        process.executableURL = url
        process.arguments = ["Password:"]
        process.environment = ["HOME": root.path, "NOOK_BRIDGE_SOCK": root.appendingPathComponent("missing.sock").path,
                               "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(out.fileHandleForReading.readDataToEndOfFile().isEmpty, "nothing on stdout, so sudo gets no password")
    }

    // MARK: Pasted secrets

    func testKnownKeysArePickedOut() {
        let cases: [(String, String)] = [
            ("sk-ant-api03-" + String(repeating: "aB3", count: 10), "ANTHROPIC_API_KEY"),
            ("sk-proj-" + String(repeating: "Xy9", count: 12), "OPENAI_API_KEY"),
            ("ghp_" + String(repeating: "a1B2", count: 9), "GITHUB_TOKEN"),
            ("AKIAIOSFODNN7EXAMPLE", "AWS_ACCESS_KEY_ID"),
            ("sk_live_" + String(repeating: "4eC3", count: 6), "STRIPE_SECRET_KEY"),
            ("xoxb-1234567890-abcdefghij", "SLACK_TOKEN"),
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "JWT")
        ]
        for (key, name) in cases {
            let text = "here it is: \(key) thanks"
            let found = SecretPasteDetector.matches(in: text)
            XCTAssertEqual(found.map(\.name), [name], key)
            XCTAssertEqual(found.first.map { String(text[$0.range]) }, key)
        }
    }

    func testAPrivateKeyAndAnAssignmentArePickedOut() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(SecretPasteDetector.matches(in: "key:\n" + pem).map(\.name), ["PRIVATE_KEY"])
        let env = "DATABASE_PASSWORD=Zx81kQ0pLm2Vb7Rt"
        let found = SecretPasteDetector.matches(in: env)
        XCTAssertEqual(found.map(\.name), ["DATABASE_PASSWORD"])
        XCTAssertEqual(found.first.map { String(env[$0.range]) }, "Zx81kQ0pLm2Vb7Rt", "the name stays in the message")
    }

    func testALoneRandomTokenIsPickedOut() {
        let found = SecretPasteDetector.matches(in: "  q8Jr2LmZ0vXe7TbN4yKc1WpA9sDf3GhU  ")
        XCTAssertEqual(found.map(\.name), ["PASTED_SECRET"])
    }

    func testOrdinaryPastesAreLeftAlone() {
        let quiet = [
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "5dab746b0356d555c1a2b3c4d5e6f7a8b9c0d1e2",
            "9F2C1D6E-3B4A-4C5D-8E7F-1A2B3C4D5E6F",
            "/Users/michan/Library/Application Support/Nook/agent-secrets",
            "https://github.com/IAMichan/nook/pull/1244",
            "handle_secret_paste_for_composer_view_model",
            "Please fix the login bug and add a test for the token refresh.",
            "michan@example.com",
            "TOKEN=short",
            "let apiKey = config.value(forKey: \"apiKey\")"
        ]
        for text in quiet { XCTAssertEqual(SecretPasteDetector.matches(in: text), [], text) }
    }

    func testNamesStayUnique() {
        XCTAssertEqual(SecretPasteDetector.uniqueName("KEY", taken: []), "KEY")
        XCTAssertEqual(SecretPasteDetector.uniqueName("KEY", taken: ["KEY", "KEY_2"]), "KEY_3")
    }

    // MARK: 1Password

    func testReferencesAreParsedStrictly() {
        let plain = SecretReference("op://Private/Stripe/credential")
        XCTAssertEqual(plain?.vault, "Private")
        XCTAssertEqual(plain?.item, "Stripe")
        XCTAssertNil(plain?.section)
        XCTAssertEqual(plain?.field, "credential")
        let full = SecretReference(" op://Work Vault/GitHub/Tokens/ci token?attribute=otp ")
        XCTAssertEqual(full?.section, "Tokens")
        XCTAssertEqual(full?.text, "op://Work Vault/GitHub/Tokens/ci token?attribute=otp")
        for bad in ["op://vault/item", "op://a/b/c/d/e", "op://a//c", "op://a/b/$(rm -rf ~)", "op://a/b/c?x", "sk-123",
                    "op://a/b/c\"", "op:/a/b/c"] {
            XCTAssertNil(SecretReference(bad), bad)
        }
    }

    private final class FakeOp: @unchecked Sendable {
        var calls: [(arguments: [String], environment: [String: String], removed: [String])] = []
        var output: OnePassword.Output? = OnePassword.Output(status: 0, stdout: Data("s3cret".utf8), stderr: "")
        var runner: OnePassword.Runner {
            { _, arguments, environment, removed, _ in
                self.calls.append((arguments, environment, removed))
                return self.output
            }
        }
    }

    func testAReferenceIsReadWithOpRead() async throws {
        let fake = FakeOp()
        let config = OnePassword.Config(executable: "/opt/homebrew/bin/op")
        let value = try await OnePassword.resolve("op://Private/Stripe/credential", config: config, runner: fake.runner)
        XCTAssertEqual(value, "s3cret")
        XCTAssertEqual(fake.calls.first?.arguments, ["read", "--no-newline", "op://Private/Stripe/credential"])
        XCTAssertEqual(fake.calls.first?.environment, [:], "the desktop app: no token")
        XCTAssertEqual(Set(fake.calls.first?.removed ?? []), ["OP_SERVICE_ACCOUNT_TOKEN", "OP_CONNECT_HOST", "OP_CONNECT_TOKEN"])
        let literal = try await OnePassword.resolve("plain-value", config: config, runner: fake.runner)
        XCTAssertEqual(literal, "plain-value")
        XCTAssertEqual(fake.calls.count, 1, "a plain value never runs op")
    }

    func testTheConfiguredSignInGoesToOp() {
        let service = OnePassword.Config(executable: "op", serviceAccountToken: "ops_x", connectHost: "https://c", connectToken: "t")
        XCTAssertEqual(service.mode, .serviceAccount, "op refuses both; the service account wins")
        XCTAssertEqual(service.environment.set, ["OP_SERVICE_ACCOUNT_TOKEN": "ops_x"])
        let connect = OnePassword.Config(executable: "op", connectHost: "https://c", connectToken: "t")
        XCTAssertEqual(connect.mode, .connect)
        XCTAssertEqual(connect.environment.set, ["OP_CONNECT_HOST": "https://c", "OP_CONNECT_TOKEN": "t"])
        XCTAssertEqual(OnePassword.Config(executable: "op", connectHost: "https://c").mode, .desktop, "a host without token")
    }

    func testOpFailuresSayWhyWithoutAValue() async {
        let fake = FakeOp()
        let config = OnePassword.Config(executable: "op")
        fake.output = OnePassword.Output(status: 1, stdout: Data(),
                                         stderr: "[ERROR] 2026/11/10 10:00:00 \"Stripe\" isn't an item in the \"Private\" vault\n")
        do {
            _ = try await OnePassword.resolve("op://Private/Stripe/credential", config: config, runner: fake.runner)
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? OnePassword.Failure, .refused("\"Stripe\" isn't an item in the \"Private\" vault"))
        }
        fake.output = nil
        await XCTAssertThrowsAsync(try await OnePassword.resolve("op://a/b/c", config: config, runner: fake.runner), .timedOut)
        fake.output = OnePassword.Output(status: 0, stdout: Data(), stderr: "")
        await XCTAssertThrowsAsync(try await OnePassword.resolve("op://a/b/c", config: config, runner: fake.runner), .empty)
        await XCTAssertThrowsAsync(try await OnePassword.resolve("op://a/b/c", config: OnePassword.Config(executable: nil),
                                                                 runner: fake.runner), .notInstalled)
    }

    func testTheTestButtonAsksWhoAmI() async throws {
        let fake = FakeOp()
        fake.output = OnePassword.Output(status: 0, stdout: Data("URL: https://my.1password.com\nEmail: me@example.com\n".utf8), stderr: "")
        let account = try await OnePassword.check(config: OnePassword.Config(executable: "op"), probe: nil, runner: fake.runner)
        XCTAssertEqual(account, "URL: https://my.1password.com")
        XCTAssertEqual(fake.calls.last?.arguments, ["whoami"])
        fake.output = OnePassword.Output(status: 0, stdout: Data("v".utf8), stderr: "")
        _ = try await OnePassword.check(config: OnePassword.Config(executable: "op"), probe: SecretReference("op://a/b/c"),
                                        runner: fake.runner)
        XCTAssertEqual(fake.calls.last?.arguments, ["read", "--no-newline", "op://a/b/c"])
    }

    private func XCTAssertThrowsAsync(_ expression: @autoclosure () async throws -> String, _ expected: OnePassword.Failure,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("should throw \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OnePassword.Failure, expected, file: file, line: line)
        }
    }
}
