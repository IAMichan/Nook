import XCTest

/// Compression on the companion channel (`CompanionWire`): large messages are compressed before they are sealed, small
/// ones and those for a side that cannot open them go as plain JSON, and a broken or oversized one is refused.
final class CompanionWireTests: XCTestCase {
    private func largeTimeline() -> CompanionResponse {
        let entries = (0..<300).map { i in
            TimelineEntry(id: "e\(i)", kind: .assistant, text: "Edited Sources/File\(i % 7).swift and ran the tests again.",
                          detail: "Edit", date: Double(i), failed: false)
        }
        return CompanionResponse(id: "r", ok: true, timeline: entries, timelineSession: "s")
    }

    func testPlainJSONIsUnchanged() throws {
        let json = Data(#"{"id":"r","ok":true}"#.utf8)
        XCTAssertEqual(CompanionWire.pack(json, compress: true), json, "small messages are not worth compressing")
        XCTAssertEqual(try CompanionWire.unpack(json), json)
        XCTAssertFalse(CompanionWire.isCompressed(json))
    }

    func testNothingIsCompressedForAPhoneThatDidNotAsk() throws {
        let json = try JSONEncoder().encode(largeTimeline())
        XCTAssertEqual(CompanionWire.pack(json, compress: false), json)
    }

    #if canImport(Compression)
    func testALargeAnswerRoundTripsCompressed() throws {
        let response = largeTimeline()
        let json = try JSONEncoder().encode(response)
        let packed = try CompanionWire.encode(response, compress: true)
        XCTAssertTrue(CompanionWire.isCompressed(packed))
        XCTAssertLessThan(packed.count, json.count / 3, "a timeline repeats itself and compresses well")
        XCTAssertEqual(try CompanionWire.decode(CompanionResponse.self, from: packed), response)
    }

    func testCompressedThroughTheSeal() throws {
        let key = Data(repeating: 7, count: 32)
        let packed = try CompanionWire.encode(largeTimeline(), compress: true)
        let sealed = try CompanionSeal.seal(packed, pairingKey: key, deviceID: "d", direction: .response)
        let opened = try CompanionSeal.open(sealed, pairingKey: key, direction: .response)
        XCTAssertEqual(try CompanionWire.decode(CompanionResponse.self, from: opened), largeTimeline())
    }

    func testIncompressibleDataStaysPlain() {
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<8_192).map { _ in UInt8.random(in: 0...255, using: &generator) })
        XCTAssertEqual(CompanionWire.pack(noise, compress: true), noise, "compressing must make it smaller, or it is left")
    }

    func testABrokenOrLyingMessageIsRefused() throws {
        let packed = try CompanionWire.encode(largeTimeline(), compress: true)
        XCTAssertThrowsError(try CompanionWire.unpack(packed.prefix(packed.count - 20)), "cut short")
        var lying = packed
        lying[7] = lying[7] &+ 1
        XCTAssertThrowsError(try CompanionWire.unpack(lying), "opens to another length than it says")
        var unknown = packed
        unknown[3] = 0x7A
        XCTAssertThrowsError(try CompanionWire.unpack(unknown)) { XCTAssertEqual($0 as? CompanionWire.Failure, .unsupported) }
    }
    #endif

    func testAnOversizedPromiseIsRefusedBeforeUnpacking() {
        let n = CompanionWire.maxExpanded + 1
        let header = CompanionWire.magic + Data([CompanionWire.deflate, UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
                                                 UInt8((n >> 8) & 0xff), UInt8(n & 0xff), 0x03, 0x00])
        XCTAssertThrowsError(try CompanionWire.unpack(header)) { XCTAssertEqual($0 as? CompanionWire.Failure, .tooLarge) }
    }

    // MARK: Compatibility

    func testAnOldPhoneNeverAsksAndAnOldMacIgnoresTheAsk() throws {
        // A phone before compression sends no flag: the Mac sends it plain JSON.
        let old = try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"r","sent":1,"op":"list"}"#.utf8))
        XCTAssertNil(old.compression)
        // A new phone's flag is one more key an older Mac's decoder skips.
        var request = CompanionRequest(op: .list)
        request.compression = true
        let json = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["compression"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: json).compression, true)
        // A request without the flag encodes exactly as before.
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CompanionRequest(op: .list))) as? [String: Any])["compression"])
    }

    func testThePhoneCompressesOnlyForAMacThatListsIt() {
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.compression))
        XCTAssertNil(CompanionScopes.featureScopes[CompanionFeature.compression], "about the connection: every phone gets it")
    }
}
