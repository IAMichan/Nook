import XCTest

/// The Pull requests page and the notification settings on the phone as on the Mac (`CompanionPullRequests.swift`,
/// `CompanionFeature.pullActions`, `CompanionFeature.notifySettings`).
final class CompanionPullParityTests: XCTestCase {
    private func pull(_ number: Int, group: PullDigest.Group = .mine, state: String = "open", ci: String = "unknown",
                      review: String = "none", conflict: Bool = false, updated: Double = 0, size: Int = 0,
                      labels: [String]? = nil, repo: String = "o/r", author: String = "ada", branch: String = "feature") -> PullDigest {
        PullDigest(url: "https://github.com/\(repo)/pull/\(number)", repo: repo, number: number, title: "Pull \(number)", author: author,
                   state: state, ci: ci, review: review, conflict: conflict, additions: size, deletions: 0, updated: updated,
                   group: group.rawValue, headBranch: branch, baseBranch: "main", labels: labels)
    }

    // MARK: Chips

    func testChipsCountWhatAsksSomethingOfYou() {
        let pulls = [
            pull(1, group: .review),
            pull(2, group: .review, state: "draft"),
            pull(3, group: .review, state: "merged"),
            pull(4, ci: "failing"),
            pull(5, ci: "passing", review: "approved"),
            pull(6, ci: "passing", review: "approved", conflict: true),
            pull(7, group: .watched, ci: "failing"),
        ]
        let counts = PullList.counted(pulls)
        XCTAssertEqual(counts[.review], 2)
        XCTAssertEqual(counts[.failing], 1)
        XCTAssertEqual(counts[.ready], 1)
        // A search narrows the counts, as on the Mac.
        XCTAssertEqual(PullList.counted(pulls, query: "#4")[.failing], 1)
        XCTAssertEqual(PullList.counted(pulls, query: "#4")[.review], 0)
    }

    // MARK: Search

    func testSearchTakesTheMacsQualifiers() {
        let query = PullList.Query.parse("fix label:bug,ui -label:wip author:@Ada repo:o/r branch:feat draft:false review:approved checks:failing")
        XCTAssertEqual(query.words, ["fix"])
        XCTAssertEqual(query.labels, [["bug", "ui"]])
        XCTAssertEqual(query.excludedLabels, ["wip"])
        XCTAssertEqual(query.author, "ada")
        XCTAssertEqual(query.repo, "o/r")
        XCTAssertEqual(query.branch, "feat")
        XCTAssertEqual(query.draft, false)
        XCTAssertEqual(query.review, "approved")
        XCTAssertEqual(query.checks, "failing")
        XCTAssertEqual(PullList.Query.parse("area:ui").labels, [["area:ui"]])
    }

    func testSearchMatchesLabelsRepoAuthorBranchAndNumber() {
        let bug = pull(12, labels: ["Bug"], author: "ada", branch: "fix-login")
        let other = pull(123, labels: ["wip"], repo: "x/y", author: "bob", branch: "main-work")
        let pulls = [bug, other]
        func shown(_ query: String) -> [Int] { PullList.sections(pulls, query: query).flatMap(\.pulls).map(\.number) }
        XCTAssertEqual(shown("label:bug"), [12])
        XCTAssertEqual(shown("-label:wip"), [12])
        XCTAssertEqual(shown("repo:x/y"), [123])
        XCTAssertEqual(shown("author:bob"), [123])
        XCTAssertEqual(shown("branch:login"), [12])
        XCTAssertEqual(shown("#12"), [12])
        XCTAssertEqual(shown("login"), [12])
    }

    // MARK: State, sort and groups

