import XCTest

/// What a paired phone may do (`CompanionScope`, `CompanionScopes`).
final class CompanionScopesTests: XCTestCase {
    /// A new op must say which scope it needs: without an entry it would be refused to every phone.
    func testEveryOpHasAnEntryInTheTable() {
        let missing = CompanionOp.allCases.filter { CompanionScopes.table[$0] == nil }
        XCTAssertEqual(missing, [], "add these ops to CompanionScopes.table")
    }

    func testEveryFeatureWithAScopeIsAKnownFeature() {
        for feature in CompanionScopes.featureScopes.keys { XCTAssertTrue(CompanionFeature.all.contains(feature), feature) }
    }

    func testTheConnectionAlwaysWorks() {
        for op in [CompanionOp.hello, .list, .subscribe, .ping, .register, .unregister, .liveActivity] {
            XCTAssertTrue(CompanionScopes.allows(op, granted: []), "\(op)")
        }
    }

    func testScopesGateTheirOps() {
        XCTAssertFalse(CompanionScopes.allows(.decide, granted: [.read]))
        XCTAssertTrue(CompanionScopes.allows(.decide, granted: [.approve]))
        XCTAssertFalse(CompanionScopes.allows(.start, granted: [.read, .approve]))
        XCTAssertTrue(CompanionScopes.allows(.send, granted: [.operate]))
        XCTAssertFalse(CompanionScopes.allows(.inboxSend, granted: [.nookChat]))
        XCTAssertTrue(CompanionScopes.allows(.ask, granted: [.nookChat]))
        XCTAssertFalse(CompanionScopes.allows(.music, granted: Set(CompanionScope.allCases).subtracting([.music])))
    }

    func testOldDevicesMayDoEverythingAndUnknownNamesAreIgnored() throws {
        let old = try JSONDecoder().decode(PairedDevice.self, from: Data(#"{"id":"d","name":"iPhone","pairedAt":0}"#.utf8))
        XCTAssertNil(old.scopes)
        XCTAssertEqual(old.grantedScopes, Set(CompanionScope.allCases))
        XCTAssertEqual(CompanionScopes.parse(["read", "teleport", "music"]), [.read, .music])
        XCTAssertEqual(CompanionScopes.parse([]), [])
        XCTAssertEqual(CompanionScopes.names([.music, .read]), ["read", "music"], "stable order")
    }

    func testAnswersLeaveOutWhatThePhoneMayNotSee() {
        let session = SessionDigest(id: "s", title: "T", agent: "Claude", attention: "working", folder: "f", branch: nil,
                                    updated: 0, excerpt: "", items: [])
        var response = CompanionResponse(id: "r", ok: true, sessions: [session], features: CompanionFeature.all)
        response.inbox = []
        response.conversations = []
        let redacted = CompanionScopes.redact(response, granted: [.approve])
        XCTAssertEqual(redacted.sessions, [], "no read: an empty list, not a missing one")
        XCTAssertNil(redacted.inbox)
        XCTAssertNil(redacted.conversations)
        XCTAssertEqual(redacted.scopes, ["approve"])
        let features = Set(redacted.features ?? [])
        XCTAssertFalse(features.contains(CompanionFeature.start))
        XCTAssertFalse(features.contains(CompanionFeature.inbox))
        XCTAssertTrue(features.contains(CompanionFeature.stream), "connection features stay")
        XCTAssertTrue(features.contains(CompanionFeature.retry))
    }

    func testEverythingGrantedChangesNothingButTheScopes() {
        let response = CompanionResponse(id: "r", ok: true, sessions: [], features: CompanionFeature.all)
        var expected = response
        expected.scopes = CompanionScope.allCases.map(\.rawValue)
        XCTAssertEqual(CompanionScopes.redact(response, granted: Set(CompanionScope.allCases)), expected)
        let plain = CompanionResponse(id: "p", ok: true)
        XCTAssertNil(CompanionScopes.redact(plain, granted: []).scopes, "only answers that list features carry scopes")
    }
}
