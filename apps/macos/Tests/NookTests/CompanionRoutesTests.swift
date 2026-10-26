import XCTest

final class CompanionRoutesTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    func testClassifiesAddresses() {
        XCTAssertEqual(CompanionAddress.classify("127.0.0.1"), .loopback)
        XCTAssertEqual(CompanionAddress.classify("localhost"), .loopback)
        XCTAssertEqual(CompanionAddress.classify("192.168.1.20"), .lan)
        XCTAssertEqual(CompanionAddress.classify("10.0.0.5"), .lan)
        XCTAssertEqual(CompanionAddress.classify("172.20.1.1"), .lan)
        XCTAssertEqual(CompanionAddress.classify("172.32.1.1"), .internet)
        XCTAssertEqual(CompanionAddress.classify("Michaels-Mac.local"), .lan)
        XCTAssertEqual(CompanionAddress.classify("100.101.102.103"), .vpn, "the shared space is only Tailscale when the Mac says so")
        XCTAssertEqual(CompanionAddress.classify("mac.tail1234.ts.net"), .tailnet)
        XCTAssertEqual(CompanionAddress.classify("fd7a:115c:a1e0::1"), .tailnet)
        XCTAssertEqual(CompanionAddress.classify("fe80::1"), .lan)
        XCTAssertEqual(CompanionAddress.classify("example.com"), .internet)
        XCTAssertEqual(CompanionAddress.classify("8.8.8.8"), .internet)
        XCTAssertNil(CompanionAddress.ipv4("1.2.3"))
        XCTAssertNil(CompanionAddress.ipv4("1.2.3.256"))
        XCTAssertNil(CompanionAddress.ipv4("1.2.+3.4"))
    }

    func testPairingLinkCarriesAlternates() throws {
        let link = PairingLink(host: "mac.local", port: 49321, key: key, macName: "Mac",
                               alternates: ["192.168.1.20", "100.101.102.103"])
        let parsed = try XCTUnwrap(PairingLink.parse(try XCTUnwrap(link.url).absoluteString))
        XCTAssertEqual(parsed, link)
        // A bad or repeated alternate is left out; the link itself still works.
        let text = "nook://pair?h=mac.local&p=1&k=\(Base64URL.encode(key))&a=a%2Fb&a=MAC.local&a=10.0.0.2&a=10.0.0.2"
        XCTAssertEqual(PairingLink.parse(text)?.alternates, ["10.0.0.2"])
    }

    func testInitialRoutesPutTheLocalNetworkFirst() {
        let link = PairingLink(host: "mac.local", port: 5000, key: key, macName: "Mac",
                               alternates: ["100.101.102.103", "192.168.1.20"])
        let routes = CompanionRoutes.initial(from: link)
        XCTAssertEqual(routes.map(\.host), ["mac.local", "192.168.1.20", "100.101.102.103"])
        XCTAssertEqual(routes.map(\.learned), [false, true, true])
    }

    func testMergeFollowsWhatTheMacReports() throws {
        let saved = [CompanionRoute(host: "mac.local", port: 5000),
                     CompanionRoute(host: "192.168.1.20", port: 5000, learned: true)]
        // The Mac moved to another Wi-Fi network and has Tailscale now; it also listens on another port.
        let reported = [CompanionEndpoint(host: "mac.local", port: 5001, tailnet: false),
                        CompanionEndpoint(host: "10.0.0.7", port: 5001, tailnet: false),
                        CompanionEndpoint(host: "100.101.102.103", port: 5001, tailnet: true),
                        CompanionEndpoint(host: "127.0.0.1", port: 5001, tailnet: false)]
        let merged = try XCTUnwrap(CompanionRoutes.merge(saved, reported: reported))
        XCTAssertEqual(merged.map(\.host), ["mac.local", "10.0.0.7", "100.101.102.103"])
        XCTAssertEqual(Set(merged.map(\.port)), [5001])
        XCTAssertEqual(merged.last?.kind, .tailnet)
        XCTAssertNil(CompanionRoutes.merge(merged, reported: reported), "nothing changed")
    }

    func testMergeNeverDropsWhatWasPaired() throws {
        let saved = [CompanionRoute(host: "mac.local", port: 5000), CompanionRoute(host: "10.0.0.7", port: 5000, learned: true)]
        let merged = try XCTUnwrap(CompanionRoutes.merge(saved, reported: []))
        XCTAssertEqual(merged, [CompanionRoute(host: "mac.local", port: 5000)])
    }

    func testPickPrefersEarlierRoutes() {
        XCTAssertEqual(CompanionRoutes.pick([true, nil], headStartPassed: false), .route(0))
        XCTAssertEqual(CompanionRoutes.pick([nil, true], headStartPassed: false), .wait, "the first route still has its head start")
        XCTAssertEqual(CompanionRoutes.pick([nil, true], headStartPassed: true), .route(1))
        XCTAssertEqual(CompanionRoutes.pick([false, true], headStartPassed: false), .route(1))
        XCTAssertEqual(CompanionRoutes.pick([false, nil, true], headStartPassed: true), .route(2))
        XCTAssertEqual(CompanionRoutes.pick([false, false], headStartPassed: true), .unreachable)
        XCTAssertEqual(CompanionRoutes.pick([false, nil], headStartPassed: true), .wait)
    }

    func testBackoffGrowsWithJitterUpToTheCap() {
        XCTAssertEqual(RetryBackoff.delay(failures: 1, random: 0), 1)
        XCTAssertEqual(RetryBackoff.delay(failures: 1, random: 1), 2)
        XCTAssertEqual(RetryBackoff.delay(failures: 3, random: 1), 8)
        XCTAssertEqual(RetryBackoff.delay(failures: 30, random: 1), RetryBackoff.cap)
        XCTAssertEqual(RetryBackoff.delay(failures: 30, random: 0), RetryBackoff.cap / 2)
    }

    func testWakeupReplacesTheConnectionAfterARealBreak() {
        let now = Date()
        XCTAssertEqual(CompanionWakeup.onActive(backgroundedAt: nil, now: now), .probe)
        XCTAssertEqual(CompanionWakeup.onActive(backgroundedAt: now.addingTimeInterval(-3), now: now), .probe)
        XCTAssertEqual(CompanionWakeup.onActive(backgroundedAt: now.addingTimeInterval(-30), now: now), .reconnect)
    }

    func testCooldownHoldsARouteBack() {
        var cooldowns = RouteCooldowns()
        let route = CompanionRoute(host: "192.168.1.20", port: 1)
        let now = Date()
        XCTAssertTrue(cooldowns.allows(route, now: now))
        cooldowns.hold(route, now: now)
        XCTAssertFalse(cooldowns.allows(route, now: now.addingTimeInterval(60)))
        XCTAssertTrue(cooldowns.allows(route, now: now.addingTimeInterval(CompanionTiming.routeCooldown)))
    }

    func testOutboxKeepsOnlyMessagesAndExpires() {
        var outbox = CompanionOutbox()
        let now = Date()
        let message = CompanionRequest(id: "m1", sent: now.timeIntervalSince1970, op: .send, session: "s", text: "hi")
        XCTAssertTrue(outbox.enqueue(message, now: now))
        XCTAssertTrue(outbox.enqueue(message, now: now), "the same message once")
        XCTAssertFalse(outbox.enqueue(CompanionRequest(op: .decide, session: "s", item: "i", allow: true), now: now))
        XCTAssertEqual(outbox.entries.count, 1)
        XCTAssertEqual(outbox.waiting(for: "s").count, 1)

        let later = now.addingTimeInterval(120)
        let resent = CompanionOutbox.resend(outbox.entries[0], now: later)
        XCTAssertEqual(resent.id, "m1")
        XCTAssertEqual(resent.sent, later.timeIntervalSince1970)

        XCTAssertEqual(outbox.expire(now: now.addingTimeInterval(CompanionOutbox.maxAge + 1)).count, 1)
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    func testReceiptsAnswerARepeatOnce() {
        var receipts = CommandReceipts()
        receipts.record("a", CompanionResponse(id: "a", ok: true, message: "sent"))
        receipts.record("b", .failure("b", .failed))
        receipts.record("c", .failure("c", .unknownSession))
        XCTAssertEqual(receipts.response(for: "a")?.message, "sent")
        XCTAssertNil(receipts.response(for: "b"), "a passing failure may be tried again")
        XCTAssertEqual(receipts.response(for: "c")?.error, .unknownSession)
        XCTAssertTrue(CommandReceipts.keeps(.send))
        XCTAssertFalse(CommandReceipts.keeps(.list))
        for i in 0..<(CommandReceipts.capacity + 5) { receipts.record("x\(i)", CompanionResponse(id: "x\(i)", ok: true)) }
        XCTAssertNil(receipts.response(for: "a"), "the oldest go first")
    }

    func testARequestThatFailedInPassingGetsThroughAgain() {
        var guardian = RequestGuard()
        let now = Date()
        let request = CompanionRequest(id: "f", sent: now.timeIntervalSince1970, op: .send, session: "s", text: "hi")
        XCTAssertNil(guardian.admit(request, now: now))
        XCTAssertFalse(CommandReceipts.settles(.failure("f", .busy)))
        XCTAssertTrue(CommandReceipts.settles(.failure("f", .unknownSession)))
        guardian.forget(request)
        XCTAssertNil(guardian.admit(request, now: now), "the outbox sends it again with the same id")
        XCTAssertEqual(guardian.admit(request, now: now), .replay)
    }

    func testRetryOfAKnownRequestIsAdmittedButStillChecked() {
        var guardian = RequestGuard()
        let now = Date()
        let request = CompanionRequest(id: "r", sent: now.timeIntervalSince1970, op: .send, session: "s", text: "hi")
        XCTAssertNil(guardian.admit(request, now: now))
        XCTAssertEqual(guardian.admit(request, now: now), .replay)
        XCTAssertNil(guardian.admitRetry(request, now: now))
        XCTAssertEqual(guardian.admitRetry(request, now: now.addingTimeInterval(120)), .stale)
    }
}
