import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The shared golden fixtures of the companion protocol (`packages/protocol/Fixtures`), read here as in the Tauri app
/// (`apps/tauri/core/src/companion/fixtures.rs`) and in the relay (`apps/relay/test/fixtures.test.js`), so all of them
/// stay byte for byte the same. See the parity table in docs/COMPANION.md.
final class CompanionFixturesTests: XCTestCase {
    /// `packages/protocol/Fixtures`: from `apps/macos` in the environment when the tests run as a throwaway package,
    /// else relative to this file.
    private static let folder: URL = {
        let macos = ProcessInfo.processInfo.environment["NOOK_MACOS_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return macos.appendingPathComponent("../../packages/protocol/Fixtures").standardizedFileURL
    }()

    private func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func entries(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]])
    }

    func testRequestsReadAndWriteBack() throws {
        for entry in try entries(fixture("requests.json"), "requests") {
            let json = try JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["json"]))
            let request = try JSONDecoder().decode(CompanionRequest.self, from: json)
            XCTAssertEqual(request.op.rawValue, (entry["json"] as? [String: Any])?["op"] as? String)
            let back = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(back, request, entry["name"] as? String ?? "")
            // Every field of the fixture is one this side knows: it comes back.
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            XCTAssertEqual(Set(written.keys), Set((entry["json"] as? [String: Any] ?? [:]).keys), entry["name"] as? String ?? "")
        }
    }

    func testResponsesReadAndWriteBack() throws {
        for entry in try entries(fixture("responses.json"), "responses") {
            let json = try JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["json"]))
            let response = try JSONDecoder().decode(CompanionResponse.self, from: json)
            let back = try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response))
            XCTAssertEqual(back, response, entry["name"] as? String ?? "")
            let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
            XCTAssertEqual(Set(written.keys), Set((entry["json"] as? [String: Any] ?? [:]).keys), entry["name"] as? String ?? "")
        }
    }

    func testFraming() throws {
        let object = try fixture("framing.json")
        XCTAssertEqual(object["maxFrame"] as? Int, CompanionConstants.maxFrame)
        for frame in try entries(object, "frames") {
            let payload = hex(frame["payload"] as? String ?? "")
            let framed = hex(frame["framed"] as? String ?? "")
            XCTAssertEqual(CompanionFrameReader.frame(payload), framed)
            var reader = CompanionFrameReader()
            XCTAssertEqual(reader.feed(framed), [payload])
        }
    }

    func testPairingLinks() throws {
        let object = try fixture("pairing.json")
        for link in try entries(object, "valid") {
            let url = try XCTUnwrap(link["url"] as? String)
            let parsed = try XCTUnwrap(PairingLink.parse(url), url)
            XCTAssertEqual(parsed.host, link["host"] as? String)
            XCTAssertEqual(Int(parsed.port), link["port"] as? Int)
            XCTAssertEqual(parsed.key, Base64URL.decode(link["key"] as? String ?? ""))
            XCTAssertEqual(parsed.macName, link["macName"] as? String)
            XCTAssertEqual(parsed.alternates, link["alternates"] as? [String])
            XCTAssertEqual(parsed.relay, link["relay"] as? String)
        }
        for text in try XCTUnwrap(object["invalid"] as? [String]) { XCTAssertNil(PairingLink.parse(text), text) }
    }

    func testRelayRoomsMuxAndCloseCodes() throws {
        let object = try fixture("relay.json")
        for room in try entries(object, "rooms") {
            let key = try XCTUnwrap(Base64URL.decode(room["key"] as? String ?? ""))
            XCTAssertEqual(CompanionRelay.room(forKey: key), room["room"] as? String)
        }
        for message in try entries(object, "mux") {
            let kind = try XCTUnwrap(RelayMux.Kind(rawValue: UInt8(message["kind"] as? Int ?? 0)))
            let connection = UInt32(message["connection"] as? Int ?? 0)
            let payload = hex(message["payload"] as? String ?? "")
            XCTAssertEqual(hex(RelayMux.encode(kind, connection: connection, payload: payload)), message["frame"] as? String)
            XCTAssertEqual(RelayMux.decode(hex(message["frame"] as? String ?? "")),
                           RelayMux.Message(kind: kind, connection: connection, payload: payload))
        }
        for frame in try XCTUnwrap(object["invalidMux"] as? [String]) { XCTAssertNil(RelayMux.decode(hex(frame)), frame) }
        let codes = try XCTUnwrap(object["closeCodes"] as? [String: Int])
        XCTAssertEqual(codes["macOffline"], CompanionDiagnosis.relayMacOffline)
        XCTAssertEqual(codes["roomFull"], CompanionDiagnosis.relayRoomFull)
    }

    func testDeviceIdentifier() throws {
        let object = try fixture("sealed.json")
        let key = try XCTUnwrap(Base64URL.decode(object["key"] as? String ?? ""))
        XCTAssertEqual(PairedDevice.identifier(forKey: key), object["deviceID"] as? String)
    }

    #if canImport(CryptoKit)
    /// CryptoKit only (the Mac): the same sealed bytes as the Tauri app and the test vector.
    func testSealedFrames() throws {
        let object = try fixture("sealed.json")
        let key = try XCTUnwrap(Base64URL.decode(object["key"] as? String ?? ""))
        let device = try XCTUnwrap(object["deviceID"] as? String)
        let nonce = hex(object["nonce"] as? String ?? "")
        for vector in try entries(object, "vectors") {
            let direction: CompanionSeal.Direction = vector["direction"] as? String == "q" ? .request : .response
            let plaintext = Data((vector["plaintext"] as? String ?? "").utf8)
            let envelope = try CompanionSeal.seal(plaintext, pairingKey: key, deviceID: device, direction: direction, nonce: nonce)
            let parsed = try JSONDecoder().decode(CompanionSeal.Envelope.self, from: envelope)
            XCTAssertEqual(parsed.s, vector["s"] as? String)
            XCTAssertEqual(parsed.d, device)
            XCTAssertEqual(try CompanionSeal.open(envelope, pairingKey: key, direction: direction), plaintext)
        }
    }
    #endif
}
