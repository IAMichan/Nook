//! GitHub Actions under Agents › Actions (`ActionsPanel` on the Mac): the workflow runs of one repository, so a CI run or
//! a promote can be followed without opening a pull request first. The repositories to pick from, the workflows of one
//! repository, its runs (filtered by workflow and status), one run with its jobs, and re-running or cancelling a run.
//! A job's steps and log come from `pulls::load_ci_log`, the same as a pull request's check.

use std::future::Future;

use chrono::{DateTime, Utc};
use futures_util::future::join_all;
use serde::Serialize;
use serde_json::Value;

use super::github::{api, headers};
use super::hub::Env;
use super::{date, int, link, list, CResult, ConnectorError, ErrorKind};

/// How a run or a job ended, or that it has not yet. Cancelled is its own mark: nothing broke, someone stopped it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunOutcome {
    Passing,
    Failing,
    Pending,
    Skipped,
    Cancelled,
}

/// GitHub's `status` and `conclusion` as one outcome, the same split as a pull request's checks.
pub fn outcome(status: &str, conclusion: &str) -> RunOutcome {
    if status != "completed" {
        return RunOutcome::Pending;
    }
    match conclusion {
        "cancelled" => RunOutcome::Cancelled,
        "skipped" | "neutral" => RunOutcome::Skipped,
        "failure" | "timed_out" | "action_required" | "startup_failure" | "stale" => RunOutcome::Failing,
        _ => RunOutcome::Passing,
    }
}

/// A repository to pick on the Actions page, with the account that listed it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsRepo {
    pub name: String,
    pub account: String,
    pub pushed: Option<DateTime<Utc>>,
}

/// The repositories of every account, most recently pushed first. `available` is false while GitHub is not connected.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionsRepos {
    pub available: bool,
    pub repos: Vec<ActionsRepo>,
}

/// One active workflow of a repository ("CI", "Promote").
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workflow {
    pub id: i64,
    pub name: String,
    pub path: String,
}

/// One workflow run.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowRun {
    pub id: i64,
    pub workflow_id: i64,
    /// The workflow's name ("CI").
    pub workflow: String,
    /// What GitHub shows as the run's title: the commit subject, the pull request title, or the dispatch name.
    pub title: String,
    pub number: i64,
    pub attempt: i64,
    pub branch: Option<String>,
    pub sha: String,
    /// What started it: push, pull_request, workflow_dispatch, release, schedule…
    pub event: String,
    pub actor: String,
    /// queued, in_progress, waiting, requested, pending or completed.
    pub status: String,
    pub conclusion: Option<String>,
    pub outcome: RunOutcome,
    /// Runs right now; a pending run that has not started yet is queued.
    pub running: bool,
    pub created: Option<DateTime<Utc>>,
    pub started: Option<DateTime<Utc>>,
    /// When it finished (GitHub's last update of a completed run); None while it runs.
    pub finished: Option<DateTime<Utc>>,
    pub url: Option<String>,
}

/// One job of a run.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunJob {
    pub id: i64,
    pub name: String,
    pub outcome: RunOutcome,
    /// The conclusion or status GitHub gave ("success", "in_progress"…).
    pub detail: String,
    pub running: bool,
    pub started: Option<DateTime<Utc>>,
    pub finished: Option<DateTime<Utc>>,
    pub url: Option<String>,
}

/// The runs of a repository, with the account that could read them (the views read a job's log with it).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionRuns {
    pub account: String,
    pub runs: Vec<WorkflowRun>,
}

/// One run with its jobs, for the detail view.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunDetail {
    pub account: String,
    pub run: WorkflowRun,
    pub jobs: Vec<RunJob>,
}

/// The status filter of the run list.
pub const STATUS_FILTERS: [&str; 3] = ["all", "running", "failed"];

/// What can be done to a run from the detail view, with its GitHub endpoint.
pub fn action_path(action: &str) -> Option<&'static str> {
    match action {
        "rerun" => Some("rerun"),
        "rerunFailed" => Some("rerun-failed-jobs"),
        "cancel" => Some("cancel"),
        _ => None,
    }
}

fn text(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}

/// Repositories of `GET /user/repos`, archived ones left out (they run nothing).
pub fn parse_repos(items: &[Value], account: &str) -> Vec<ActionsRepo> {
    items
        .iter()
        .filter(|r| !r["archived"].as_bool().unwrap_or(false))
        .filter_map(|r| {
            let name = r["full_name"].as_str().filter(|n| super::github::is_repository(n))?;
            Some(ActionsRepo { name: name.to_string(), account: account.to_string(), pushed: date(&r["pushed_at"]) })
        })
        .collect()
}

