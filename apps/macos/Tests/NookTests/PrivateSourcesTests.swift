import XCTest

/// "Only on this Mac": while an external brain answers, those sources cannot be reached however the scope or the question asks.
final class PrivateSourcesTests: XCTestCase {
    func testNothingChangesWithoutPrivateSources() {
        let scope = SourceScope(mode: .only, included: ["mail"], excluded: ["stripe"])
        XCTAssertEqual(scope.keepingLocal([]), scope)
    }

    func testPrivateSourcesAreOutOfReachInAutomaticMode() {
        let scope = SourceScope.automatic.keepingLocal(["whatsapp", "mail"])
        XCTAssertFalse(scope.allows("whatsapp"))
        XCTAssertFalse(scope.allows("mail"))
        XCTAssertTrue(scope.allows("github"))
        XCTAssertFalse(scope.allowsTool("search_whatsapp"))
        XCTAssertFalse(scope.allowsTool("read_mail"))
        XCTAssertTrue(scope.allowsTool("github_overview"))
    }

    func testAQuestionCannotBringAPrivateSourceBack() throws {
        let asked = try XCTUnwrap(SourceScope.parse("Zoek alleen in mijn mail en agenda"))
        let scope = SourceScope.automatic.merged(with: asked).keepingLocal(["mail"])
        XCTAssertFalse(scope.allows("mail"))
        XCTAssertTrue(scope.allows("calendar"))
        XCTAssertFalse(scope.focus.contains("mail"))
    }

    func testOnlyModeLeavesNothingWhenEverythingAskedForIsPrivate() {
        let scope = SourceScope(mode: .only, included: ["mail"]).keepingLocal(["mail"])
        XCTAssertFalse(scope.allows("mail"))
        XCTAssertFalse(scope.allows("calendar"), "only mode still means only the sources that were named")
    }

    func testFocusOnAPrivateSourceIsDropped() {
        let scope = SourceScope(focus: ["notes", "github"]).keepingLocal(["notes"])
        XCTAssertEqual(scope.focus, ["github"])
    }

    func testAccountsOfAPrivateSourceAreOutOfReachToo() {
        let scope = SourceScope.automatic.keepingLocal(["github"])
        XCTAssertFalse(scope.allowsAccount("github.werk"))
    }

    func testThePersonalPresetCoversTheScreenAndThePersonalApps() {
        for id in [SourceCatalog.screen, "mail", "messages", "whatsapp", "notes", "calendar", "files"] {
            XCTAssertTrue(SourceCatalog.personal.contains(id), id)
        }
        XCTAssertFalse(SourceCatalog.personal.contains(SourceCatalog.web))
        XCTAssertTrue(SourceCatalog.personal.isSubset(of: Set(SourceCatalog.all.map(\.id))))
    }

    func testAScopeWithPrivateSourcesIsReportedAsRestricted() {
        XCTAssertTrue(SourceScope.automatic.keepingLocal(["mail"]).isRestricted)
        XCTAssertEqual(SourceScope.automatic.keepingLocal(["mail"]).label(), "Zonder Mail")
    }
}
