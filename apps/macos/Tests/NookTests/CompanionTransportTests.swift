import XCTest

/// What the companion's connection learned from iPhone app (docs/COMPANION.md): a probe deadline per route,
/// "Always" from the phone, and the device key's op.
final class CompanionTransportTests: XCTestCase {
    // MARK: Probe deadline per route

    func testProbeDeadlineIsShortOnTheLocalNetworkAndLongerFarAway() {
        XCTAssertEqual(CompanionTiming.probeTimeout(for: CompanionRoute(host: "192.168.1.20", port: 5000)), CompanionTiming.probeTimeout)
        XCTAssertEqual(CompanionTiming.probeTimeout(for: CompanionRoute(host: "mac.local", port: 5000)), CompanionTiming.probeTimeout)
        XCTAssertEqual(CompanionTiming.probeTimeout(for: CompanionRoute(host: "100.101.102.103", port: 5000, tailnet: true)),
                       CompanionTiming.remoteProbeTimeout)
        XCTAssertEqual(CompanionTiming.probeTimeout(for: .viaRelay("https://relay.example.com")), CompanionTiming.remoteProbeTimeout)
        XCTAssertGreaterThan(CompanionTiming.remoteProbeTimeout, CompanionTiming.probeTimeout)
    }

    // MARK: Always, from the phone

    func testAlwaysTravelsWithTheRequest() throws {
        let request = CompanionRequest(id: "r", sent: 1, op: .decide, session: "s", item: "i", allow: true, always: true)
        let decoded = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.always, true)
        // An older phone does not say it.
        let plain = try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"r","sent":1,"op":"decide"}"#.utf8))
        XCTAssertNil(plain.always)
    }

    func testItemFromAnOlderMacHasNoAlways() throws {
        let json = #"{"id":"a","kind":"approval","title":"ls","detail":"Bash","canAllow":true,"options":[]}"#
        let item = try JSONDecoder().decode(SessionDigest.Item.self, from: Data(json.utf8))
        XCTAssertNil(item.canAlways)
        var newer = item
        newer.canAlways = true
        XCTAssertEqual(try JSONDecoder().decode(SessionDigest.Item.self, from: JSONEncoder().encode(newer)).canAlways, true)
    }

    func testAllowingForGoodNeedsTheApproveScopeAndBindingAKeyIsAlwaysAllowed() {
        XCTAssertEqual(CompanionScopes.featureScopes[CompanionFeature.allowAlways], .approve)
        XCTAssertEqual(CompanionScopes.table[.bindKey], .always)
        XCTAssertTrue(CommandReceipts.keeps(.bindKey), "binding a key is answered once")
        XCTAssertNil(CompanionScopes.featureScopes[CompanionFeature.deviceKey], "the device key is about the connection")
        for feature in [CompanionFeature.allowAlways, CompanionFeature.deviceKey] {
            XCTAssertTrue(CompanionFeature.all.contains(feature))
        }
    }
}
