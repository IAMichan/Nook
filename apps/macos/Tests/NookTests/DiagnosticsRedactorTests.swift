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
        let out = DiagnosticsRedactor.redact(#"mail sam@example.com call +31 6 1234 5678 at /Users/sam/Nook and C:\Users\sam\Nook"#)
        XCTAssertFalse(out.contains("sam@example.com"))
        XCTAssertFalse(out.contains("1234 5678"))
        XCTAssertFalse(out.contains("/Users/sam"))
        XCTAssertFalse(out.contains(#"Users\sam"#))
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

    /// The export's log: the last half hour, oldest first, the newest when there are too many, long lines cut.
    func testTheLogKeepsTheRecentNewestLines() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ ago: TimeInterval, _ message: String) -> DiagnosticsLog.Entry {
            DiagnosticsLog.Entry(date: now.addingTimeInterval(-ago), category: "storage", level: "error", message: message)
        }
        let entries = [entry(10, "second"), entry(DiagnosticsLog.window + 1, "too old"), entry(20, "first\nline")]
        let lines = DiagnosticsLog.lines(entries, now: now)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" error storage: first line"))
        XCTAssertTrue(lines[1].hasSuffix(" error storage: second"))

        let many = (0..<10).map { entry(TimeInterval(100 - $0), "line \($0)") }
        XCTAssertEqual(DiagnosticsLog.lines(many, now: now, limit: 3).map { $0.components(separatedBy: ": ").last }, ["line 7", "line 8", "line 9"])

        let long = DiagnosticsLog.lines([entry(1, String(repeating: "x", count: 2_000))], now: now)[0]
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThan(long.count, DiagnosticsLog.messageLimit + 40)
    }

    /// What a log line holds is redacted with the rest of the report.
    func testLogLinesAreRedacted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let line = DiagnosticsLog.lines([DiagnosticsLog.Entry(date: now, category: "agents", level: "info",
                                                              message: "opened /Users/jane/app for jane@example.com")], now: now)
        let report = DiagnosticsRedactor.report(header: [], log: line, now: now)
        XCTAssertFalse(report.contains("jane"))
        XCTAssertTrue(report.contains("[email]"))
    }

    /// Values logged as private, and strings without a mark (private by default), never reach the export; values marked
    /// public and plain numbers do.
    func testPrivateLogValuesStayOut() {
        let pieces = [
            DiagnosticsLog.Piece(text: "opened ", placeholder: "%{private}s", isNumber: false, value: "/Users/jane/secret"),
            DiagnosticsLog.Piece(text: " via ", placeholder: "%{public}s", isNumber: false, value: "codex"),
            DiagnosticsLog.Piece(text: " said ", placeholder: "%s", isNumber: false, value: "my message"),
            DiagnosticsLog.Piece(text: " after ", placeholder: "%ld", isNumber: true, value: "42"),
            DiagnosticsLog.Piece(text: " tries, id ", placeholder: "%{private}ld", isNumber: true, value: "7"),
            DiagnosticsLog.Piece(text: ".", placeholder: "", isNumber: false, value: nil),
        ]
        XCTAssertEqual(DiagnosticsLog.message(pieces), "opened <private> via codex said <private> after 42 tries, id <private>.")
    }
}
