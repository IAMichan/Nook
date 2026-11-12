import XCTest

/// A CLIProxyAPI hub as a source of limits: which addresses Nook accepts (the management key goes there), how a hub's
/// `auth-files` reply is read, and which windows the rate limit headers it saw carry.
final class CLIProxyHubTests: XCTestCase {
    // MARK: Address

    func testBaseAcceptsHubAddressesAndDropsThePanelPage() {
        XCTAssertEqual(try? CLIProxyHub.base("http://127.0.0.1:8317").get().absoluteString, "http://127.0.0.1:8317/")
        XCTAssertEqual(try? CLIProxyHub.base("http://127.0.0.1:8317/management.html").get().absoluteString, "http://127.0.0.1:8317/")
        XCTAssertEqual(try? CLIProxyHub.base("https://hub.example.com/proxy/").get().absoluteString, "https://hub.example.com/proxy/")
        XCTAssertEqual(try? CLIProxyHub.base("localhost:8317").get().absoluteString, "http://localhost:8317/",
                       "no scheme: a local address is plain http")
        XCTAssertEqual(try? CLIProxyHub.base("https://hub.example.com/?key=1#x").get().absoluteString, "https://hub.example.com/",
                       "no query or fragment")
    }

    func testBaseRefusesWhatWouldSendTheKeyInTheClear() {
        XCTAssertEqual(CLIProxyHub.base("http://hub.example.com").failure, .insecure)
        XCTAssertEqual(CLIProxyHub.base("http://8.8.8.8:8317").failure, .insecure)
        XCTAssertEqual(CLIProxyHub.base("http://172.32.0.1").failure, .insecure, "172.32 is outside the private range")
        XCTAssertNil(CLIProxyHub.base("http://192.168.1.20:8317").failure)
        XCTAssertNil(CLIProxyHub.base("http://172.20.0.5:8317").failure)
        XCTAssertNil(CLIProxyHub.base("http://mac-mini.local:8317").failure)
    }

    func testBaseRefusesWhatIsNotAWebAddress() {
        XCTAssertEqual(CLIProxyHub.base("").failure, .invalid)
        XCTAssertEqual(CLIProxyHub.base("ftp://hub.example.com").failure, .invalid)
        XCTAssertEqual(CLIProxyHub.base("https://user:secret@hub.example.com").failure, .invalid, "no credentials in the address")
    }

    func testManagementURLSitsUnderTheBase() {
        let base = URL(string: "https://hub.example.com/proxy/")!
        XCTAssertEqual(CLIProxyHub.managementURL(base, path: "auth-files")?.absoluteString,
                       "https://hub.example.com/proxy/v0/management/auth-files")
    }

    func testNameFallsBackToTheHost() {
        XCTAssertEqual(CLIProxyHub(id: "a", label: "Server", url: "http://127.0.0.1:8317").name, "Server")
        XCTAssertEqual(CLIProxyHub(id: "a", label: "  ", url: "http://127.0.0.1:8317").name, "127.0.0.1")
        XCTAssertEqual(CLIProxyHub(id: "abc", label: "", url: "").secretAccount, "cliproxy.hub.abc")
    }

    // MARK: Reply