/// Every account's repositories as one list: each repository once (under the first account that listed it), most
/// recently pushed first.
pub fn merge_repos(lists: Vec<Vec<ActionsRepo>>) -> Vec<ActionsRepo> {
    let mut result: Vec<ActionsRepo> = vec![];
    for repo in lists.into_iter().flatten() {
        if !result.iter().any(|r| r.name.eq_ignore_ascii_case(&repo.name)) {
            result.push(repo);
        }
    }
    // A stable sort keeps the accounts' order between repositories pushed at the same moment.
    result.sort_by_key(|r| std::cmp::Reverse(r.pushed));
    result
}

/// The active workflows of `GET /repos/{repo}/actions/workflows`, by name.
pub fn parse_workflows(root: &Value) -> Vec<Workflow> {
    let mut result: Vec<Workflow> = list(&root["workflows"])
        .iter()
        .filter(|w| w["state"].as_str() == Some("active"))
        .filter_map(|w| Some(Workflow { id: int(&w["id"])?, name: text(&w["name"]), path: text(&w["path"]) }))
        .collect();
    result.sort_by_key(|w| w.name.to_lowercase());
    result
}

pub fn parse_run(run: &Value) -> Option<WorkflowRun> {
    let status = run["status"].as_str().unwrap_or("");
    let conclusion = run["conclusion"].as_str().filter(|c| !c.is_empty());
    let title = run["display_title"].as_str().filter(|t| !t.is_empty()).or(run["name"].as_str()).unwrap_or("?");
    let completed = status == "completed";
    Some(WorkflowRun {
        id: int(&run["id"])?,
        workflow_id: int(&run["workflow_id"]).unwrap_or(0),
        workflow: text(&run["name"]),
        title: title.to_string(),
        number: int(&run["run_number"]).unwrap_or(0),
        attempt: int(&run["run_attempt"]).unwrap_or(1),
        branch: run["head_branch"].as_str().filter(|b| !b.is_empty()).map(str::to_string),
        sha: text(&run["head_sha"]),
        event: text(&run["event"]),
        actor: run["triggering_actor"]["login"].as_str().or(run["actor"]["login"].as_str()).unwrap_or("").to_string(),
        status: status.to_string(),
        conclusion: conclusion.map(str::to_string),
        outcome: outcome(status, conclusion.unwrap_or("")),
        running: status == "in_progress",
        created: date(&run["created_at"]),
        // A queued run has no start yet; GitHub fills `run_started_at` with the creation time for those, so only a run
        // that runs or ran gets a clock.
        started: if status == "in_progress" || completed { date(&run["run_started_at"]).or(date(&run["created_at"])) } else { None },
        finished: if completed { date(&run["updated_at"]) } else { None },
        url: link(run["html_url"].as_str()),
    })
}

/// The runs of `GET …/actions/runs`, newest first as GitHub sends them.
pub fn parse_runs(root: &Value) -> Vec<WorkflowRun> {
    list(&root["workflow_runs"]).iter().filter_map(parse_run).collect()
}

/// The jobs of `GET …/actions/runs/{id}/jobs`, in GitHub's order.
pub fn parse_jobs(root: &Value) -> Vec<RunJob> {
    list(&root["jobs"])
        .iter()
        .filter_map(|job| {
            let status = job["status"].as_str().unwrap_or("");
            let conclusion = job["conclusion"].as_str().unwrap_or("");
            let completed = status == "completed";
            Some(RunJob {
                id: int(&job["id"])?,
                name: job["name"].as_str().unwrap_or("?").to_string(),
                outcome: outcome(status, conclusion),
                detail: if completed { conclusion } else { status }.to_string(),
                running: status == "in_progress",
                started: date(&job["started_at"]),
                finished: if completed { date(&job["completed_at"]) } else { None },
                url: link(job["html_url"].as_str()),
            })
        })
        .collect()
}

/// The address of the run list: one workflow's or all of them, with GitHub's own status filter.
pub fn runs_url(repo: &str, workflow: Option<i64>, status: &str) -> String {
    let base = match workflow {
        Some(id) => format!("{}/repos/{repo}/actions/workflows/{id}/runs?per_page=40", api()),
        None => format!("{}/repos/{repo}/actions/runs?per_page=40", api()),
    };
    match status {
        "running" => format!("{base}&status=in_progress"),
        "failed" => format!("{base}&status=failure"),
        _ => base,
    }
}

