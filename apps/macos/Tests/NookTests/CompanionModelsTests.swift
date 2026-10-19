import XCTest

final class CompanionModelsTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    func testPairingLinkRoundTrip() throws {
        let link = PairingLink(host: "192.168.1.20", port: 49321, key: key, macName: "Michael’s Mac")
        let parsed = try XCTUnwrap(PairingLink.parse(try XCTUnwrap(link.url).absoluteString))
        XCTAssertEqual(parsed, link)
    }

    func testPairingLinkRefusesBadInput() {
        XCTAssertNil(PairingLink.parse("https://pair?h=a&p=1&k=x"))
        XCTAssertNil(PairingLink.parse("nook://pair?h=a&p=0&k=\(Base64URL.encode(key))"))
        XCTAssertNil(PairingLink.parse("nook://pair?h=a%2Fb&p=1&k=\(Base64URL.encode(key))"), "no path in a host")
        XCTAssertNil(PairingLink.parse("nook://pair?h=a&p=1&k=\(Base64URL.encode(Data(repeating: 1, count: 16)))"), "short key")
        XCTAssertNil(PairingLink.parse("nook://pair?h=a&p=70000&k=\(Base64URL.encode(key))"))
    }

    func testBase64URLRoundTrip() {
        for length in 0..<12 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data)
        }
        XCTAssertFalse(Base64URL.encode(Data([0xfb, 0xff])).contains("+"))
    }

    func testFramingSplitsAndJoins() throws {
        var reader = CompanionFrameReader()
        let a = try XCTUnwrap(CompanionFrameReader.frame(Data("hello".utf8)))
        let b = try XCTUnwrap(CompanionFrameReader.frame(Data("x".utf8)))
        let all = a + b
        XCTAssertEqual(reader.feed(all.prefix(3)), [])
        let frames = reader.feed(all.dropFirst(3))
        XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) }, ["hello", "x"])
    }

    func testOversizedFrameClosesTheReader() {
        var reader = CompanionFrameReader()
        let n = CompanionConstants.maxFrame + 1
        let header = Data([UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        XCTAssertEqual(reader.feed(header), [])
        XCTAssertTrue(reader.overflowed)
        XCTAssertEqual(reader.feed(Data("more".utf8)), [])
        XCTAssertNil(CompanionFrameReader.frame(Data(count: n)))
    }

    func testGuardRefusesStaleAndReplayedRequests() {
        var guardrail = RequestGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = CompanionRequest(id: "a", sent: now.timeIntervalSince1970, op: .list)
        XCTAssertNil(guardrail.admit(fresh, now: now))
        XCTAssertEqual(guardrail.admit(fresh, now: now), .replay)
        let old = CompanionRequest(id: "b", sent: now.timeIntervalSince1970 - 120, op: .list)
        XCTAssertEqual(guardrail.admit(old, now: now), .stale)
        let future = CompanionRequest(id: "c", sent: now.timeIntervalSince1970 + 120, op: .list)
        XCTAssertEqual(guardrail.admit(future, now: now), .stale)
    }

    func testGuardRateLimits() {
        var guardrail = RequestGuard()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var limited = false
        for i in 0..<200 {
            if guardrail.admit(CompanionRequest(id: "r\(i)", sent: now.timeIntervalSince1970, op: .list), now: now) == .rateLimited { limited = true }
        }
        XCTAssertTrue(limited)
    }

    func testPolicyOnlyAllowsLowRiskFromThePhone() {
        XCTAssertTrue(CompanionPolicy.canAllow(tool: "Edit", commandIsSafe: nil))
        XCTAssertTrue(CompanionPolicy.canAllow(tool: "Bash", commandIsSafe: true))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "Bash", commandIsSafe: false))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "Bash", commandIsSafe: nil))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "WebFetch", commandIsSafe: nil))
        XCTAssertFalse(CompanionPolicy.canAllow(tool: "mcp__x__y", commandIsSafe: nil))
    }

    func testMessageCleaning() {
        XCTAssertEqual(CompanionPolicy.cleanMessage("  hi\u{0007}\nthere  "), "hi\nthere")
        XCTAssertNil(CompanionPolicy.cleanMessage("  \n "))
        XCTAssertNil(CompanionPolicy.cleanMessage(String(repeating: "a", count: 8_001)))
        XCTAssertEqual(CompanionPolicy.excerpt(String(repeating: "a", count: 700)).count, CompanionConstants.excerptLimit + 1)
    }

    func testDeviceIdentifierIsStableAndShort() {
        XCTAssertEqual(PairedDevice.identifier(forKey: key), PairedDevice.identifier(forKey: key))
        XCTAssertEqual(PairedDevice.identifier(forKey: key).count, 16)
        XCTAssertNotEqual(PairedDevice.identifier(forKey: key), PairedDevice.identifier(forKey: Data(repeating: 9, count: 32)))
    }

    func testPairedDeviceDecodesWithoutPushFields() throws {
        let old = #"{"id":"a","name":"iPhone","pairedAt":0}"#
        let device = try JSONDecoder().decode(PairedDevice.self, from: Data(old.utf8))
        XCTAssertNil(device.pushToken)
        XCTAssertNil(device.pushProduction)
    }

    func testBadgeCountsSessionsWithItems() {
        let item = SessionDigest.Item(id: "i", kind: .approval, title: "t", detail: "", canAllow: false, options: [])
        let a = SessionDigest(id: "1", title: "", agent: "", attention: "approval", folder: "", branch: nil, updated: 0, excerpt: "", items: [item, item])
        let b = SessionDigest(id: "2", title: "", agent: "", attention: "idle", folder: "", branch: nil, updated: 0, excerpt: "", items: [])
        XCTAssertEqual([a, b].needingYou, 1)
    }

    func testRequestResponseCodable() throws {
        let request = CompanionRequest(op: .decide, session: "s", item: "i", allow: true)
        XCTAssertEqual(try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request)), request)
        let response = CompanionResponse.failure("x", .notAllowedFromPhone)
        XCTAssertEqual(try JSONDecoder().decode(CompanionResponse.self, from: JSONEncoder().encode(response)), response)
    }
}