    func testStateFilterKeepsDraftsWithOpen() {
        let pulls = [pull(1), pull(2, state: "draft"), pull(3, state: "merged"), pull(4, state: "closed")]
        XCTAssertEqual(PullList.sections(pulls).flatMap(\.pulls).map(\.number), [1, 2])
        XCTAssertEqual(PullList.sections(pulls, state: .merged).flatMap(\.pulls).map(\.number), [3])
        XCTAssertEqual(PullList.sections(pulls, state: .closed).flatMap(\.pulls).map(\.number), [4])
        XCTAssertEqual(PullList.sections(pulls, state: .all).flatMap(\.pulls).count, 4)
    }

    func testSortsFollowTheMac() {
        let pulls = [pull(1, updated: 10, size: 5), pull(2, ci: "failing", updated: 5, size: 50),
                     pull(3, ci: "passing", review: "approved", updated: 1, size: 1)]
        XCTAssertEqual(PullList.sorted(pulls, by: .attention).map(\.number), [2, 1, 3])
        XCTAssertEqual(PullList.sorted(pulls, by: .readiness).map(\.number), [3, 1, 2])
        XCTAssertEqual(PullList.sorted(pulls, by: .blockedOnMe).map(\.number), [2, 1, 3])
        XCTAssertEqual(PullList.sorted(pulls, by: .recent).map(\.number), [1, 2, 3])
        XCTAssertEqual(PullList.sorted(pulls, by: .oldest).map(\.number), [3, 2, 1])
        XCTAssertEqual(PullList.sorted(pulls, by: .largest).map(\.number), [2, 1, 3])
        XCTAssertEqual(PullList.sorted(pulls, by: .smallest).map(\.number), [3, 1, 2])
    }

    func testGroupsByInvolvementOrRepository() {
        let pulls = [pull(1, repo: "a/one"), pull(2, group: .review, repo: "b/two"), pull(3, group: .watched, repo: "a/one")]
        XCTAssertEqual(PullList.sections(pulls).map(\.key), ["review", "mine", "watched"])
        let byRepo = PullList.sections(pulls, sort: .recent, grouping: .repository)
        XCTAssertEqual(byRepo.map(\.key), ["a/one", "b/two"])
        XCTAssertEqual(byRepo.first?.pulls.map(\.number), [1, 3])
        XCTAssertEqual(PullList.sections(pulls, attention: .review).flatMap(\.pulls).map(\.number), [2])
    }

    // MARK: Actions

    func testActionsFollowTheMacsMenu() {
        let open = PullActionRules.allowed(.init(state: "open", behind: true, autoMergeAllowed: true, failedRuns: 2))
        XCTAssertEqual(Set(open), [.note, .draft, .updateBranch, .rebaseBranch, .autoMergeOn, .rerunFailed, .close, .reply, .resolve, .unresolve])
        let draft = PullActionRules.allowed(.init(state: "draft", autoMergeOn: true))
        XCTAssertTrue(draft.contains(.ready))
        XCTAssertTrue(draft.contains(.autoMergeOff))
        XCTAssertFalse(draft.contains(.autoMergeOn))
        let closed = PullActionRules.allowed(.init(state: "closed", threads: false))
        XCTAssertEqual(closed, [.note, .reopen, .deleteBranch])
        let merged = PullActionRules.allowed(.init(state: "merged", branchDeleted: true, threads: false))
        XCTAssertEqual(merged, [.note])
        // Without push access: no auto-merge, no reruns; a conflict holds auto-merge back too.
        let readOnly = PullActionRules.allowed(.init(state: "open", canPush: false, autoMergeAllowed: true, failedRuns: 1))
        XCTAssertFalse(readOnly.contains(.autoMergeOn))
        XCTAssertFalse(readOnly.contains(.rerunFailed))
        XCTAssertFalse(PullActionRules.allowed(.init(state: "open", conflicted: true, autoMergeAllowed: true)).contains(.autoMergeOn))
        // Another forge without GraphQL ids: no draft switch, no rebase.
        let forge = PullActionRules.allowed(.init(state: "open", hasNodeID: false, behind: true))
        XCTAssertFalse(forge.contains(.draft))
        XCTAssertFalse(forge.contains(.rebaseBranch))
        XCTAssertTrue(forge.contains(.updateBranch))
    }

