import XCTest

/// Older sessions and search on the phone (`CompanionHistory`, `CompanionOp.history`), and previews of a session's files
/// in pieces (`FileChunk`, `FileAssembly`).
final class CompanionHistoryTests: XCTestCase {
    private struct Item: Equatable { var id: String; var updated: Double }

    private func page(_ items: [Item], after cursor: String?, limit: Int) -> (items: [Item], cursor: String?) {
        CompanionHistory.page(items, updated: \.updated, id: \.id, after: cursor, limit: limit)
    }

    func testPagesWalkEverySessionOnceNewestFirst() {
        let items = (0..<53).map { Item(id: String(format: "s%02d", $0), updated: Double($0 / 2)) }
        var cursor: String?
        var seen: [Item] = []
        repeat {
            let next = page(items, after: cursor, limit: 10)
            seen += next.items
            cursor = next.cursor
        } while cursor != nil
        XCTAssertEqual(seen.count, 53)
        XCTAssertEqual(Set(seen.map(\.id)).count, 53, "no session twice, even with equal times")
        XCTAssertEqual(seen.map(\.updated), seen.map(\.updated).sorted(by: >))
    }

    func testTheLastPageHasNoCursor() {
        let items = (0..<5).map { Item(id: "s\($0)", updated: Double($0)) }
        XCTAssertNil(page(items, after: nil, limit: 5).cursor)
        XCTAssertNotNil(page(items, after: nil, limit: 4).cursor)
    }

    func testASessionThatMovesToTheTopShiftsNoPage() {
        var items = (0..<20).map { Item(id: "s\($0)", updated: Double($0)) }
        let first = page(items, after: nil, limit: 5)
        items[0].updated = 100
        let second = page(items, after: first.cursor, limit: 5)
        XCTAssertEqual(second.items.map(\.id), ["s14", "s13", "s12", "s11", "s10"])
    }

    func testCursorsRoundTripAndBadOnesStartOver() {
        let cursor = CompanionHistory.Cursor(updated: 1_700_000_000.5, id: "A|B")
        XCTAssertEqual(CompanionHistory.Cursor(cursor.text), cursor)
        XCTAssertNil(CompanionHistory.Cursor("nonsense"))
        XCTAssertNil(CompanionHistory.Cursor(nil))
        let items = [Item(id: "a", updated: 1)]
        XCTAssertEqual(page(items, after: "nonsense", limit: 5).items, items)
    }

    func testSearchNeedsEveryWordSomewhere() {
        let fields = ["Fix the login form", "nook", "feature/login", "Claude Code"]
        XCTAssertTrue(CompanionHistory.matches("login claude", fields))
        XCTAssertTrue(CompanionHistory.matches("LOGIN", fields))
        XCTAssertTrue(CompanionHistory.matches("", fields))
        XCTAssertFalse(CompanionHistory.matches("login codex", fields))
        XCTAssertTrue(CompanionHistory.matches("cafe", ["Café menu"]), "accents do not matter")
    }

    func testSearchWordsAreCleaned() {
        XCTAssertEqual(CompanionHistory.clean("  login\u{7} "), "login")
        XCTAssertEqual(CompanionHistory.clean(nil), "")
        XCTAssertEqual(CompanionHistory.clean(String(repeating: "a", count: 500)).count, CompanionHistory.maxQuery)
    }

    func testOlderSessionsLeaveOutWhatTheLiveListHas() {
        func digest(_ id: String, _ updated: Double) -> SessionDigest {
            SessionDigest(id: id, title: id, agent: "Claude", attention: "idle", folder: "f", branch: nil, updated: updated, excerpt: "",
                          items: [])
        }
        let merged = CompanionHistory.merge(live: [digest("a", 9)], older: [digest("b", 1), digest("a", 2), digest("c", 3), digest("b", 1)])
        XCTAssertEqual(merged.map(\.id), ["c", "b"])
    }

    // MARK: Compatibility

