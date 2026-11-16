import XCTest

/// `TelegramBridge.handledTypes` drops what `handle` does not read on TDLib's own thread, so a type added to `handle`
/// but not to the set would never arrive. The source is read as text (like `AgentParityTests`), so this needs nothing of
/// the app and also runs through `scripts/core-tests.sh`.
final class TelegramBridgeTypesTests: XCTestCase {
    /// `apps/macos`: from the environment when the tests run as a throwaway package, else relative to this file.
    private static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    private static func strings(in text: Substring) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #""([A-Za-z]+)""#)
        let string = String(text)
        return Set(regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
            Range($0.range(at: 1), in: string).map { String(string[$0]) }
        })
    }

    func testHandledTypesMatchTheCasesOfHandle() throws {
        let url = Self.root.appendingPathComponent("Services/Messages/TelegramBridge.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let setStart = try XCTUnwrap(source.range(of: "static let handledTypes: Set<String> = ["))
        let setEnd = try XCTUnwrap(source.range(of: "]", range: setStart.upperBound..<source.endIndex))
        let listed = Self.strings(in: source[setStart.upperBound..<setEnd.lowerBound])

        let handleStart = try XCTUnwrap(source.range(of: "private func handle(_ object: [String: Any]) {"))
        let handleEnd = try XCTUnwrap(source.range(of: "private func authorization(", range: handleStart.upperBound..<source.endIndex))
        var cases: Set<String> = []
        for line in source[handleStart.upperBound..<handleEnd.lowerBound].split(separator: "\n")
        where line.trimmingCharacters(in: .whitespaces).hasPrefix("case \"") {
            cases.formUnion(Self.strings(in: line))
        }

        XCTAssertFalse(cases.isEmpty)
        XCTAssertEqual(listed, cases, "TelegramBridge.handledTypes must list exactly the @types `handle` has a case for")
    }
}
