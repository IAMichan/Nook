import XCTest

final class LocalAgentScannerTests: XCTestCase {
    /// Builds a `kern.procargs2` area the way the kernel lays it out.
    private func area(_ arguments: [String], environment: [String], path: String = "/usr/local/bin/node") -> [UInt8] {
        var argc = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array(path.utf8) + [0, 0, 0, 0]
        for text in arguments + environment { bytes += Array(text.utf8) + [0] }
        return bytes + [0, 0, 0, 0, 0, 0, 0, 0]
    }

    func testSplitsArgumentsAndEnvironment() throws {
        let bytes = area(["node", "/opt/claude/cli.js", "--resume"], environment: ["HOME=/Users/x", "CLAUDE_CONFIG_DIR=/Users/x/My Work/.claude"])
        let parsed = try XCTUnwrap(LocalAgentScanner.parseArguments(bytes, count: bytes.count))
        XCTAssertEqual(parsed.arguments, ["node", "/opt/claude/cli.js", "--resume"])
        XCTAssertEqual(parsed.environment, ["HOME=/Users/x", "CLAUDE_CONFIG_DIR=/Users/x/My Work/.claude"])
        let line = (parsed.arguments + parsed.environment).joined(separator: " ")
        XCTAssertEqual(AgentProcessEnvironment.value(of: "CLAUDE_CONFIG_DIR", in: line), "/Users/x/My Work/.claude")
    }

    func testKeepsEmptyArgumentsAndStopsAtTheEnd() throws {
        let bytes = area(["claude", "", "-p"], environment: [])
        let parsed = try XCTUnwrap(LocalAgentScanner.parseArguments(bytes, count: bytes.count))
        XCTAssertEqual(parsed.arguments, ["claude", "", "-p"])
        XCTAssertEqual(parsed.environment, [])
    }

    func testRespectsTheReportedSize() throws {
        let bytes = area(["codex"], environment: ["A=1", "B=2"])
        let cut = bytes.count - 8 - 4   // drop the padding and "B=2\0"
        let parsed = try XCTUnwrap(LocalAgentScanner.parseArguments(bytes, count: cut))
        XCTAssertEqual(parsed.arguments, ["codex"])
        XCTAssertEqual(parsed.environment, ["A=1"])
    }

    func testRejectsTooShortAnArea() {
        XCTAssertNil(LocalAgentScanner.parseArguments([1, 0], count: 2))
    }
}