    private func reply(_ files: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["observed_at": "2026-11-12T13:50:52Z", "files": files])
    }

    func testAccountsAreReadFromAuthFiles() throws {
        let data = reply([[
            "id": "claude-6f85b165-me@example.com.json", "provider": "Claude", "email": "me@example.com",
            "label": "me@example.com", "account": "me@example.com", "status": "active", "disabled": false,
            "unavailable": false, "success": 12, "failed": 1, "cooldowns": [], "quota": ["signals": [:] as [String: Any]],
        ]])
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(data))
        XCTAssertEqual(accounts.count, 1)
        let account = accounts[0]
        XCTAssertEqual(account.provider, "claude", "provider names are lowercase")
        XCTAssertEqual(account.name, "me@example.com")
        XCTAssertEqual(account.succeeded, 12)
        XCTAssertEqual(account.failed, 1)
        XCTAssertTrue(account.isAvailable())
        XCTAssertTrue(account.windows().isEmpty, "no request went through the hub yet: no limits")
        XCTAssertNil(account.retryAt)
    }

    func testAnUnreadableReplyIsNotAHubReply() {
        XCTAssertNil(CLIProxyReply.accounts(Data("<html>login</html>".utf8)))
        XCTAssertNil(CLIProxyReply.accounts(Data(#"{"error":"invalid management key"}"#.utf8)))
        XCTAssertEqual(CLIProxyReply.accounts(Data(#"{"files":[]}"#.utf8))?.count, 0)
    }

    func testACooldownHoldsTheAccountBackUntilItEnds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retry = NookDates.isoPlain.string(from: now.addingTimeInterval(1800))
        let later = NookDates.isoPlain.string(from: now.addingTimeInterval(3600))
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([[
            "id": "a", "provider": "codex", "status": "error", "unavailable": true, "next_retry_after": retry,
            "cooldowns": [["scope": "model", "reason": "quota", "retry_at": later, "remaining_seconds": 3600]],
        ]])))
        let account = accounts[0]
        XCTAssertFalse(account.isAvailable(now: now))
        XCTAssertEqual(account.retryAt, now.addingTimeInterval(3600), "the account is back when the last cooldown ends")
        XCTAssertTrue(account.isAvailable(now: now.addingTimeInterval(3601)))
    }

    func testADisabledAccountIsNeverAvailable() throws {
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([["id": "a", "provider": "claude", "disabled": true]])))
        XCTAssertFalse(accounts[0].isAvailable())
    }

    func testAZeroTimeFromTheHubMeansNever() throws {
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([[
            "id": "a", "provider": "claude", "unavailable": true, "next_retry_after": "0001-01-01T00:00:00Z",
        ]])))
        XCTAssertNil(accounts[0].retryAt)
    }

    func testAccountsWithoutAnIDAreSkipped() throws {
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([["provider": "claude"], ["id": "b"]])))
        XCTAssertEqual(accounts.map(\.id), ["b"])
    }

    // MARK: Windows

    func testClaudeHeadersGiveBothWindows() throws {
        let reset5 = 1_800_000_000.0
        let reset7 = 1_800_400_000.0
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([[
            "id": "a", "provider": "claude",
            "quota": ["signals": [
                "Anthropic-Ratelimit-Unified-5h-Utilization": "0.34", "anthropic-ratelimit-unified-5h-reset": "\(Int(reset5))",
                "anthropic-ratelimit-unified-7d-utilization": "12", "anthropic-ratelimit-unified-7d-reset": "\(Int(reset7))",
            ]],
        ]])))
        let windows = accounts[0].windows()
        XCTAssertEqual(windows.map(\.key), ["five_hour", "seven_day"])
        XCTAssertEqual(windows[0].usedPercent, 34, accuracy: 0.001, "a fraction is a share")
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: reset5))
        XCTAssertEqual(windows[0].duration, 5 * 3600)
        XCTAssertEqual(windows[1].usedPercent, 12, accuracy: 0.001, "above 1 it is already a percentage")
    }

    func testCodexHeadersAreSortedByTheLengthOfTheWindow() throws {
        let observed = NookDates.isoPlain.string(from: Date(timeIntervalSince1970: 1_800_000_000))
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([[
            "id": "a", "provider": "codex",
            "quota": ["observed_at": observed, "signals": [
                "x-codex-primary-used-percent": "90", "x-codex-primary-window-minutes": "300",
                "x-codex-primary-reset-after-seconds": "600",
                "x-codex-secondary-used-percent": "40", "x-codex-secondary-window-minutes": "10080",
            ]],
        ]])))
        let windows = accounts[0].windows()
        XCTAssertEqual(windows.map(\.key), ["five_hour", "seven_day"])
        XCTAssertEqual(windows[0].usedPercent, 90)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_600), "counted from when the hub saw it")
        XCTAssertNil(windows[1].resetsAt)
    }

    func testPercentagesStayInRange() throws {
        let accounts = try XCTUnwrap(CLIProxyReply.accounts(reply([[
            "id": "a", "provider": "codex", "quota": ["signals": ["x-codex-primary-used-percent": "140"]],
        ]])))
        XCTAssertEqual(accounts[0].windows().first?.usedPercent, 100)
        XCTAssertEqual(accounts[0].windows().first?.key, "other", "a window of unknown length is not claimed as either")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
