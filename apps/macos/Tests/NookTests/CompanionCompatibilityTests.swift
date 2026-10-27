import XCTest

/// Versions of the Mac and the phone (`CompanionProtocol`, `CompanionCompatibility`): which side to update, and that
/// messages of a side that predates versions still read.
final class CompanionCompatibilityTests: XCTestCase {
    func testSameAndUnversionedPeersWork() {
        XCTAssertEqual(CompanionCompatibility.check(macVersion: CompanionProtocol.version, oldestPhone: CompanionProtocol.oldestPhone), .ok)
        XCTAssertEqual(CompanionCompatibility.check(macVersion: nil, oldestPhone: nil), .ok, "a Mac before versions is version 1")
        XCTAssertTrue(CompanionCompatibility.phoneSupported(nil), "a phone before versions still works with this Mac")
    }

    func testAMacOlderThanThePhoneSupportsIsTooOld() {
        XCTAssertEqual(CompanionCompatibility.check(macVersion: 2, oldestPhone: 1, phoneVersion: 4, oldestMac: 3), .macTooOld)
        XCTAssertEqual(CompanionCompatibility.check(macVersion: nil, oldestPhone: nil, phoneVersion: 4, oldestMac: 2), .macTooOld)
    }

    func testAPhoneOlderThanTheMacSupportsIsTooOld() {
        XCTAssertEqual(CompanionCompatibility.check(macVersion: 5, oldestPhone: 3, phoneVersion: 2, oldestMac: 1), .phoneTooOld)
        XCTAssertFalse(CompanionCompatibility.phoneSupported(1, oldestPhone: 2))
        XCTAssertTrue(CompanionCompatibility.phoneSupported(2, oldestPhone: 2))
    }

    func testUnknownFeaturesAreReportedWithoutDuplicates() {
        XCTAssertEqual(CompanionCompatibility.unknownFeatures([CompanionFeature.start, "future", "future"]), ["future"])
    }

    func testKnownFeaturesAreNotUnknown() {
        XCTAssertEqual(CompanionCompatibility.unknownFeatures(CompanionFeature.all), [])
    }

    func testMissingFeatureInformationIsDistinctFromAnEmptyList() {
        XCTAssertNil(CompanionCompatibility.unknownFeatures(nil))
        XCTAssertEqual(CompanionCompatibility.unknownFeatures([]), [])
    }

    func testAMacTooOldWinsOverAPhoneTooOld() {
        // Both are out of range: the Mac is the one that cannot even say what it needs.
        XCTAssertEqual(CompanionCompatibility.check(macVersion: 1, oldestPhone: 9, phoneVersion: 2, oldestMac: 2), .macTooOld)
    }

    func testTheResponseCarriesTheVersions() {
        var response = CompanionResponse(id: "a", ok: true)
        response.protocolVersion = 7
        response.oldestPhone = CompanionProtocol.version + 1
        XCTAssertEqual(CompanionCompatibility.check(response), .phoneTooOld)
        response.oldestPhone = 1
        XCTAssertEqual(CompanionCompatibility.check(response), .ok)
    }

    func testMessagesWithoutVersionsStillDecode() throws {
        let request = try JSONDecoder().decode(CompanionRequest.self, from: Data(#"{"id":"r","sent":1,"op":"list"}"#.utf8))
        XCTAssertNil(request.protocolVersion)
        XCTAssertNil(request.appVersion)
        let response = try JSONDecoder().decode(CompanionResponse.self, from: Data(#"{"id":"r","ok":true}"#.utf8))
        XCTAssertNil(response.protocolVersion)
        XCTAssertEqual(CompanionCompatibility.check(response), .ok)
        let device = try JSONDecoder().decode(PairedDevice.self, from: Data(#"{"id":"d","name":"iPhone","pairedAt":0}"#.utf8))
        XCTAssertNil(device.protocolVersion)
    }

    func testVersionedRequestsRoundTrip() throws {
        let request = CompanionRequest.versioned(.hello, text: "iPhone")
        XCTAssertEqual(request.protocolVersion, CompanionProtocol.version)
        let back = try JSONDecoder().decode(CompanionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(back, request)
    }

    func testAppVersionsAreCleaned() {
        XCTAssertEqual(CompanionProtocol.cleanVersion(" 1.4.0\n"), "1.4.0")
        XCTAssertNil(CompanionProtocol.cleanVersion("\u{7}"))
        XCTAssertNil(CompanionProtocol.cleanVersion(nil))
        XCTAssertEqual(CompanionProtocol.cleanVersion(String(repeating: "9", count: 100))?.count, 40)
    }

    func testRequestUpdateIsKeptOnceAndOffered() {
        XCTAssertTrue(CommandReceipts.keeps(.requestUpdate))
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.requestUpdate))
    }
}
