import XCTest

/// A connector added at runtime (an MCP server, a new service) joins source scoping and routing without editing tables.
final class SourceRegistryTests: XCTestCase {
    override func tearDown() {
        SourceCatalog.unregister("mcp.linear")
    }

    func testRegisteredSourceOwnsItsToolsAndIsRecognised() {
        XCTAssertNil(SourceCatalog.source(forTool: "mcp_linear_search"), "unknown before registration")
        SourceCatalog.register(SourceDescriptor(id: "mcp.linear", title: "Linear", kind: .custom),
                               tools: ["mcp_linear_search", "mcp_linear_create_issue"],
                               intents: [#"tickets?|sprint"#])
        XCTAssertEqual(SourceCatalog.source(forTool: "mcp_linear_search"), "mcp.linear")
        XCTAssertEqual(SourceCatalog.title("mcp.linear"), "Linear")

        var scope = SourceScope()
        scope.excluded = ["mcp.linear"]
        XCTAssertFalse(scope.allowsTool("mcp_linear_create_issue"), "the picker now governs the new tools")

        let parsed = SourceScope.parse("zoek alleen in Linear")
        XCTAssertEqual(parsed?.included, ["mcp.linear"], "the title works as an alias")

        let routed = SourceRouter.relevant(to: "welke tickets staan in deze sprint?", scope: .automatic, active: ["mcp.linear", "mail"])
        XCTAssertTrue(routed.contains("mcp.linear"))
        XCTAssertFalse(routed.contains("mail"))
    }

    func testUnregisterRemovesEverything() {
        SourceCatalog.register(SourceDescriptor(id: "mcp.linear", title: "Linear", kind: .custom), tools: ["mcp_linear_search"])
        SourceCatalog.unregister("mcp.linear")
        XCTAssertNil(SourceCatalog.source(forTool: "mcp_linear_search"))
        XCTAssertNil(SourceCatalog.descriptor("mcp.linear"))
    }

    func testAccountScope() {
        var scope = SourceScope()
        XCTAssertTrue(scope.allowsAccount("github.werk"))
        scope.excludedAccounts = ["github.werk"]
        XCTAssertFalse(scope.allowsAccount("github.werk"))
        XCTAssertTrue(scope.allowsAccount("github"))
        XCTAssertTrue(scope.isRestricted)
        scope.excluded = ["github"]
        XCTAssertFalse(scope.allowsAccount("github"), "no source, no accounts")
    }

    func testOldSavedScopesStillDecode() throws {
        let old = #"{"mode":"only","included":["mail"],"excluded":[],"focus":[]}"#
        let scope = try JSONDecoder().decode(SourceScope.self, from: Data(old.utf8))
        XCTAssertEqual(scope.included, ["mail"])
        XCTAssertNil(scope.excludedAccounts)
    }
}
