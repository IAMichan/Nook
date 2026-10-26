import XCTest

/// Push through the relay: the push key, the request the Mac posts, how the relay's answer is read, and (on a Mac) the
/// sealing round trip in the format the phone's Notification Service Extension opens.
final class RelayPushTests: XCTestCase {
    private let pairingKey = Data(0..<32)
    private let token = String(repeating: "a1", count: 32)
    private let room = "cae98fe2b67a6f65273aa18446bdf884"
    /// Made independently (Python: HMAC, HKDF-SHA256 and ChaCha20-Poly1305 as CompanionSeal does), so the format is
    /// pinned from outside Swift.
    private let vector = #"{"d": "630dcd2966c43366", "s": "AAAAAAAAAAAAAAAABS3kO4MIl6sxb1ccggt5baLczbPE5rpaZZaRXcuXSEkU4GmcxaFGzXF2q8bQTP2LEs8QYTtYj28NxxIl6Jzq5FRLlKT08PCoTrtIfWad9wFhK/oWpdxpklboXglaJ9jrZzvC7W6L/zlNGKz8GyQVJJtQdWS9SyRboYTAbGjAzZDq+8r9QGuqTk4csyaBfiMwc1M="}"#

    func testPushKeyAndCollapseIDAreDerivedNotRevealed() {
        let push = RelayPush.pushKey(pairingKey: pairingKey)
        XCTAssertEqual(WebhookHex.encode(push), "7a429408bc2815112a429079b335fb1a10ddd5ca648231192c2182f7ce957c07")
        XCTAssertNotEqual(push, pairingKey)
        XCTAssertEqual(PairedDevice.identifier(forKey: pairingKey), "630dcd2966c43366")
        let collapse = RelayPush.collapseID("approval:s1:i1", pushKey: push)
        XCTAssertEqual(collapse, "f6b38485348952fccce2343eeac86bd8")
        XCTAssertFalse(collapse.contains("s1"))
    }

    func testRequestAroundAnEnvelope() throws {
        let request = try XCTUnwrap(RelayPush.request(envelope: Data(vector.utf8), room: room, token: token.uppercased(),
                                                      production: true, collapse: "ab", urgent: true))
        XCTAssertEqual(request.token, token)
        XCTAssertEqual(request.sealed.d, "630dcd2966c43366")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["room", "token", "production", "sealed", "collapse", "urgent"], "what push.js reads")
        XCTAssertNil(RelayPush.request(envelope: Data(vector.utf8), room: "nope", token: token, production: true, collapse: nil, urgent: false))
        XCTAssertNil(RelayPush.request(envelope: Data(vector.utf8), room: room, token: "xyz", production: true, collapse: nil, urgent: false))
        XCTAssertNil(RelayPush.request(envelope: Data("{}".utf8), room: room, token: token, production: true, collapse: nil, urgent: false))

        XCTAssertEqual(RelayPush.endpoint(relay: "nook-relay.me.workers.dev")?.absoluteString, "https://nook-relay.me.workers.dev/v1/push")
        XCTAssertNil(RelayPush.endpoint(relay: "http://example.com"))
    }

    func testReadsTheRelaysAnswer() {
        XCTAssertEqual(RelayPush.outcome(status: 200, body: Data(#"{"apns":200}"#.utf8)).outcome, .delivered)
        let gone = RelayPush.outcome(status: 200, body: Data(#"{"apns":410,"reason":"Unregistered"}"#.utf8))
        XCTAssertEqual(gone.outcome, .dropToken)
        XCTAssertEqual(gone.reason, "Unregistered")
        XCTAssertEqual(RelayPush.outcome(status: 429, body: Data()).outcome, .retryLater)
        XCTAssertEqual(RelayPush.outcome(status: 502, body: Data()).outcome, .retryLater)
        let off = RelayPush.outcome(status: 501, body: Data(#"{"error":"push is not set up on this relay"}"#.utf8))
        XCTAssertEqual(off.outcome, .configuration)
        XCTAssertEqual(off.reason, "push is not set up on this relay")
    }

    func testContentIsBoundedAndCarriesTheAppsIDs() throws {
        let content = RelayPushContent(title: String(repeating: "t", count: 500), body: String(repeating: "b", count: 500),
                                       category: PushCategory.question, thread: "s", session: "s", item: "i", badge: -3)
        XCTAssertEqual(content.title.count, RelayPushContent.maxTitle)
        XCTAssertEqual(content.body.count, RelayPushContent.maxBody)
        XCTAssertEqual(content.badge, 0)
        XCTAssertEqual((content.userInfo["nook"] as? [String: Any])?["item"] as? String, "i")
        let envelope = try XCTUnwrap(RelayPush.envelope(fromUserInfo: ["d": "630dcd2966c43366", "s": "AAAA"]))
        XCTAssertEqual(try JSONDecoder().decode(RelayPushRequest.Sealed.self, from: envelope).s, "AAAA")
        XCTAssertNil(RelayPush.envelope(fromUserInfo: "nope"))
    }

    #if canImport(CryptoKit)
    func testSealRoundTripAndTheOutsideVector() throws {
        let content = RelayPushContent(title: "Claude · Fix tests", body: "Needs your approval", category: PushCategory.approvalDeny,
                                       thread: "s1", session: "s1", item: "i1", badge: 2)
        let device = PairedDevice.identifier(forKey: pairingKey)
        let envelope = try RelayPush.seal(content, pairingKey: pairingKey, deviceID: device)
        XCTAssertEqual(CompanionSeal.claimedDevice(envelope), device)
        let push = RelayPush.pushKey(pairingKey: pairingKey)
        XCTAssertEqual(try RelayPush.open(envelope, pushKey: push), content)
        XCTAssertThrowsError(try RelayPush.open(envelope, pushKey: pairingKey), "the pairing key itself does not open a push")
        XCTAssertThrowsError(try CompanionSeal.open(envelope, pairingKey: pairingKey, direction: .response),
                             "a push never passes as a reply")

        let outside = try RelayPush.open(Data(vector.utf8), pushKey: push)
        XCTAssertEqual(outside.title, "Claude")
        XCTAssertEqual(outside.item, "i1")
        XCTAssertEqual(outside.badge, 2)
    }
    #endif
}