    func testNewOpsAreGatedAndScoped() {
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.history))
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.filePreview))
        XCTAssertEqual(CompanionScopes.table[.history], .scope(.read))
        XCTAssertEqual(CompanionScopes.table[.fileData], .scope(.operate))
        // A phone that may not operate is not offered previews, and gets no file bytes.
        let granted: Set<CompanionScope> = [.read]
        var response = CompanionResponse(id: "r", ok: true, features: CompanionFeature.all)
        response.fileChunk = FileChunk(path: "a.png", offset: 0, total: 1, data: "AA==")
        let redacted = CompanionScopes.redact(response, granted: granted)
        XCTAssertNil(redacted.fileChunk)
        XCTAssertFalse(redacted.features?.contains(CompanionFeature.filePreview) ?? true)
        XCTAssertTrue(redacted.features?.contains(CompanionFeature.history) ?? false)
    }

    func testAnOldPhoneReadsAnAnswerWithTheNewFields() throws {
        var response = CompanionResponse(id: "r", ok: true, sessions: [])
        response.cursor = "1.000000|x"
        let json = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: json).cursor, "1.000000|x")
        // Without them, an answer encodes as an older Mac's.
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CompanionResponse(id: "r", ok: true))) as? [String: Any])
        XCTAssertNil(plain["cursor"])
        XCTAssertNil(plain["fileChunk"])
    }

    // MARK: File previews

    func testRangesStayWithinTheFileAndTheLimit() {
        XCTAssertEqual(FileChunk.range(offset: 0, total: 10), 0..<10)
        XCTAssertEqual(FileChunk.range(offset: 0, total: 300_000), 0..<FileChunk.maxChunkBytes)
        XCTAssertEqual(FileChunk.range(offset: FileChunk.maxChunkBytes * 2, total: 300_000), FileChunk.maxChunkBytes * 2..<300_000)
        XCTAssertEqual(FileChunk.range(offset: 0, total: 0), 0..<0)
        XCTAssertNil(FileChunk.range(offset: 10, total: 10))
        XCTAssertNil(FileChunk.range(offset: -1, total: 10))
        XCTAssertNil(FileChunk.range(offset: 0, total: FileChunk.maxFileBytes + 1))
    }

    #if canImport(CryptoKit)
    func testAPieceFitsInOneFrameOnceSealed() throws {
        let bytes = Data(repeating: 0xAB, count: FileChunk.maxChunkBytes)
        var response = CompanionResponse(id: UUID().uuidString, ok: true)
        response.fileChunk = FileChunk(path: String(repeating: "p", count: 200), offset: 0, total: FileChunk.maxFileBytes,
                                       data: bytes.base64EncodedString())
        // Plain, as for a phone without compression: the worst case.
        let json = try JSONEncoder().encode(response)
        let sealed = try CompanionSeal.seal(json, pairingKey: Data(repeating: 1, count: 32), deviceID: "0123456789abcdef", direction: .response)
        XCTAssertNotNil(CompanionFrameReader.frame(sealed))
    }
    #endif

    func testAFileIsAssembledInOrder() throws {
        let file = Data((0..<300_000).map { UInt8($0 % 251) })
        var assembly = FileAssembly()
        while !assembly.complete {
            let range = try XCTUnwrap(FileChunk.range(offset: assembly.nextOffset, total: file.count))
            try assembly.take(FileChunk(path: "a.mov", offset: range.lowerBound, total: file.count,
                                        data: file.subdata(in: range).base64EncodedString()))
        }
        XCTAssertEqual(assembly.data, file)
    }

    func testAssemblyRefusesWhatDoesNotFollow() throws {
        var assembly = FileAssembly()
        let piece = Data(repeating: 1, count: 10).base64EncodedString()
        XCTAssertThrowsError(try assembly.take(FileChunk(path: "a", offset: 5, total: 20, data: piece))) {
            XCTAssertEqual($0 as? FileAssembly.Failure, .outOfOrder)
        }
        try assembly.take(FileChunk(path: "a", offset: 0, total: 20, data: piece))
        XCTAssertThrowsError(try assembly.take(FileChunk(path: "a", offset: 10, total: 30, data: piece))) {
            XCTAssertEqual($0 as? FileAssembly.Failure, .changed)
        }
        XCTAssertThrowsError(try assembly.take(FileChunk(path: "a", offset: 10, total: 20, data: "%%%"))) {
            XCTAssertEqual($0 as? FileAssembly.Failure, .malformed)
        }
        var fresh = FileAssembly()
        XCTAssertThrowsError(try fresh.take(FileChunk(path: "a", offset: 0, total: FileChunk.maxFileBytes + 1, data: piece))) {
            XCTAssertEqual($0 as? FileAssembly.Failure, .tooLarge)
        }
    }
}
