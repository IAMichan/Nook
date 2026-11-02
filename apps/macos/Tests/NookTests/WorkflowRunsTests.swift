import XCTest

/// The Actions page: a repository's workflows, their runs and the jobs of a run read from GitHub, the filters, and the
/// repositories it offers.
final class WorkflowRunsTests: XCTestCase {
    private func runJSON(_ id: Int, status: String, conclusion: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "workflow_id": 7, "name": "CI", "display_title": "Fix the build", "run_number": 40 + id,
            "run_attempt": 1, "head_branch": "main", "head_sha": "1a2b3c4d5e6f", "event": "push",
            "actor": ["login": "ada"], "status": status, "created_at": "2026-10-28T12:00:00Z",
            "run_started_at": "2026-10-28T12:00:05Z", "updated_at": "2026-10-28T12:03:05Z",
            "html_url": "https://github.com/o/r/actions/runs/\(id)",
        ]
        if let conclusion { item["conclusion"] = conclusion }
        return item.merging(extra) { _, new in new }
    }

    func testRuns() {
        let runs = WorkflowRunParser.runs(["workflow_runs": [
            runJSON(1, status: "completed", conclusion: "success"),
            runJSON(2, status: "completed", conclusion: "failure"),
            runJSON(3, status: "in_progress"),
            runJSON(4, status: "queued"),
            runJSON(5, status: "completed", conclusion: "skipped"),
        ]])
        XCTAssertEqual(runs.map(\.outcome), [.passing, .failing, .pending, .pending, .skipped])
        XCTAssertEqual(runs.map(\.running), [false, false, true, false, false], "a queued run waits, it does not run")
        XCTAssertEqual(runs[0].title, "Fix the build")
        XCTAssertEqual(runs[0].number, 41)
        XCTAssertEqual(runs[0].actor, "ada")
        XCTAssertEqual(runs[0].shortSHA, "1a2b3c4")
        XCTAssertNotNil(runs[0].finished, "a completed run has an end")
        XCTAssertNil(runs[2].finished, "a running one has none yet")
        XCTAssertEqual(runs[0].check.started, runs[0].started)
        XCTAssertTrue(WorkflowRunParser.runs(nil).isEmpty)
    }

    func testTitleFallsBackToTheCommitThenTheWorkflow() {
        let commit = runJSON(1, status: "completed", conclusion: "success",
                         extra: ["display_title": "", "head_commit": ["message": "Promote to production\n\nDetails"]])
        let bare = runJSON(2, status: "completed", conclusion: "success", extra: ["display_title": ""])
        let runs = WorkflowRunParser.runs(["workflow_runs": [commit, bare]])
        XCTAssertEqual(runs.map(\.title), ["Promote to production", "CI"])
    }

    func testTheActorWhoStartedItAgainWins() {
        let rerun = runJSON(1, status: "queued", extra: ["triggering_actor": ["login": "grace"], "run_attempt": 2])
        let parsed = WorkflowRunParser.runs(["workflow_runs": [rerun]])[0]
        XCTAssertEqual(parsed.actor, "grace")
        XCTAssertEqual(parsed.attempt, 2)
    }

    func testActionsPerState() {
        let runs = WorkflowRunParser.runs(["workflow_runs": [
            runJSON(1, status: "completed", conclusion: "success"),
            runJSON(2, status: "completed", conclusion: "failure"),
            runJSON(3, status: "in_progress"),
        ]])
        XCTAssertEqual(runs.map(\.canRerun), [true, true, false])
        XCTAssertEqual(runs.map(\.canRerunFailed), [false, true, false])
        XCTAssertEqual(runs.map(\.canCancel), [false, false, true])
        XCTAssertEqual(WorkflowRunAction.rerunFailed.path(repo: "o/r", runID: 9), "/repos/o/r/actions/runs/9/rerun-failed-jobs")
        XCTAssertEqual(WorkflowRunAction.cancel.path(repo: "o/r", runID: 9), "/repos/o/r/actions/runs/9/cancel")
        XCTAssertEqual(WorkflowRunAction.rerun.path(repo: "o/r", runID: 9), "/repos/o/r/actions/runs/9/rerun")
    }

    func testFilters() {
        let runs = WorkflowRunParser.runs(["workflow_runs": [
            runJSON(1, status: "completed", conclusion: "success"),
            runJSON(2, status: "completed", conclusion: "cancelled"),
            runJSON(3, status: "waiting"),
        ]])
        XCTAssertEqual(runs.filter(WorkflowRunFilter.all.matches).count, 3)
        XCTAssertEqual(runs.filter(WorkflowRunFilter.active.matches).map(\.id), [3])
        XCTAssertEqual(runs.filter(WorkflowRunFilter.failed.matches).map(\.id), [2])
        XCTAssertTrue(runs[2].waitsForApproval)
        XCTAssertEqual(WorkflowRunParser.runsPath(workflowID: nil), "/actions/runs?per_page=40")
        XCTAssertEqual(WorkflowRunParser.runsPath(workflowID: 7), "/actions/workflows/7/runs?per_page=40")
    }

    func testWorkflowsSkipDisabledOnesAndSortByName() {
        let workflows = WorkflowRunParser.workflows(["workflows": [
            ["id": 1, "name": "Promote", "path": ".github/workflows/promote.yml", "state": "active"],
            ["id": 2, "name": "Old", "path": ".github/workflows/old.yml", "state": "disabled_manually"],
            ["id": 3, "name": "ci", "path": ".github/workflows/ci.yml", "state": "active"],
        ]])
        XCTAssertEqual(workflows.map(\.name), ["ci", "Promote"])
    }

    func testJobsOpenAsChecksWithTheirLog() {
        let jobs = WorkflowRunParser.jobs(["jobs": [
            ["id": 456, "name": "build", "status": "completed", "conclusion": "failure",
             "started_at": "2026-10-28T12:00:00Z", "completed_at": "2026-10-28T12:04:05Z",
             "html_url": "https://github.com/o/r/actions/runs/123/job/456", "steps": [["number": 1], ["number": 2]]],
            ["id": 457, "name": "deploy", "status": "queued", "html_url": "https://github.com/o/r/actions/runs/123/job/457"],
        ]])
        XCTAssertEqual(jobs.map(\.check.outcome), [.failing, .pending])
        XCTAssertEqual(jobs[0].steps, 2)
        XCTAssertEqual(CILogParser.jobID(from: jobs[0].check.url), 456, "the job's log opens like a pull request's check")
        XCTAssertEqual(CILogParser.elapsed(started: jobs[0].check.started, finished: jobs[0].check.finished), 245)
        XCTAssertNil(jobs[1].check.finished)
    }

    func testRepositories() {
        XCTAssertEqual(WorkflowRunParser.repositories([
            ["full_name": "o/app"], ["full_name": "o/old", "archived": true], ["full_name": "o/site"],
        ]), ["o/app", "o/site"])
        XCTAssertEqual(WorkflowRunParser.candidates(selected: "o/site", pushed: ["o/app", "O/Site"],
                                                    pullRequests: ["o/app", "x/lib"], watched: ["acme", "x/tool"]),
                       ["o/site", "o/app", "x/lib", "x/tool"], "each once, an organization is no repository")
    }

    func testRepositoryFromWhatYouType() {
        XCTAssertEqual(WorkflowRunParser.repository(from: " o/app "), "o/app")
        XCTAssertEqual(WorkflowRunParser.repository(from: "https://github.com/o/app/actions/runs/1"), "o/app")
        XCTAssertEqual(WorkflowRunParser.repository(from: "github.com/o/app.git"), "o/app")
        XCTAssertNil(WorkflowRunParser.repository(from: "o"))
        XCTAssertNil(WorkflowRunParser.repository(from: "o/a pp"))
    }

    func testRepositoryStatusForItsTab() {
        func run(_ id: Int, workflow: Int, _ status: String, _ conclusion: String? = nil) -> [String: Any] {
            runJSON(id, status: status, conclusion: conclusion, extra: ["workflow_id": workflow])
        }
        XCTAssertNil(WorkflowRepoStatus(runs: []), "no runs, no mark")
        let calm = WorkflowRepoStatus(runs: WorkflowRunParser.runs(["workflow_runs": [
            run(3, workflow: 1, "completed", "success"), run(2, workflow: 1, "completed", "failure"),
        ]]))
        XCTAssertEqual(calm?.outcome, .passing, "a failure fixed by a newer run is gone")
        XCTAssertEqual(calm?.failing, 0)
        let broken = WorkflowRepoStatus(runs: WorkflowRunParser.runs(["workflow_runs": [
            run(4, workflow: 1, "completed", "success"), run(3, workflow: 2, "completed", "failure"),
        ]]))
        XCTAssertEqual(broken?.outcome, .failing, "one workflow's newest run failed")
        XCTAssertEqual(broken?.failing, 1)
        let busy = WorkflowRepoStatus(runs: WorkflowRunParser.runs(["workflow_runs": [
            run(5, workflow: 1, "in_progress"), run(4, workflow: 2, "completed", "failure"),
        ]]))
        XCTAssertEqual(busy?.outcome, .pending, "something runs")
        XCTAssertEqual(busy?.running, true)
        XCTAssertEqual(busy?.active, 1)
        XCTAssertEqual(busy?.failing, 1)
    }

    func testTabsKeepTheirOrder() {
        XCTAssertEqual(WorkflowRunParser.recent(opening: "o/b", in: ["o/a", "o/b", "o/c"]), ["o/a", "o/b", "o/c"])
        XCTAssertEqual(WorkflowRunParser.recent(opening: "O/B", in: ["o/a", "o/b"]), ["o/a", "o/b"], "ignoring case")
        XCTAssertEqual(WorkflowRunParser.recent(opening: "o/d", in: ["o/a", "o/b", "o/c"], limit: 3), ["o/d", "o/a", "o/b"])
    }

    func testPickerSearch() {
        let repos = ["acme/web", "ada/nook", "acme/nook-site", "x/tool"]
        XCTAssertEqual(WorkflowRunParser.matching("", in: repos), repos)
        XCTAssertEqual(WorkflowRunParser.matching("nook", in: repos), ["ada/nook", "acme/nook-site"])
        XCTAssertEqual(WorkflowRunParser.matching("site", in: repos), ["acme/nook-site"])
        XCTAssertEqual(WorkflowRunParser.matching("acme", in: repos), ["acme/web", "acme/nook-site"], "the owner counts too")
        XCTAssertEqual(WorkflowRunParser.matching("ook", in: repos), ["ada/nook", "acme/nook-site"], "anywhere, after the names")
        XCTAssertEqual(WorkflowRunParser.matching("t", in: repos), ["x/tool", "acme/nook-site"], "a name that starts with it first")
    }

    // MARK: A run without jobs

    private func neighbour(_ id: Int, number: Int, branch: String = "main", conclusion: String, created: String,
                           updated: String) -> [String: Any] {
        runJSON(id, status: "completed", conclusion: conclusion,
                extra: ["run_number": number, "head_branch": branch, "created_at": created, "updated_at": updated,
                        "path": ".github/workflows/build.yml"])
    }

    func testARunCancelledBeforeItsJobsNamesTheRunThatReplacedIt() {
        // As on GitHub: #2520 was cancelled a second after it was queued, because #2523 queued behind it.
        let runs = WorkflowRunParser.runs(["workflow_runs": [
            neighbour(4, number: 2531, conclusion: "success", created: "2026-11-02T08:14:39Z", updated: "2026-11-02T08:30:58Z"),
            neighbour(3, number: 2524, conclusion: "success", created: "2026-11-02T08:08:23Z", updated: "2026-11-02T08:18:57Z"),
            neighbour(2, number: 2523, conclusion: "cancelled", created: "2026-11-02T08:08:23Z", updated: "2026-11-02T08:08:24Z"),
            neighbour(5, number: 2522, branch: "feature", conclusion: "success", created: "2026-11-02T08:08:20Z",
                      updated: "2026-11-02T08:09:00Z"),
            neighbour(1, number: 2520, conclusion: "cancelled", created: "2026-11-02T08:08:19Z", updated: "2026-11-02T08:08:24Z"),
        ]])
        let cancelled = runs[4]
        XCTAssertEqual(WorkflowRunParser.noJobs(repo: "o/r", run: cancelled, jobs: [], others: runs),
                       .replaced(id: 2, number: 2523, url: URL(string: "https://github.com/o/r/actions/runs/2")))
        XCTAssertEqual(WorkflowRunParser.noJobs(repo: "o/r", run: cancelled, jobs: [], others: [runs[0]]), .cancelled,
                       "nothing newer was queued in time: someone or a workflow cancelled it")
    }

    func testWhyARunHasNoJobs() {
        let failed = WorkflowRunParser.runs(["workflow_runs": [
            runJSON(1, status: "completed", conclusion: "startup_failure", extra: ["path": ".github/workflows/ci.yml"]),
        ]])[0]
        XCTAssertEqual(WorkflowRunParser.noJobs(repo: "o/r", run: failed, jobs: [], others: []),
                       .workflowError(path: ".github/workflows/ci.yml",
                                      file: URL(string: "https://github.com/o/r/blob/1a2b3c4d5e6f/.github/workflows/ci.yml")))
        let skipped = WorkflowRunParser.runs(["workflow_runs": [runJSON(1, status: "completed", conclusion: "skipped")]])[0]
        XCTAssertEqual(WorkflowRunParser.noJobs(repo: "o/r", run: skipped, jobs: [], others: []), .skipped)
        let done = WorkflowRunParser.runs(["workflow_runs": [runJSON(1, status: "completed", conclusion: "success")]])[0]
        XCTAssertEqual(WorkflowRunParser.noJobs(repo: "o/r", run: done, jobs: [], others: []), .empty)
        let job = WorkflowRunParser.jobs(["jobs": [["id": 1, "name": "test", "status": "completed", "conclusion": "success"]]])
        XCTAssertNil(WorkflowRunParser.noJobs(repo: "o/r", run: failed, jobs: job, others: []), "a run with jobs has their logs")
        let queued = WorkflowRunParser.runs(["workflow_runs": [runJSON(1, status: "queued")]])[0]
        XCTAssertNil(WorkflowRunParser.noJobs(repo: "o/r", run: queued, jobs: [], others: []), "its jobs are still to come")
        XCTAssertEqual(WorkflowRunParser.workflowFile(repo: "o/r", sha: "abc", path: ".github/workflows/ci.yml@refs/heads/main"),
                       URL(string: "https://github.com/o/r/blob/abc/.github/workflows/ci.yml"))
        XCTAssertNil(WorkflowRunParser.workflowFile(repo: "o/r", sha: "abc", path: "dynamic/pages/pages-build-deployment"))
        XCTAssertEqual(WorkflowRunParser.branchRunsPath(workflowID: 7, branch: "fix/a&b"),
                       "/actions/workflows/7/runs?branch=fix/a%26b&per_page=30")
    }
}
