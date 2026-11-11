import XCTest

/// The Agent activity widget (`AgentActivitySnapshot`): the same agents the Live Activity follows, waiting ones first,
/// and when unfinished work reads as out of date.
final class CompanionAgentWidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func digest(_ id: String, _ attention: String, updated: Double, waiting: Bool = false) -> SessionDigest {
        SessionDigest(id: id, title: "Task " + id, agent: "Claude Code", attention: attention, folder: "nook", branch: nil,
                      updated: updated, excerpt: "",
                      items: waiting ? [.init(id: "i", kind: .approval, title: "Run", detail: "Bash", canAllow: false, options: [])] : [])
    }

    private func snapshot(_ list: [SessionDigest]) -> AgentActivitySnapshot {
        AgentActivitySnapshot(macName: "Studio", snapshots: list.map { (LiveActivitySnapshot(digest: $0), $0.updated) }, taken: now)
    }

    func testOnlyWorkingAndWaitingAgentsShowWaitingFirst() {
        let made = snapshot([
            digest("done", "ready", updated: 9), digest("old", "working", updated: 1), digest("new", "working", updated: 5),
            digest("ask", "working", updated: 2, waiting: true), digest("failed", "failed", updated: 8),
        ])
        XCTAssertEqual(made.agents.map(\.id), ["ask", "new", "old"])
        XCTAssertEqual(made.waiting, 1)
        XCTAssertEqual(made.agents.first?.phase, .waiting)
    }

    func testNoMoreThanTheLiveActivitiesAtOnce() {
        let made = snapshot((0..<9).map { digest("s\($0)", "working", updated: Double($0)) })
        XCTAssertEqual(made.agents.count, LiveActivityPlanner.maxActivities)
        XCTAssertEqual(made.agents.first?.id, "s8")
    }

    func testUnfinishedWorkReadsOutOfDateAfterTenMinutes() {
        let made = snapshot([digest("a", "working", updated: 1)])
        XCTAssertFalse(made.stale(now: now.addingTimeInterval(60)))
        XCTAssertTrue(made.stale(now: now.addingTimeInterval(AgentActivitySnapshot.staleAfter + 1)))
        XCTAssertFalse(snapshot([]).stale(now: now.addingTimeInterval(86_400)), "nothing running is never out of date")
    }

    func testTheSameAgentsNeedNoRedraw() throws {
        let made = snapshot([digest("a", "working", updated: 1)])
        var later = made
        later.taken += 30
        XCTAssertTrue(later.sameAgents(as: made))
        XCTAssertFalse(snapshot([]).sameAgents(as: made))
        XCTAssertEqual(try JSONDecoder().decode(AgentActivitySnapshot.self, from: JSONEncoder().encode(made)), made)
    }
}