/// Runs `read` with each account's token in turn until one may read the repository: a 401, 403 or 404 means this
/// account has no access, so the next one tries. Any other error (the network, a rate limit) stops at once.
pub async fn first_with_access<T, F, Fut>(tokens: &[(String, String)], read: F) -> CResult<(String, T)>
where
    F: Fn(String) -> Fut,
    Fut: Future<Output = CResult<T>>,
{
    let mut last = ConnectorError::not_set_up("GitHub");
    for (account, token) in tokens {
        match read(token.clone()).await {
            Ok(value) => return Ok((account.clone(), value)),
            Err(e) if matches!(e.kind, ErrorKind::Auth | ErrorKind::Config) => last = e,
            Err(e) => return Err(e),
        }
    }
    Err(last)
}

/// The repositories each account pushed to lately. An account that fails is left out; only when every account fails
/// is that an error.
pub async fn load_repos(env: &Env, tokens: &[(String, String)]) -> CResult<Vec<ActionsRepo>> {
    let url = format!("{}/user/repos?sort=pushed&per_page=50", api());
    let lists = join_all(tokens.iter().map(|(account, token)| {
        let url = url.clone();
        async move { env.http.get(&url, &headers(token), "GitHub").await.map(|root| parse_repos(list(&root), account)) }
    }))
    .await;
    if lists.iter().all(Result::is_err) {
        if let Some(Err(e)) = lists.into_iter().next() {
            return Err(e);
        }
        return Ok(vec![]);
    }
    Ok(merge_repos(lists.into_iter().filter_map(Result::ok).collect()))
}

pub async fn load_workflows(env: &Env, tokens: &[(String, String)], repo: &str) -> CResult<Vec<Workflow>> {
    let url = format!("{}/repos/{repo}/actions/workflows?per_page=100", api());
    let (_, root) = first_with_access(tokens, |token| {
        let url = url.clone();
        async move { env.http.get(&url, &headers(&token), "GitHub").await }
    })
    .await?;
    Ok(parse_workflows(&root))
}

pub async fn load_runs(env: &Env, tokens: &[(String, String)], repo: &str, workflow: Option<i64>, status: &str) -> CResult<ActionRuns> {
    let url = runs_url(repo, workflow, status);
    let (account, root) = first_with_access(tokens, |token| {
        let url = url.clone();
        async move { env.http.get(&url, &headers(&token), "GitHub").await }
    })
    .await?;
    Ok(ActionRuns { account, runs: parse_runs(&root) })
}

/// One run and its jobs (the latest attempt's), read together so the header and the jobs agree.
pub async fn load_run(env: &Env, tokens: &[(String, String)], repo: &str, run: i64) -> CResult<RunDetail> {
    let base = format!("{}/repos/{repo}/actions/runs/{run}", api());
    let (account, (run, jobs)) = first_with_access(tokens, |token| {
        let base = base.clone();
        async move {
            let h = headers(&token);
            let jobs_url = format!("{base}/jobs?per_page=100");
            let (run, jobs) = futures_util::join!(env.http.get(&base, &h, "GitHub"), env.http.get(&jobs_url, &h, "GitHub"));
            Ok((run?, jobs?))
        }
    })
    .await?;
    let run = parse_run(&run).ok_or_else(|| ConnectorError::new("GitHub gaf een onverwacht antwoord."))?;
    Ok(RunDetail { account, run, jobs: parse_jobs(&jobs) })
}

/// The error of a refused run action, in GitHub's own words when it gave some ("Cannot cancel a workflow run that is
/// completed.").
fn action_error(status: u16, bytes: &[u8]) -> ConnectorError {
    let message =
        serde_json::from_slice::<Value>(bytes).ok().and_then(|v| v["message"].as_str().map(str::to_string)).filter(|m| !m.is_empty());
    match message {
        Some(m) => ConnectorError::kind(format!("GitHub: {m} ({status})"), ErrorKind::for_http(status)),
        None => super::status_error(status, "GitHub"),
    }
}

