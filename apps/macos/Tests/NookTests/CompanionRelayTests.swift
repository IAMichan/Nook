import XCTest

final class CompanionRelayTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    func testRoomComesFromTheKey() {
        // HMAC-SHA256(key, "nook-companion-relay-room-v1"), first 16 bytes; the phone and the Mac must agree on it.
        XCTAssertEqual(CompanionRelay.room(forKey: key), "cae98fe2b67a6f65273aa18446bdf884")
        XCTAssertNotEqual(CompanionRelay.room(forKey: Data(repeating: 7, count: 32)), CompanionRelay.room(forKey: key))
        XCTAssertTrue(CompanionRelay.isRoom(CompanionRelay.room(forKey: key)))
        XCTAssertFalse(CompanionRelay.isRoom("../etc"))
    }

    func testRelayAddressMustBeHTTPS() {
        XCTAssertEqual(CompanionRelay.normalize("nook-relay.me.workers.dev"), "https://nook-relay.me.workers.dev")
        XCTAssertEqual(CompanionRelay.normalize(" https://Relay.example.com/some/path?x=1 "), "https://relay.example.com")
        XCTAssertEqual(CompanionRelay.normalize("http://localhost:8787"), "http://localhost:8787")
        XCTAssertNil(CompanionRelay.normalize("http://relay.example.com"), "no plain HTTP over the internet")
        XCTAssertNil(CompanionRelay.normalize("https://user:pw@relay.example.com"))
        XCTAssertNil(CompanionRelay.normalize("ftp://relay.example.com"))
        XCTAssertNil(CompanionRelay.normalize(""))
    }

    func testSocketURL() throws {
        let room = CompanionRelay.room(forKey: key)
        let url = try XCTUnwrap(CompanionRelay.socketURL(relay: "https://relay.example.com", room: room, role: .phone))
        XCTAssertEqual(url.absoluteString, "wss://relay.example.com/v1/rooms/\(room)?role=phone")
        XCTAssertEqual(CompanionRelay.socketURL(relay: "http://localhost:8787", room: room, role: .mac)?.absoluteString,
                       "ws://localhost:8787/v1/rooms/\(room)?role=mac")
        XCTAssertNil(CompanionRelay.socketURL(relay: "https://relay.example.com", room: "nope", role: .mac))
    }

    func testMuxRoundTrip() throws {
        // The same bytes apps/relay/test/mux.test.js expects.
        let encoded = RelayMux.encode(.data, connection: 0x01020304, payload: Data([9, 8]))
        XCTAssertEqual([UInt8](encoded), [2, 1, 2, 3, 4, 9, 8])
        XCTAssertEqual(RelayMux.decode(encoded), RelayMux.Message(kind: .data, connection: 0x01020304, payload: Data([9, 8])))
        XCTAssertEqual(RelayMux.decode(RelayMux.encode(.open, connection: 7))?.payload, Data())
        XCTAssertNil(RelayMux.decode(Data([2, 0, 0])))
        XCTAssertNil(RelayMux.decode(Data([9, 0, 0, 0, 1])))
    }

    func testPairingLinkCarriesTheRelay() throws {
        let link = PairingLink(host: "mac.local", port: 5000, key: key, macName: "Mac", relay: "https://relay.example.com")
        let parsed = try XCTUnwrap(PairingLink.parse(try XCTUnwrap(link.url).absoluteString))
        XCTAssertEqual(parsed.relay, "https://relay.example.com")
        let routes = CompanionRoutes.initial(from: parsed)
        XCTAssertEqual(routes.last?.relay, "https://relay.example.com", "the relay is the last resort")
        XCTAssertNil(PairingLink.parse("nook://pair?h=mac.local&p=1&k=\(Base64URL.encode(key))&r=http://evil.example")?.relay)
    }

    func testMacDecidesTheRelayRoute() throws {
        let saved = [CompanionRoute(host: "mac.local", port: 5000)]
        let added = try XCTUnwrap(CompanionRoutes.withRelay(saved, relay: "https://relay.example.com"))
        XCTAssertEqual(added.map(\.isRelay), [false, true])
        XCTAssertNil(CompanionRoutes.withRelay(added, relay: "https://relay.example.com"))
        XCTAssertNil(CompanionRoutes.withRelay(added, relay: nil), "an older Mac says nothing")
        XCTAssertEqual(CompanionRoutes.withRelay(added, relay: ""), saved, "turned off")
        // What the Mac reports never drops the relay route, and new addresses go before it.
        let merged = try XCTUnwrap(CompanionRoutes.merge(added, reported: [CompanionEndpoint(host: "10.0.0.2", port: 5000, tailnet: false)]))
        XCTAssertEqual(merged.map(\.host), ["mac.local", "10.0.0.2", "relay.example.com"])
    }
}

final class CloudflareRelaySetupTests: XCTestCase {
    func testMetadataCarriesTheMigrationOnlyTheFirstTime() throws {
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: CloudflareRelaySetup.metadata(withMigration: true)) as? [String: Any])
        XCTAssertEqual(first["main_module"] as? String, "index.js")
        let binding = try XCTUnwrap((first["bindings"] as? [[String: Any]])?.first)
        XCTAssertEqual(binding["name"] as? String, "ROOMS")
        XCTAssertEqual(binding["class_name"] as? String, "Room")
        XCTAssertEqual((first["migrations"] as? [String: Any])?["new_tag"] as? String, "v1")
        let update = try XCTUnwrap(JSONSerialization.jsonObject(with: CloudflareRelaySetup.metadata(withMigration: false)) as? [String: Any])
        XCTAssertNil(update["migrations"])
    }

    func testMultipartHasTheSettingsAndEveryModule() {
        let body = CloudflareRelaySetup.multipart(metadata: Data("{}".utf8),
                                                  modules: [("index.js", Data("a".utf8)), ("mux.js", Data("b".utf8))], boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{}\r\n"))
        XCTAssertTrue(text.contains("name=\"index.js\"; filename=\"index.js\"\r\nContent-Type: application/javascript+module\r\n\r\na\r\n"))
        XCTAssertTrue(text.contains("name=\"mux.js\""))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    func testTokenPageAndAddress() {
        let page = CloudflareRelaySetup.tokenPage.absoluteString
        XCTAssertTrue(page.hasPrefix("https://dash.cloudflare.com/profile/api-tokens?"))
        XCTAssertTrue(page.contains("workers_scripts"))
        XCTAssertEqual(CloudflareRelaySetup.address(subdomain: "me"), "https://nook-relay.me.workers.dev")
        XCTAssertNotNil(CompanionRelay.normalize(CloudflareRelaySetup.address(subdomain: CloudflareRelaySetup.newSubdomain())))
    }

    func testVersionFollowsTheCode() {
        let a = CloudflareRelaySetup.version(of: [("index.js", Data("one".utf8))])
        XCTAssertEqual(a, CloudflareRelaySetup.version(of: [("index.js", Data("one".utf8))]))
        XCTAssertNotEqual(a, CloudflareRelaySetup.version(of: [("index.js", Data("two".utf8))]))
        XCTAssertEqual(a.count, 16)
    }
}
