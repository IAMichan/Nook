import XCTest

final class McpStatusTests: XCTestCase {
    func testClaudeRows() {
        let rows: [[String: Any]] = [
            ["name": "claude.ai Gmail", "status": "connected"],
            ["name": "plugin:sales:close", "status": "needs-auth"],
            ["name": "plugin:sales:gmail", "status": "failed", "error": "No URL configured for this server"],
            ["name": "plugin:sales:slack", "status": "pending"],
            ["name": "off", "status": "disabled"],
            ["status": "connected"],
        ]
        let servers = McpStatus.claude(rows)
        XCTAssertEqual(servers.map(\.status), [.connected, .needsSignIn, .failed, .pending, .disabled])
        XCTAssertEqual(servers[2].error, "No URL configured for this server")
        XCTAssertEqual(servers[0].title, "Gmail")
        XCTAssertEqual(McpStatus.sorted(servers).map(\.status), [.failed, .needsSignIn, .pending, .connected, .disabled])
    }

    func testCodexRows() {
        let response: [String: Any] = ["data": [["name": "linear", "authStatus": "notLoggedIn"], ["name": "github", "authStatus": "oAuth"],
                                                ["name": "local", "authStatus": "unsupported"]]]
        XCTAssertEqual(McpStatus.codex(response).map(\.status), [.needsSignIn, .connected, .connected])
    }

    func testOpenCodeRows() {
        // As `GET /api/mcp` answers (OpenCode 2).
        let response: [String: Any] = ["location": ["directory": "/tmp"], "data": [
            ["name": "broken", "status": ["status": "failed", "error": "NotFound: ChildProcess.spawn (/nonexistent )"]],
            ["name": "remote", "status": ["status": "needs_auth", "error": "Unauthorized"], "integrationID": "mcp_1"],
            ["name": "nook", "status": ["status": "connected"]],
        ]]
        let servers = McpStatus.openCode(response)
        XCTAssertEqual(servers.map(\.status), [.failed, .needsSignIn, .connected])
        XCTAssertEqual(servers[0].error, "NotFound: ChildProcess.spawn (/nonexistent )")
    }

    func testEventRoundTrip() {
        let event = McpStatus.event([McpServerState(name: "b", status: .connected), McpServerState(name: "a", status: .failed, error: "x")])
        XCTAssertEqual(event.kind, .system)
        XCTAssertEqual(event.tool, McpStatus.tool)
        XCTAssertEqual(McpStatus.servers(in: event).map(\.name), ["a", "b"])
        XCTAssertFalse(event.text.isEmpty)
        XCTAssertEqual(McpStatus.event([]).text, tr("ws.mcp.none"))
    }

    func testOnlyBareMcpIsNooks() {
        XCTAssertTrue(McpStatus.isRequest("/mcp"))
        XCTAssertTrue(McpStatus.isRequest("  /MCP \n"))
        XCTAssertFalse(McpStatus.isRequest("/mcp reconnect github"))
        XCTAssertFalse(McpStatus.isRequest("what is /mcp"))
    }
}
