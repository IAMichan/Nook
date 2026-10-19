import XCTest

final class CompanionPushTests: XCTestCase {
    private func event(_ kind: PushEvent.Kind = .approval, canAllow: Bool = false) -> PushEvent {
        PushEvent(kind: kind, session: "S1", item: kind == .approval || kind == .question ? "I1" : nil, agent: "Claude Code", title: "Fix login", canAllow: canAllow)
    }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour))! }

    func testDisabledAndKindOff() {
        var s = PushSettings()
        XCTAssertEqual(PushPolicy.skipReason(event(), settings: s, away: true, now: Date()), .disabled)
        s.enabled = true
        XCTAssertNil(PushPolicy.skipReason(event(), settings: s, away: true, now: Date()))
        XCTAssertEqual(PushPolicy.skipReason(event(.limited), settings: s, away: true, now: Date()), .kindOff)
    }

    func testOnlyWhenAway() {
        var s = PushSettings(); s.enabled = true
        XCTAssertEqual(PushPolicy.skipReason(event(), settings: s, away: false, now: Date()), .atTheMac)
        s.onlyWhenAway = false
        XCTAssertNil(PushPolicy.skipReason(event(), settings: s, away: false, now: Date()))
    }

    func testQuietHoursWrapMidnightAndLetUrgentThrough() {
        var s = PushSettings(); s.enabled = true; s.quietFrom = 22; s.quietTo = 7
        XCTAssertTrue(s.inQuietHours(date(hour: 23), calendar: calendar))
        XCTAssertTrue(s.inQuietHours(date(hour: 3), calendar: calendar))
        XCTAssertFalse(s.inQuietHours(date(hour: 12), calendar: calendar))
        XCTAssertNil(PushPolicy.skipReason(event(.approval), settings: s, away: true, now: date(hour: 23), calendar: calendar))
        XCTAssertEqual(PushPolicy.skipReason(event(.finished), settings: s, away: true, now: date(hour: 23), calendar: calendar), .quietHours)
        s.quietAllowsUrgent = false
        XCTAssertEqual(PushPolicy.skipReason(event(.approval), settings: s, away: true, now: date(hour: 23), calendar: calendar), .quietHours)
        s.quietFrom = 9; s.quietTo = 9
        XCTAssertFalse(s.inQuietHours(date(hour: 9), calendar: calendar), "equal hours mean no quiet hours")
    }

    func testCategoryDecidesTheButtons() {
        XCTAssertEqual(PushPolicy.category(event(.approval, canAllow: true)), PushCategory.approvalAllow)
        XCTAssertEqual(PushPolicy.category(event(.approval, canAllow: false)), PushCategory.approvalDeny)
        XCTAssertEqual(PushPolicy.category(event(.question)), PushCategory.question)
        XCTAssertEqual(PushPolicy.category(event(.finished)), PushCategory.info)
    }

    func testLedgerDedupes() {
        var ledger = PushLedger()
        XCTAssertTrue(ledger.admit(event(.approval)))
        XCTAssertFalse(ledger.admit(event(.approval)))
        XCTAssertTrue(ledger.admit(event(.finished), turn: 1))
        XCTAssertFalse(ledger.admit(event(.finished), turn: 1))
        XCTAssertTrue(ledger.admit(event(.finished), turn: 2))
    }

    func testPayloadCarriesIdsAndNoSecrets() throws {
        let payload = APNsPayload.make(event(.approval, canAllow: true), title: "Claude Code", body: "Wacht op toestemming", badge: 2)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try XCTUnwrap(object["aps"] as? [String: Any])
        XCTAssertEqual(aps["category"] as? String, PushCategory.approvalAllow)
        XCTAssertEqual(aps["badge"] as? Int, 2)
        XCTAssertEqual(aps["thread-id"] as? String, "S1")
        XCTAssertEqual((object["nook"] as? [String: Any])?["item"] as? String, "I1")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Fix login"), "the title stays out unless chosen")
        XCTAssertEqual(APNsPayload.collapseID(event(.approval)), "approval:S1:I1")
    }

    func testJWTInput() throws {
        let input = try XCTUnwrap(APNsJWT.signingInput(keyID: "ABC123DEFG", teamID: "35SMNHP9K7", issuedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let parts = input.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(decoding: try XCTUnwrap(Base64URL.decode(parts[0])), as: UTF8.self), #"{"alg":"ES256","kid":"ABC123DEFG"}"#)
        XCTAssertEqual(String(decoding: try XCTUnwrap(Base64URL.decode(parts[1])), as: UTF8.self), #"{"iss":"35SMNHP9K7","iat":1700000000}"#)
        XCTAssertNil(APNsJWT.signingInput(keyID: "bad", teamID: "35SMNHP9K7", issuedAt: Date()))
        XCTAssertNil(APNsJWT.signingInput(keyID: "ABC123DEFG\"}", teamID: "35SMNHP9K7", issuedAt: Date()), "no injection into the JSON")
    }

    func testEndpointAndTokens() {
        let token = String(repeating: "ab", count: 32)
        XCTAssertEqual(APNsJWT.endpoint(production: true, deviceToken: token)?.host, "api.push.apple.com")
        XCTAssertEqual(APNsJWT.endpoint(production: false, deviceToken: token.uppercased())?.host, "api.sandbox.push.apple.com")
        XCTAssertEqual(APNsJWT.endpoint(production: true, deviceToken: token.uppercased())?.lastPathComponent, token)
        XCTAssertNil(APNsJWT.endpoint(production: true, deviceToken: "../x"))
        XCTAssertNil(APNsJWT.endpoint(production: true, deviceToken: "abcd"))
        XCTAssertEqual(APNsJWT.tokenHex(Data([0x0a, 0xff])), "0aff")
    }

    func testOutcomes() {
        XCTAssertEqual(APNsJWT.outcome(status: 200, reason: nil), .delivered)
        XCTAssertEqual(APNsJWT.outcome(status: 410, reason: "Unregistered"), .dropToken)
        XCTAssertEqual(APNsJWT.outcome(status: 400, reason: "BadDeviceToken"), .dropToken)
        XCTAssertEqual(APNsJWT.outcome(status: 400, reason: "PayloadEmpty"), .configuration)
        XCTAssertEqual(APNsJWT.outcome(status: 403, reason: "InvalidProviderToken"), .configuration)
        XCTAssertEqual(APNsJWT.outcome(status: 429, reason: nil), .retryLater)
    }

    func testSettingsDecodeIsTolerant() throws {
        let s = try JSONDecoder().decode(PushSettings.self, from: Data(#"{"enabled":true,"kinds":["approval","nonsense"],"quietFrom":99}"#.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.kinds, [.approval])
        XCTAssertNil(s.quietFrom)
        XCTAssertTrue(s.onlyWhenAway)
        XCTAssertEqual(try JSONDecoder().decode(PushSettings.self, from: JSONEncoder().encode(s)), s)
    }
}
