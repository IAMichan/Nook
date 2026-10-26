import XCTest

/// "Why can't I connect?" (`CompanionDiagnosis`): what the checks of the routes ran into becomes one headline, the state
/// of each hop, and what to do.
final class CompanionDiagnosisTests: XCTestCase {
    private let lan = CompanionRoute(host: "192.168.1.20", port: 5000)
    private let tailnet = CompanionRoute(host: "100.101.102.103", port: 5000, learned: true, tailnet: true)
    private let relay = CompanionRoute.viaRelay("https://relay.example.com")

    private func diagnose(_ probes: [(CompanionRoute, CompanionDiagnosis.RouteOutcome)], online: Bool = true,
                          compatibility: CompanionCompatibility = .ok, lastError: CompanionError? = nil,
                          lastClose: Int? = nil) -> CompanionDiagnosis.Result {
        CompanionDiagnosis.diagnose(.init(online: online, probes: probes.map { .init(route: $0.0, outcome: $0.1) },
                                          compatibility: compatibility, lastError: lastError, lastCloseCode: lastClose))
    }

    private func hop(_ result: CompanionDiagnosis.Result, _ hop: CompanionDiagnosis.Hop) -> CompanionDiagnosis.HopResult? {
        result.hops.first { $0.hop == hop }?.result
    }

    func testAnAnswerIsConnected() {
        let result = diagnose([(lan, .unreachable), (tailnet, .answered(milliseconds: 80)), (relay, .answered(milliseconds: 240))])
        XCTAssertEqual(result.cause, .connected)
        XCTAssertEqual(result.steps, [])
        XCTAssertEqual(result.fastestMilliseconds, 80)
        XCTAssertEqual(hop(result, .localNetwork), .failed)
        XCTAssertEqual(hop(result, .tailnet), .ok)
        XCTAssertEqual(hop(result, .mac), .ok)
    }

    func testOfflineDeviceLeavesTheRestUnchecked() {
        let result = diagnose([(lan, .unreachable), (relay, .unreachable)], online: false)
        XCTAssertEqual(result.cause, .deviceOffline)
        XCTAssertEqual(result.steps, [.connectDevice])
        XCTAssertEqual(hop(result, .device), .failed)
        XCTAssertEqual(hop(result, .relay), .unchecked)
        XCTAssertEqual(hop(result, .mac), .unchecked)
    }

    func testMacOfflineOnTheRelay() {
        let result = diagnose([(lan, .unreachable), (relay, .closed(code: CompanionDiagnosis.relayMacOffline))])
        XCTAssertEqual(result.cause, .macNotOnRelay)
        XCTAssertEqual(hop(result, .relay), .ok, "the relay itself answered")
        XCTAssertEqual(hop(result, .mac), .failed)
        XCTAssertEqual(result.steps.first, .wakeMac)
        XCTAssertNil(result.hops.first { $0.hop == .tailnet }, "no tailnet route, no tailnet hop")
    }

    func testTheLastCloseCodeNamesTheMacWhenTheRelayWasNotChecked() {
        let result = diagnose([(lan, .unreachable), (relay, .unchecked)], lastClose: 4404)
        XCTAssertEqual(result.cause, .macNotOnRelay)
        XCTAssertEqual(hop(result, .mac), .failed)
    }

    func testClockSkew() {
        XCTAssertEqual(diagnose([(lan, .refused(.stale))]).cause, .clockSkew)
        XCTAssertEqual(diagnose([(lan, .unchecked)], lastError: .stale).cause, .clockSkew)
        XCTAssertEqual(diagnose([(lan, .refused(.stale))]).steps, [.setClocks])
        XCTAssertEqual(hop(diagnose([(lan, .refused(.stale))]), .mac), .failed)
    }

    func testKeyProblems() {
        let unpaired = diagnose([(lan, .closedWithoutAnswer), (relay, .closed(code: 4404))])
        XCTAssertEqual(unpaired.cause, .notPaired)
        XCTAssertEqual(unpaired.steps, [.pairAgain])
        let other = diagnose([(lan, .wrongKey)])
        XCTAssertEqual(other.cause, .keyMismatch)
        XCTAssertEqual(hop(other, .localNetwork), .failed, "another machine is not the way to the Mac")
    }

    func testVersionsComeBeforeTheRoutes() {
        XCTAssertEqual(diagnose([(lan, .answered(milliseconds: 3))], compatibility: .macTooOld).cause, .macTooOld)
        XCTAssertEqual(diagnose([(lan, .answered(milliseconds: 3))], compatibility: .phoneTooOld).steps, [.updateApp])
    }

    func testNothingAnswersAtHome() {
        let result = diagnose([(lan, .unreachable)])
        XCTAssertEqual(result.cause, .notOnLocalNetwork)
        XCTAssertEqual(result.steps, [.sameWiFi, .wakeMac, .openNookOnMac, .setUpAway], "no relay or tailnet yet: suggest one")
        let withRelay = diagnose([(lan, .unreachable), (relay, .unreachable)])
        XCTAssertEqual(withRelay.cause, .relayUnreachable)
        XCTAssertEqual(hop(withRelay, .relay), .failed)
        XCTAssertEqual(diagnose([(lan, .unreachable), (tailnet, .unreachable)]).cause, .tailnetSilent)
    }

    func testSomethingListensButTheMacIsSilent() {
        let result = diagnose([(lan, .timedOut)])
        XCTAssertEqual(result.cause, .macSilent)
        XCTAssertEqual(hop(result, .localNetwork), .ok)
        XCTAssertEqual(hop(result, .mac), .failed)
    }

    func testRoomFullAndRateLimit() {
        XCTAssertEqual(diagnose([(relay, .closed(code: CompanionDiagnosis.relayRoomFull))]).cause, .relayFull)
        XCTAssertEqual(hop(diagnose([(relay, .closed(code: CompanionDiagnosis.relayRoomFull))]), .relay), .failed)
        XCTAssertEqual(diagnose([(lan, .refused(.rateLimited))]).cause, .rateLimited)
    }

    func testNotCheckedYet() {
        let result = diagnose([(lan, .unchecked)])
        XCTAssertEqual(result.cause, .notChecked)
        XCTAssertEqual(hop(result, .localNetwork), .unchecked)
        XCTAssertEqual(hop(result, .mac), .unchecked)
        XCTAssertEqual(diagnose([]).cause, .notChecked)
    }
}
