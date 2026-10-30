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
}