/// Re-runs (all or only the failed jobs) or cancels a run, with the first account allowed to. Returns that account.
pub async fn run_action(env: &Env, tokens: &[(String, String)], repo: &str, run: i64, action: &str) -> CResult<String> {
    let path = action_path(action).ok_or_else(|| ConnectorError::new("Onbekende actie."))?;
    let url = format!("{}/repos/{repo}/actions/runs/{run}/{path}", api());
    let (account, ()) = first_with_access(tokens, |token| {
        let url = url.clone();
        async move {
            let (status, bytes) = env.http.send("POST", &url, &headers(&token), None, "GitHub").await?;
            if (200..300).contains(&status) {
                Ok(())
            } else {
                Err(action_error(status, &bytes))
            }
        }
    })
    .await?;
    Ok(account)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn outcomes_follow_status_and_conclusion() {
        assert_eq!(outcome("in_progress", ""), RunOutcome::Pending);
        assert_eq!(outcome("queued", ""), RunOutcome::Pending);
        assert_eq!(outcome("completed", "success"), RunOutcome::Passing);
        assert_eq!(outcome("completed", "failure"), RunOutcome::Failing);
        assert_eq!(outcome("completed", "timed_out"), RunOutcome::Failing);
        assert_eq!(outcome("completed", "cancelled"), RunOutcome::Cancelled);
        assert_eq!(outcome("completed", "skipped"), RunOutcome::Skipped);
    }

    #[test]
    fn parses_a_run() {
        let root = json!({"workflow_runs": [{
            "id": 7, "workflow_id": 3, "name": "CI", "display_title": "Fix the bar", "run_number": 42, "run_attempt": 2,
            "head_branch": "main", "head_sha": "abcdef1234", "event": "push", "status": "completed", "conclusion": "failure",
            "actor": {"login": "ada"}, "triggering_actor": {"login": "bob"},
            "created_at": "2026-10-20T12:00:00Z", "run_started_at": "2026-10-20T12:00:05Z", "updated_at": "2026-10-20T12:03:00Z",
            "html_url": "https://github.com/acme/web/actions/runs/7"
        }, {"name": "no id"}]});
        let runs = parse_runs(&root);
        assert_eq!(runs.len(), 1);
        let run = &runs[0];
        assert_eq!((run.id, run.workflow_id, run.number, run.attempt), (7, 3, 42, 2));
        assert_eq!(run.title, "Fix the bar");
        assert_eq!(run.actor, "bob");
        assert_eq!(run.outcome, RunOutcome::Failing);
        assert!(!run.running);
        assert!(run.started.is_some() && run.finished.is_some());
        assert_eq!(run.url.as_deref(), Some("https://github.com/acme/web/actions/runs/7"));
    }

    #[test]
    fn a_queued_run_has_no_clock() {
        let run = parse_run(&json!({"id": 1, "status": "queued", "name": "Promote", "run_started_at": "2026-10-20T12:00:05Z"})).unwrap();
        assert_eq!(run.title, "Promote");
        assert!(run.started.is_none() && run.finished.is_none());
        assert_eq!(run.outcome, RunOutcome::Pending);
    }

    #[test]
    fn parses_jobs() {
        let jobs = parse_jobs(&json!({"jobs": [
            {"id": 9, "name": "test", "status": "in_progress", "started_at": "2026-10-20T12:00:05Z", "html_url": "https://github.com/acme/web/actions/runs/7/job/9"},
            {"id": 10, "name": "lint", "status": "completed", "conclusion": "success", "completed_at": "2026-10-20T12:01:00Z"}
        ]}));
        assert_eq!(jobs.len(), 2);
        assert!(jobs[0].running);
        assert_eq!(jobs[0].detail, "in_progress");
        assert_eq!(jobs[1].outcome, RunOutcome::Passing);
        assert_eq!(jobs[1].detail, "success");
        assert_eq!(super::super::pulls::job_id(jobs[0].url.as_deref().unwrap()), Some(9));
    }

    #[test]
    fn only_active_workflows_by_name() {
        let flows = parse_workflows(&json!({"workflows": [
            {"id": 2, "name": "Promote", "path": ".github/workflows/promote.yml", "state": "active"},
            {"id": 1, "name": "ci", "path": ".github/workflows/ci.yml", "state": "active"},
            {"id": 3, "name": "Old", "path": ".github/workflows/old.yml", "state": "disabled_manually"}
        ]}));
        assert_eq!(flows.iter().map(|w| w.id).collect::<Vec<_>>(), vec![1, 2]);
    }

    #[test]
    fn repos_merge_once_newest_first() {
        let work = parse_repos(
            &[json!({"full_name": "acme/web", "pushed_at": "2026-10-01T00:00:00Z"}), json!({"full_name": "acme/old", "archived": true})],
            "work",
        );
        let home =
            parse_repos(&[json!({"full_name": "ada/site", "pushed_at": "2026-10-05T00:00:00Z"}), json!({"full_name": "Acme/Web"})], "home");
        let merged = merge_repos(vec![work, home]);
        assert_eq!(merged.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), vec!["ada/site", "acme/web"]);
        assert_eq!(merged[1].account, "work");
    }

    #[test]
    fn run_list_filters() {
        assert!(runs_url("acme/web", None, "all").ends_with("/repos/acme/web/actions/runs?per_page=40"));
        assert!(
            runs_url("acme/web", Some(5), "running").ends_with("/repos/acme/web/actions/workflows/5/runs?per_page=40&status=in_progress")
        );
        assert!(runs_url("acme/web", None, "failed").ends_with("&status=failure"));
        assert_eq!(action_path("rerunFailed"), Some("rerun-failed-jobs"));
        assert_eq!(action_path("delete"), None);
    }
}
