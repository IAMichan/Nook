import XCTest

final class SubThreadLineageTests: XCTestCase {
    private func link(_ parent: String, _ relation: SubThreadRelation) -> SubThreadLink {
        SubThreadLink(parent: parent, relation: relation)
    }

    // MARK: Listing

    func testDelegatedTasksAndSideChatsLeaveTheListForksAndComparisonsStay() {
        let links = ["task": link("root", .delegated), "side": link("root", .side),
                     "fork": link("root", .fork), "compare": link("root", .comparison)]
        let hidden = SubThreadListing.hidden(links, listed: ["root", "task", "side", "fork", "compare"])
        XCTAssertEqual(hidden, ["task", "side"])
    }

    func testASubThreadWhoseParentIsNotListedKeepsItsOwnRow() {
        let links = ["task": link("archived", .delegated), "side": link("gone", .side)]
        XCTAssertEqual(SubThreadListing.hidden(links, listed: ["task", "side"]), [])
    }

    func testAChainHidesAsAWhole() {
        let links = ["child": link("root", .delegated), "grandchild": link("child", .delegated)]
        XCTAssertEqual(SubThreadListing.hidden(links, listed: ["root", "child", "grandchild"]), ["child", "grandchild"])
        // Without its root the child is a row again, and its own task still sits under it.
        XCTAssertEqual(SubThreadListing.hidden(links, listed: ["child", "grandchild"]), ["grandchild"])
    }

    func testTheNearestListedAncestorStandsInForAnOpenSubThread() {
        let links = ["child": link("root", .delegated), "grandchild": link("child", .side)]
        let hidden: Set<String> = ["child", "grandchild"]
        XCTAssertEqual(SubThreadListing.rowID(for: "grandchild", links: links, hidden: hidden), "root")
        XCTAssertEqual(SubThreadListing.rowID(for: "child", links: links, hidden: hidden), "root")
        XCTAssertEqual(SubThreadListing.rowID(for: "root", links: links, hidden: hidden), "root")
    }

    func testALoopOfParentsResolvesToTheSessionItself() {
        let links = ["a": link("b", .delegated), "b": link("a", .delegated)]
        XCTAssertEqual(SubThreadListing.rowID(for: "a", links: links, hidden: ["a", "b"]), "a")
    }

    // MARK: Requests

    func testADelegatedApprovalGoesUpTheChain() {
        let links = ["child": link("root", .delegated), "grandchild": link("child", .delegated)]
        let flagged = SubThreadListing.requests(links, open: ["grandchild": .approval])
        XCTAssertEqual(flagged, ["child": .approval, "root": .approval])
    }

    func testADelegatedQuestionGoesToTheAgentNotToYou() {
        let links = ["child": link("root", .delegated)]
        XCTAssertEqual(SubThreadListing.requests(links, open: ["child": .question]), [:])
    }

    func testASideChatPassesBothItsApprovalAndItsQuestionToItsParent() {
        let links = ["side": link("root", .side), "other": link("root2", .side)]
        let flagged = SubThreadListing.requests(links, open: ["side": .question, "other": .approval])
        XCTAssertEqual(flagged, ["root": .question, "root2": .approval])
    }

    func testTheChainStopsAtAForkAndApprovalWinsOverQuestion() {
        let links = ["fork": link("root", .fork), "task": link("fork", .delegated), "side": link("fork", .side)]
        let flagged = SubThreadListing.requests(links, open: ["task": .approval, "side": .question])
        XCTAssertEqual(flagged, ["fork": .approval])
    }

    // MARK: Lineage control

    private let start = Date(timeIntervalSince1970: 1_000)

    private func node(_ id: UUID, parent: UUID? = nil, _ relation: SubThreadRelation? = nil,
                      _ status: LineageStatus = .done, at offset: TimeInterval = 0) -> LineageNode {
        LineageNode(id: id, parentID: parent, relation: relation, title: id.uuidString, status: status,
                    createdAt: start.addingTimeInterval(offset))
    }

    func testTheGroupsFollowTheLineagePanel() {
        let (root, parent) = (UUID(), UUID())
        let (fork, live, done, side, grandchild) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let nodes = [
            node(parent),
            node(root, parent: parent, .fork),
            node(fork, parent: root, .fork, at: 5),
            node(live, parent: root, .delegated, .working, at: 2),
            node(done, parent: root, .delegated, .failed, at: 1),
            node(side, parent: root, .side, .question, at: 3),
            node(grandchild, parent: live, .delegated, .working),
        ]
        let groups = LineageLayout.groups(for: root, nodes: nodes)
        XCTAssertEqual(groups.related.map(\.node.id), [parent, fork])
        XCTAssertEqual(groups.related.first?.role, .parent(.fork))
        XCTAssertEqual(groups.active.map(\.node.id), [live])
        XCTAssertEqual(groups.previous.map(\.node.id), [done])
        XCTAssertEqual(groups.sideChats.map(\.node.id), [side])
        XCTAssertEqual(groups.running, 1)
        XCTAssertTrue(groups.needsYou)
    }

    func testASessionWithoutRelationsHasNoGroups() {
        let id = UUID()
        XCTAssertTrue(LineageLayout.groups(for: id, nodes: [node(id), node(UUID())]).isEmpty)
    }

    func testAMissingParentIsLeftOut() {
        let id = UUID()
        XCTAssertTrue(LineageLayout.groups(for: id, nodes: [node(id, parent: UUID(), .delegated)]).isEmpty)
    }
}
