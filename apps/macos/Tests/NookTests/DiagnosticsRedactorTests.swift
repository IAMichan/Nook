import XCTest

/// What a diagnostics export leaves out, and the plural-aware sync line.
final class DiagnosticsRedactorTests: XCTestCase {
    func testSecretsAreRemoved() {
        let text = "Authorization: Bearer abcdefgh12345678 key sk-abcdefghijklmnop ghp_abcdefghijklmnopqrstuvwx password=hunter2"
        let out = DiagnosticsRedactor.redact(text)
        XCTAssertFalse(out.contains("abcdefgh12345678"))
        XCTAssertFalse(out.contains("sk-abcdefghijklmnop"))
        XCTAssertFalse(out.contains("ghp_"))
        XCTAssertFalse(out.contains("hunter2"))
    }

    func testPersonalDetailsAreRemoved() {
        let out = DiagnosticsRedactor.redact("mail sam@example.com call +31 6 1234 5678 at /Users/sam/Nook and C:\\Users\\sam\\Nook")
        XCTAssertFalse(out.contains("sam@example.com"))
        XCTAssertFalse(out.contains("1234 5678"))
        XCTAssertFalse(out.contains("/Users/sam"))
        XCTAssertFalse(out.contains("Users\\sam"))
        XCTAssertTrue(out.contains("[email]"))
    }

    func testLinkQueriesAreRemovedButTheHostStays() {
        let out = DiagnosticsRedactor.redact("GET https://api.example.com/v1/items?user=sam&code=42 failed")
        XCTAssertEqual(out, "GET https://api.example.com/v1/items?[query] failed")
    }

    func testOrdinaryTextIsUntouched() {
        let text = "Nook 0.4 (12) started in 840 ms at 2026-11-11T10:00:00Z"
        XCTAssertEqual(DiagnosticsRedactor.redact(text), text)
    }

    func testReportRedactsHeaderAndLog() {
        let report = DiagnosticsRedactor.report(header: [("Account", "sam@example.com")], log: ["token: abc123"], now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("Account: [email]"))
        XCTAssertTrue(report.contains("token: [secret]"))
        XCTAssertTrue(report.hasPrefix("Nook diagnostics"))
    }

    func testPluralCategories() {
        XCTAssertEqual(I18n.pluralCategory(1, language: .en), "one")
        XCTAssertEqual(I18n.pluralCategory(0, language: .en), "other")
        XCTAssertEqual(I18n.pluralCategory(0, language: .fr), "one")
        XCTAssertEqual(I18n.pluralCategory(2, language: .fr), "other")
    }

    func testSyncLineStatesOfflineAndQueue() {
        let now = Date()
        let line = NookSyncStatus.text(lastSynced: nil, offline: true, queued: 0, now: now)
        XCTAssertEqual(line, I18n.text("sync.offline", [], for: I18n.shared.currentLanguage))
        let queued = NookSyncStatus.text(lastSynced: nil, offline: false, queued: 2, now: now)
        XCTAssertTrue(queued.contains("2"))
    }
}
