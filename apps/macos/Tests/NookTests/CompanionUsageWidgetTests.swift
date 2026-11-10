import XCTest

/// The usage widget's timeline (`UsageWidgetTimeline`): what it shows now, that a limit shows as reset at its reset time,
/// and when the numbers read as old.
final class CompanionUsageWidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(taken: Date? = nil) -> UsageSnapshot {
        let t = now.timeIntervalSince1970
        return UsageSnapshot(macName: "Studio", accounts: [
            .init(id: "claude.work", agent: "Claude", account: "Work", limits: [
                .init(label: "5 hours", percent: 40, resetsAt: t + 3600),
                .init(label: "Week", percent: 85, resetsAt: t + 5 * 86_400),
            ]),
            .init(id: "codex", agent: "Codex", account: "Personal", limits: [
                .init(label: "5 hours", percent: 120, resetsAt: t + 2 * 3600),
            ]),
            .init(id: "empty", agent: "Gemini", account: "", limits: []),
        ], taken: (taken ?? now).timeIntervalSince1970)
    }

    func testRowsPutTheMostUsedFirstAndClampPercent() {
        let rows = UsageWidgetTimeline.rows(snapshot(), at: now)
        XCTAssertEqual(rows.map(\.id), ["codex|5 hours", "claude.work|Week", "claude.work|5 hours"])
        XCTAssertEqual(rows.first?.percent, 100)
        XCTAssertEqual(UsageWidgetTimeline.headline(rows, count: 3).map(\.id), ["codex|5 hours", "claude.work|Week"],
                       "the small widget shows each account's most used limit")
    }

    func testALimitReadsResetOnceItsTimePassed() {
        let later = now.addingTimeInterval(3600 + 1)
        let row = UsageWidgetTimeline.rows(snapshot(), at: later).first { $0.id == "claude.work|5 hours" }
        XCTAssertEqual(row?.percent, 0)
        XCTAssertEqual(row?.reset, true)
        XCTAssertNil(row?.resetsAt)
    }

    func testEntriesComeNowAtEachResetAndWhenTheyTurnStale() {
        let entries = UsageWidgetTimeline.entries(snapshot(), now: now)
        let offsets = entries.map { $0.date.timeIntervalSince(now) }
        XCTAssertEqual(offsets, [0, 3600, 7200, UsageWidgetTimeline.staleAfter], "the weekly reset is past the horizon")
        XCTAssertEqual(entries.map(\.stale), [false, false, false, true])
        XCTAssertEqual(entries[1].rows.first { $0.id == "claude.work|5 hours" }?.reset, true)
        XCTAssertEqual(entries.first?.macName, "Studio")
    }

    func testOldNumbersAreStaleFromTheStart() {
        let entries = UsageWidgetTimeline.entries(snapshot(taken: now.addingTimeInterval(-7 * 3600)), now: now)
        XCTAssertTrue(entries.allSatisfy(\.stale))
    }

    func testWithoutASnapshotThereIsOneEmptyEntry() {
        let entries = UsageWidgetTimeline.entries(nil, now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].rows.isEmpty)
        XCTAssertNil(entries[0].taken)
    }

    func testTheSnapshotRoundTrips() throws {
        let data = try JSONEncoder().encode(snapshot())
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data), snapshot())
    }
}