    func testNewActionsAreCompleteBeforeTheyGo() {
        XCTAssertTrue(CompanionPullAction(kind: .close).isValid)
        XCTAssertFalse(CompanionPullAction(kind: .note, body: "  ").isValid)
        XCTAssertTrue(CompanionPullAction(kind: .note, body: "LGTM").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .reply, body: "Done").isValid)
        XCTAssertTrue(CompanionPullAction(kind: .reply, body: "Done", thread: "line-1").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .resolve).isValid)
        XCTAssertTrue(CompanionPullAction(kind: .resolve, thread: "line-1").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .updateBranch).isValid)
        XCTAssertTrue(CompanionPullAction(kind: .updateBranch, head: "abc").isValid)
        XCTAssertFalse(CompanionPullAction(kind: .autoMergeOn, method: "fast").isValid)
        XCTAssertTrue(CompanionPullAction.Kind.close.isDestructive)
        XCTAssertTrue(CompanionPullAction.Kind.deleteBranch.isDestructive)
        XCTAssertFalse(CompanionPullAction.Kind.ready.isDestructive)
    }

    func testOlderAnswersStillDecode() throws {
        let row = #"{"url":"u","repo":"o/r","number":1,"title":"t","author":"a","state":"open","ci":"passing","review":"none","conflict":false,"group":"mine"}"#
        let decoded = try JSONDecoder().decode(PullDigest.self, from: Data(row.utf8))
        XCTAssertNil(decoded.labels)
        XCTAssertNil(decoded.checksTotal)
    }

    // MARK: Notification settings

    func testNotifySettingsRoundTripThroughPushSettings() {
        var push = PushSettings()
        push.enabled = true
        push.kinds = [.question, .approval]
        let notify = CompanionNotifySettings(push: push, quiet: QuietHours(from: 22, to: 7))
        XCTAssertEqual(notify.kinds, ["approval", "question"])
        XCTAssertEqual(notify.quietHours, QuietHours(from: 22, to: 7))
        var changed = notify
        changed.kinds = ["finished"]
        changed.includeTitle = true
        let applied = changed.applied(to: push)
        XCTAssertEqual(applied.kinds, [.finished])
        XCTAssertTrue(applied.includeTitle)
        XCTAssertEqual(changed.changes(from: notify), "kinds finished · titles on")
        XCTAssertEqual(notify.changes(from: notify), "unchanged")
    }

    func testNotifySettingsRefuseWhatTheMacCannotTake() {
        var notify = CompanionNotifySettings(enabled: true, kinds: ["approval"], onlyWhenAway: true, includeTitle: false)
        XCTAssertTrue(notify.isValid)
        notify.kinds = ["approval", "spam"]
        XCTAssertFalse(notify.isValid)
        notify.kinds = []
        notify.quietFrom = 22
        XCTAssertFalse(notify.isValid)
        notify.quietTo = 24
        XCTAssertFalse(notify.isValid)
        notify.quietTo = 7
        XCTAssertTrue(notify.isValid)
    }

    func testChangingNotifySettingsNeedsOperate() {
        XCTAssertTrue(CompanionScopes.allows(.notifySettings, granted: [.read]))
        XCTAssertFalse(CompanionScopes.allows(.notifySet, granted: [.read]))
        XCTAssertTrue(CompanionScopes.allows(.notifySet, granted: [.operate]))
        XCTAssertTrue(CommandReceipts.keeps(.notifySet))
        XCTAssertFalse(CommandReceipts.keeps(.notifySettings))
        var response = CompanionResponse(id: "1", ok: true)
        response.notify = CompanionNotifySettings(enabled: true, kinds: [], onlyWhenAway: true, includeTitle: false)
        XCTAssertNil(CompanionScopes.redact(response, granted: [.approve]).notify)
    }
}
