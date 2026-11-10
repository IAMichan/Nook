import XCTest

/// What the companion's connection learned from t3code's iPhone app (docs/COMPANION.md): a probe deadline per route,
/// freshness apart from the connection, "Always" from the phone, compressed answers, and the device key's op.
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

    // MARK: Freshness

    func testFreshnessIsLiveWithALiveConnectionHoweverOldTheLastChange() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(CompanionFreshness.of(connected: true, live: true, lastUpdated: now.addingTimeInterval(-3_600), now: now), .live)
    }

    func testFreshnessWithoutALiveConnectionFollowsTheLastAnswer() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(CompanionFreshness.of(connected: true, live: false, lastUpdated: now.addingTimeInterval(-30), now: now), .current)
        XCTAssertEqual(CompanionFreshness.of(connected: true, live: false, lastUpdated: now.addingTimeInterval(-180), now: now),
                       .behind(minutes: 3))
        XCTAssertEqual(CompanionFreshness.of(connected: true, live: false, lastUpdated: nil, now: now), .current)
    }

    func testFreshnessOfflineSaysSinceWhen() {
        let now = Date(timeIntervalSince1970: 10_000)
        let last = now.addingTimeInterval(-600)
        XCTAssertEqual(CompanionFreshness.of(connected: false, live: true, lastUpdated: last, now: now), .offline(since: last))
        XCTAssertEqual(CompanionFreshness.of(connected: false, live: false, lastUpdated: nil, now: now), .offline(since: nil))
    }

    // MARK: Always, from the phone

    func testAlwaysAndAcceptsTravelWithTheRequest() throws {
        let request = CompanionRequest(id: "r", sent: 1, op: .decide, session: "s", item: "i", allow: true, always: true,
                                       accepts: [CompanionDeflate.name])
        let decoded = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.always, true)
        XCTAssertEqual(decoded.accepts, [CompanionDeflate.name])
        // An older phone says neither.
        let plain = try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"r","sent":1,"op":"decide"}"#.utf8))
        XCTAssertNil(plain.always)
        XCTAssertNil(plain.accepts)
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
        XCTAssertNil(CompanionScopes.featureScopes[CompanionFeature.deflate], "compression is about the connection")
        XCTAssertNil(CompanionScopes.featureScopes[CompanionFeature.deviceKey])
        for feature in [CompanionFeature.allowAlways, CompanionFeature.deflate, CompanionFeature.deviceKey] {
            XCTAssertTrue(CompanionFeature.all.contains(feature))
        }
    }

    // MARK: Compression

    func testDeflateRoundTripsLargeJSONAndLeavesSmallOnesAlone() throws {
        try XCTSkipUnless(CompanionDeflate.isAvailable, "compression needs Apple's Compression framework")
        let entries = (0..<400).map { TimelineEntry(id: "e\($0)", kind: .assistant, text: "Reading the same file again, line \($0).", date: 1, failed: false) }
        let json = try JSONEncoder().encode(entries)
        let packed = try XCTUnwrap(CompanionDeflate.compress(json))
        XCTAssertLessThan(packed.count, json.count / 2)
        XCTAssertEqual(CompanionDeflate.decompress(packed), json)
        XCTAssertNil(CompanionDeflate.compress(Data("{\"ok\":true}".utf8)), "below the threshold it goes as it is")
        XCTAssertNil(CompanionDeflate.decompress(Data([0xFF, 0x00, 0x13, 0x37])), "not DEFLATE")
    }
}
