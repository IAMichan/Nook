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
use super::{date, int, link, list, with_query, CResult, ConnectorError, ErrorKind};

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
    /// The workflow file it ran from (".github/workflows/ci.yml"); empty when GitHub gave none.
    pub path: String,
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
    /// Why a finished run has no jobs. GitHub keeps no log for such a run, so this is all there is to read.
    pub no_jobs: Option<NoJobs>,
}

/// Why a finished run has no jobs, worked out from the run itself: GitHub keeps no log and no annotation for a run that
/// never started a job (its log archive is empty), so the page says what it can read from the run and its neighbours.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum NoJobs {
    /// Cancelled before a job started because a newer run of the same workflow on the same branch took its place
    /// (the workflow's `concurrency` group).
    Replaced { id: i64, number: i64, url: Option<String> },
    /// Cancelled before a job started, by someone or by another workflow.
    Cancelled,
    /// GitHub could not start the workflow, nearly always an error in its file.
    WorkflowError { path: String, file: Option<String> },
    /// Every job was skipped by its condition.
    Skipped,
    /// It waits for someone to approve it.
    Approval,
    /// Finished without jobs and without a reason GitHub gives.
    Empty,
}

/// How long after a run was cancelled its replacement may have been created: GitHub cancels the older run within a
/// few seconds of queueing the newer one.
const REPLACEMENT_WINDOW_SECONDS: i64 = 10;

/// The run that took `run`'s place: the first newer run of the same workflow on the same branch created before (or
/// just after) `run` was cancelled.
pub fn replacement<'a>(run: &WorkflowRun, others: &'a [WorkflowRun]) -> Option<&'a WorkflowRun> {
    let cancelled = run.finished?;
    let latest = cancelled + chrono::Duration::seconds(REPLACEMENT_WINDOW_SECONDS);
    others
        .iter()
        .filter(|o| o.id != run.id && o.workflow_id == run.workflow_id && o.branch == run.branch && o.number > run.number)
        .filter(|o| o.created.is_some_and(|c| c <= latest))
        .min_by_key(|o| o.number)
}

/// The workflow file at the run's commit on github.com, for a run that could not start.
pub fn workflow_file(repo: &str, sha: &str, path: &str) -> Option<String> {
    if !path.starts_with(".github/") || sha.is_empty() || !super::github::is_repository(repo) {
        return None;
    }
    // A reusable workflow's run path reads ".github/workflows/x.yml@refs/heads/main"; the file is the part before the @.
    let file = path.split('@').next().unwrap_or(path);
    Some(format!("https://github.com/{repo}/blob/{sha}/{file}"))
}

/// Why `run` has no jobs, or None while it still runs or when it has jobs. `others` are the latest runs of its workflow
/// on its branch, to find the run that replaced a cancelled one.
pub fn no_jobs(repo: &str, run: &WorkflowRun, jobs: &[RunJob], others: &[WorkflowRun]) -> Option<NoJobs> {
    if run.status != "completed" || !jobs.is_empty() {
        return None;
    }
    Some(match run.conclusion.as_deref().unwrap_or("") {
        "cancelled" => match replacement(run, others) {
            Some(newer) => NoJobs::Replaced { id: newer.id, number: newer.number, url: newer.url.clone() },
            None => NoJobs::Cancelled,
        },
        // A run fails without a single job only when GitHub could not start the workflow.
        "startup_failure" | "failure" => NoJobs::WorkflowError { path: run.path.clone(), file: workflow_file(repo, &run.sha, &run.path) },
        "skipped" => NoJobs::Skipped,
        "action_required" => NoJobs::Approval,
        _ => NoJobs::Empty,
    })
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
        path: text(&run["path"]),
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

/// The address of the run list: one workflow's or all of them, with GitHub's own status filter. Without the pull
/// requests of each run: GitHub works those out per run, which makes the list slow and large, and the page shows none.
pub fn runs_url(repo: &str, workflow: Option<i64>, status: &str) -> String {
    let base = match workflow {
        Some(id) => format!("{}/repos/{repo}/actions/workflows/{id}/runs?per_page=40&exclude_pull_requests=true", api()),
        None => format!("{}/repos/{repo}/actions/runs?per_page=40&exclude_pull_requests=true", api()),
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
    let jobs = parse_jobs(&jobs);
    // Only a run cancelled before its first job needs its neighbours: the newer run that took its place. Reading them
    // is a best effort; without them the page still says the run was cancelled before it started.
    let mut others = vec![];
    if run.status == "completed" && jobs.is_empty() && run.conclusion.as_deref() == Some("cancelled") {
        if let (Some(branch), Some((_, token))) = (&run.branch, tokens.iter().find(|(a, _)| *a == account)) {
            let url = with_query(
                &format!("{}/repos/{repo}/actions/workflows/{}/runs", api(), run.workflow_id),
                &[("branch", branch.clone()), ("per_page", "30".into()), ("exclude_pull_requests", "true".into())],
            );
            if let Ok(root) = env.http.get(&url, &headers(token), "GitHub").await {
                others = parse_runs(&root);
            }
        }
    }
    let no_jobs = no_jobs(repo, &run, &jobs, &others);
    Ok(RunDetail { account, run, jobs, no_jobs })
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

// Starting a workflow by hand (workflow_dispatch)

/// One input of a workflow's `workflow_dispatch` trigger, as its file declares it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchInput {
    pub name: String,
    pub description: String,
    pub required: bool,
    pub default: Option<String>,
    /// string, boolean, choice, number or environment; an unknown type reads as string.
    pub kind: String,
    /// The choices of a `choice` input, in file order.
    pub options: Vec<String>,
}

/// A workflow on the "Run workflow" form: `inputs` is None when its file has no `workflow_dispatch` trigger (or could not
/// be read), so it cannot be started by hand.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchWorkflow {
    pub id: i64,
    pub name: String,
    pub path: String,
    pub inputs: Option<Vec<DispatchInput>>,
}

/// What the "Run workflow" form needs: the branches (default first) and each workflow's inputs at the default branch.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchForm {
    pub account: String,
    pub default_branch: String,
    pub branches: Vec<String>,
    pub workflows: Vec<DispatchWorkflow>,
}

/// One line of a workflow file: its indentation, the text without its comment, and the line as written (for block
/// scalars, where a `#` is text).
struct YamlLine<'a> {
    indent: usize,
    text: String,
    raw: &'a str,
}

impl YamlLine<'_> {
    /// Blank or only a comment: no part of a mapping.
    fn empty(&self) -> bool {
        self.text.is_empty()
    }
}

/// The line without a `# comment`: a `#` at the start or after a space, outside a quoted scalar. A quote only opens a
/// scalar where one can start (after `: `, `- `, `[`, `,`, `{` or at the start), so "don't" stays a plain word.
fn strip_comment(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut quote: Option<char> = None;
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match quote {
            Some('\'') => {
                if c == '\'' {
                    if chars.get(i + 1) == Some(&'\'') {
                        out.push_str("''");
                        i += 2;
                        continue;
                    }
                    quote = None;
                }
            }
            Some(_) => {
                if c == '\\' && i + 1 < chars.len() {
                    out.push(c);
                    out.push(chars[i + 1]);
                    i += 2;
                    continue;
                }
                if c == '"' {
                    quote = None;
                }
            }
            None => {
                let before = out.trim_end().chars().last();
                if c == '#' && (i == 0 || chars[i - 1].is_whitespace()) {
                    break;
                }
                if (c == '\'' || c == '"') && matches!(before, None | Some(':' | '-' | '[' | ',' | '{')) {
                    quote = Some(c);
                }
            }
        }
        out.push(c);
        i += 1;
    }
    out.trim().to_string()
}

fn yaml_lines(text: &str) -> Vec<YamlLine<'_>> {
    text.lines()
        .map(|raw| {
            let raw = raw.trim_end_matches('\r');
            YamlLine { indent: raw.len() - raw.trim_start_matches(' ').len(), text: strip_comment(raw), raw }
        })
        .collect()
}

/// A scalar without its quotes: `'it''s'` → it's, `"a \"b\""` → a "b", `plain` → plain.
fn yaml_scalar(value: &str) -> String {
    let v = value.trim();
    if v.len() >= 2 && v.starts_with('\'') && v.ends_with('\'') {
        return v[1..v.len() - 1].replace("''", "'");
    }
    if v.len() >= 2 && v.starts_with('"') && v.ends_with('"') {
        let mut out = String::new();
        let mut chars = v[1..v.len() - 1].chars();
        while let Some(c) = chars.next() {
            if c != '\\' {
                out.push(c);
                continue;
            }
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => out.push(other),
                None => {}
            }
        }
        return out;
    }
    if v == "~" || v == "null" {
        return String::new();
    }
    v.to_string()
}

/// The items of a flow list (`[a, 'b, c']`), quotes respected.
fn flow_list(value: &str) -> Vec<String> {
    let inner = value.trim().trim_start_matches('[').trim_end_matches(']');
    let mut items = vec![];
    let mut current = String::new();
    let mut quote: Option<char> = None;
    for c in inner.chars() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '\'' || c == '"' => quote = Some(c),
            None if c == ',' => {
                items.push(std::mem::take(&mut current));
                continue;
            }
            None => {}
        }
        current.push(c);
    }
    items.push(current);
    items.into_iter().map(|i| yaml_scalar(&i)).filter(|i| !i.is_empty()).collect()
}

/// `key: rest` of a mapping line; the key unquoted. None for a line that is no mapping entry.
fn split_key(text: &str) -> Option<(String, String)> {
    let (key, rest) = if text.starts_with('\'') || text.starts_with('"') {
        let q = text.chars().next()?;
        let end = text[1..].find(q)? + 1;
        (yaml_scalar(&text[..=end]), text[end + 1..].trim_start())
    } else {
        let at = text.char_indices().find(|&(i, c)| c == ':' && text[i + 1..].chars().next().is_none_or(char::is_whitespace))?.0;
        (text[..at].trim().to_string(), &text[at..])
    };
    let rest = rest.strip_prefix(':')?;
    Some((key, rest.trim().to_string()))
}

/// One entry of a block mapping: its key, the value on its own line, and the lines below it that belong to it.
struct Entry {
    key: String,
    value: String,
    children: std::ops::Range<usize>,
}

/// The entries of the block mapping in `range` (all at the indentation of its first line), in file order.
fn entries(lines: &[YamlLine], range: std::ops::Range<usize>) -> Vec<Entry> {
    let Some(indent) = lines[range.clone()].iter().find(|l| !l.empty()).map(|l| l.indent) else { return vec![] };
    let mut result = vec![];
    let mut i = range.start;
    while i < range.end {
        let line = &lines[i];
        if line.empty() || line.indent != indent {
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < range.end && (lines[end].empty() || lines[end].indent > indent) {
            end += 1;
        }
        if let Some((key, value)) = split_key(&line.text) {
            result.push(Entry { key, value, children: i + 1..end });
        }
        i = end;
    }
    result
}

/// The items of a block sequence (`- a` lines) in `range`.
fn sequence(lines: &[YamlLine], range: std::ops::Range<usize>) -> Vec<String> {
    lines[range]
        .iter()
        .filter_map(|l| l.text.strip_prefix('-').filter(|rest| rest.is_empty() || rest.starts_with(' ')))
        .map(yaml_scalar)
        .filter(|i| !i.is_empty())
        .collect()
}

/// A scalar value: on the key's line, or a `|` / `>` block scalar below it.
fn entry_text(lines: &[YamlLine], entry: &Entry) -> String {
    let v = entry.value.as_str();
    if !(v.starts_with('|') || v.starts_with('>')) {
        return yaml_scalar(v);
    }
    let body: Vec<&YamlLine> = lines[entry.children.clone()].iter().collect();
    let indent = body.iter().filter(|l| !l.raw.trim().is_empty()).map(|l| l.indent).min().unwrap_or(0);
    let rows: Vec<&str> = body.iter().map(|l| l.raw.get(indent..).unwrap_or("").trim_end()).collect();
    let text = if v.starts_with('|') {
        rows.join("\n")
    } else {
        // Folded: lines join with a space, an empty line is a line break.
        let mut out = String::new();
        for row in rows {
            if row.is_empty() {
                out.push('\n');
            } else {
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push(' ');
                }
                out.push_str(row);
            }
        }
        out
    };
    text.trim().to_string()
}

fn truthy(value: &str) -> bool {
    matches!(yaml_scalar(value).to_lowercase().as_str(), "true" | "yes" | "on")
}

fn parse_input(lines: &[YamlLine], name: String, children: std::ops::Range<usize>) -> DispatchInput {
    let mut input =
        DispatchInput { name, description: String::new(), required: false, default: None, kind: "string".into(), options: vec![] };
    for prop in entries(lines, children) {
        match prop.key.as_str() {
            "description" => input.description = entry_text(lines, &prop),
            "required" => input.required = truthy(&prop.value),
            "default" => input.default = Some(entry_text(lines, &prop)),
            "type" => {
                let kind = yaml_scalar(&prop.value).to_lowercase();
                if ["string", "boolean", "choice", "number", "environment"].contains(&kind.as_str()) {
                    input.kind = kind;
                }
            }
            "options" if prop.value.starts_with('[') => input.options = flow_list(&prop.value),
            "options" => input.options = sequence(lines, prop.children.clone()),
            _ => {}
        }
    }
    input
}

/// The inputs of a workflow's `workflow_dispatch` trigger, in file order; None when the file has no such trigger.
/// Reads only the top-level `on:` block (also written `"on":`, `'on':` or YAML 1.1's `true:`) in its usual forms:
/// `on: workflow_dispatch`, `on: [push, workflow_dispatch]`, a list of events, or a mapping whose `workflow_dispatch`
/// entry may hold `inputs` with description, required, default, type and options.
pub fn dispatch_inputs(yaml: &str) -> Option<Vec<DispatchInput>> {
    let lines = yaml_lines(yaml);
    let top = entries(&lines, 0..lines.len());
    let on = top.iter().find(|e| matches!(e.key.as_str(), "on" | "true" | "True" | "ON" | "On"))?;
    let is_dispatch = |name: &str| yaml_scalar(name) == "workflow_dispatch";
    let value = on.value.as_str();
    if value.starts_with('[') {
        return flow_list(value).iter().any(|e| e == "workflow_dispatch").then(Vec::new);
    }
    if value.starts_with('{') {
        let inner = value.trim_start_matches('{').trim_end_matches('}');
        return inner.split(',').any(|part| is_dispatch(part.split(':').next().unwrap_or(""))).then(Vec::new);
    }
    if !value.is_empty() {
        return is_dispatch(value).then(Vec::new);
    }
    if sequence(&lines, on.children.clone()).iter().any(|e| e == "workflow_dispatch") {
        return Some(vec![]);
    }
    let dispatch = entries(&lines, on.children.clone()).into_iter().find(|e| e.key == "workflow_dispatch")?;
    let Some(inputs) = entries(&lines, dispatch.children.clone()).into_iter().find(|e| e.key == "inputs") else { return Some(vec![]) };
    Some(entries(&lines, inputs.children.clone()).into_iter().map(|input| parse_input(&lines, input.key, input.children)).collect())
}

/// The branch names of `GET /repos/{repo}/branches`, the default branch first.
pub fn parse_branches(root: &Value, default_branch: &str) -> Vec<String> {
    let mut names: Vec<String> = list(root).iter().filter_map(|b| b["name"].as_str().map(str::to_string)).collect();
    names.retain(|n| n != default_branch);
    if !default_branch.is_empty() {
        names.insert(0, default_branch.to_string());
    }
    names
}

/// The text of a file from `GET /repos/{repo}/contents/{path}`: GitHub sends it base64-encoded, wrapped every 60 chars.
pub fn file_content(root: &Value) -> Option<String> {
    use base64::Engine;
    let encoded: String = root["content"].as_str()?.chars().filter(|c| !c.is_whitespace()).collect();
    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded).ok()?;
    String::from_utf8(bytes).ok()
}

/// The workflow file's path for the contents endpoint, or None for a workflow without a file of its own (a dynamic one
/// like "dynamic/pages/pages-build-deployment").
fn workflow_file_path(path: &str) -> Option<String> {
    let file = path.split('@').next().unwrap_or(path);
    if !file.starts_with(".github/workflows/") || file.contains("..") {
        return None;
    }
    const SEGMENT: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC.remove(b'.').remove(b'-').remove(b'_');
    let encoded: Vec<String> = file.split('/').map(|s| percent_encoding::utf8_percent_encode(s, SEGMENT).to_string()).collect();
    Some(encoded.join("/"))
}

/// The repository's branches and the inputs of every workflow at its default branch, for the "Run workflow" form. A
/// workflow file that cannot be read counts as one that cannot be started by hand.
pub async fn load_dispatch_form(env: &Env, tokens: &[(String, String)], repo: &str) -> CResult<DispatchForm> {
    let base = format!("{}/repos/{repo}", api());
    let (account, (info, branches, flows)) = first_with_access(tokens, |token| {
        let base = base.clone();
        async move {
            let h = headers(&token);
            let (branches_url, flows_url) = (format!("{base}/branches?per_page=100"), format!("{base}/actions/workflows?per_page=100"));
            let (info, branches, flows) = futures_util::join!(
                env.http.get(&base, &h, "GitHub"),
                env.http.get(&branches_url, &h, "GitHub"),
                env.http.get(&flows_url, &h, "GitHub"),
            );
            Ok((info?, branches.unwrap_or(Value::Null), flows?))
        }
    })
    .await?;
    let default_branch = text(&info["default_branch"]);
    let token = tokens.iter().find(|(a, _)| *a == account).map(|(_, t)| t.clone()).unwrap_or_default();
    let workflows = join_all(parse_workflows(&flows).into_iter().map(|w| {
        let (token, default_branch) = (token.clone(), default_branch.clone());
        let url = workflow_file_path(&w.path).map(|file| with_query(&format!("{base}/contents/{file}"), &[("ref", default_branch)]));
        async move {
            let inputs = match url {
                Some(url) => env.http.get(&url, &headers(&token), "GitHub").await.ok().and_then(|root| file_content(&root)),
                None => None,
            }
            .and_then(|yaml| dispatch_inputs(&yaml));
            DispatchWorkflow { id: w.id, name: w.name, path: w.path, inputs }
        }
    }))
    .await;
    Ok(DispatchForm { account, branches: parse_branches(&branches, &default_branch), default_branch, workflows })
}

/// The body of a dispatch: the branch, the inputs that were filled in, and the ask for the new run's id.
pub fn dispatch_body(git_ref: &str, inputs: &std::collections::BTreeMap<String, String>) -> Value {
    let filled: serde_json::Map<String, Value> =
        inputs.iter().filter(|(_, v)| !v.is_empty()).map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
    serde_json::json!({"ref": git_ref, "inputs": filled, "return_run_details": true})
}

/// Starts a workflow on `git_ref` with the first account allowed to. Returns that account and the new run's id when
/// GitHub gave it (a 200 with run details; an older GitHub answers 204 without a body).
pub async fn dispatch_workflow(
    env: &Env,
    tokens: &[(String, String)],
    repo: &str,
    workflow: i64,
    git_ref: &str,
    inputs: &std::collections::BTreeMap<String, String>,
) -> CResult<(String, Option<i64>)> {
    let url = format!("{}/repos/{repo}/actions/workflows/{workflow}/dispatches", api());
    let body = dispatch_body(git_ref, inputs);
    first_with_access(tokens, |token| {
        let (url, body) = (url.clone(), body.clone());
        async move {
            let (status, bytes) = env.http.send("POST", &url, &headers(&token), Some(&body), "GitHub").await?;
            if !(200..300).contains(&status) {
                return Err(action_error(status, &bytes));
            }
            Ok(serde_json::from_slice::<Value>(&bytes).ok().and_then(|v| int(&v["workflow_run_id"])))
        }
    })
    .await
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

    fn run(id: i64, number: i64, branch: &str, conclusion: &str, created: &str, updated: &str) -> WorkflowRun {
        parse_run(&json!({
            "id": id, "workflow_id": 3, "name": "Build", "run_number": number, "head_branch": branch, "head_sha": "abc1234",
            "status": "completed", "conclusion": conclusion, "created_at": created, "updated_at": updated,
            "path": ".github/workflows/build.yml", "html_url": format!("https://github.com/acme/web/actions/runs/{id}")
        }))
        .unwrap()
    }

    #[test]
    fn a_run_cancelled_before_its_jobs_names_the_run_that_replaced_it() {
        // As on GitHub: #2520 was cancelled a second after it was queued, because #2523 queued behind it.
        let cancelled = run(1, 2520, "main", "cancelled", "2026-11-02T08:08:19Z", "2026-11-02T08:08:24Z");
        let others = vec![
            run(4, 2531, "main", "success", "2026-11-02T08:14:39Z", "2026-11-02T08:30:58Z"),
            run(3, 2524, "main", "success", "2026-11-02T08:08:23Z", "2026-11-02T08:18:57Z"),
            run(2, 2523, "main", "cancelled", "2026-11-02T08:08:23Z", "2026-11-02T08:08:24Z"),
            run(5, 2522, "feature", "success", "2026-11-02T08:08:20Z", "2026-11-02T08:09:00Z"),
            cancelled.clone(),
        ];
        assert_eq!(
            no_jobs("acme/web", &cancelled, &[], &others),
            Some(NoJobs::Replaced { id: 2, number: 2523, url: Some("https://github.com/acme/web/actions/runs/2".into()) })
        );
        // Nothing newer was queued in time: someone (or a workflow) cancelled it.
        assert_eq!(no_jobs("acme/web", &cancelled, &[], &others[..1]), Some(NoJobs::Cancelled));
    }

    #[test]
    fn why_a_run_has_no_jobs() {
        let failed = run(1, 9, "main", "startup_failure", "2026-11-02T08:00:00Z", "2026-11-02T08:00:01Z");
        assert_eq!(
            no_jobs("acme/web", &failed, &[], &[]),
            Some(NoJobs::WorkflowError {
                path: ".github/workflows/build.yml".into(),
                file: Some("https://github.com/acme/web/blob/abc1234/.github/workflows/build.yml".into())
            })
        );
        let skipped = run(1, 9, "main", "skipped", "2026-11-02T08:00:00Z", "2026-11-02T08:00:01Z");
        assert_eq!(no_jobs("acme/web", &skipped, &[], &[]), Some(NoJobs::Skipped));
        let done = run(1, 9, "main", "success", "2026-11-02T08:00:00Z", "2026-11-02T08:00:01Z");
        assert_eq!(no_jobs("acme/web", &done, &[], &[]), Some(NoJobs::Empty));
        let job = parse_jobs(&json!({"jobs": [{"id": 1, "name": "test", "status": "completed", "conclusion": "success"}]}));
        assert_eq!(no_jobs("acme/web", &failed, &job, &[]), None, "a run with jobs has their logs");
        let queued = parse_run(&json!({"id": 1, "status": "queued"})).unwrap();
        assert_eq!(no_jobs("acme/web", &queued, &[], &[]), None, "its jobs are still to come");
        assert_eq!(
            workflow_file("acme/web", "abc", ".github/workflows/ci.yml@refs/heads/main").as_deref(),
            Some("https://github.com/acme/web/blob/abc/.github/workflows/ci.yml")
        );
        assert_eq!(workflow_file("acme/web", "abc", "dynamic/pages/pages-build-deployment"), None);
    }

    fn names(inputs: &[DispatchInput]) -> Vec<&str> {
        inputs.iter().map(|i| i.name.as_str()).collect()
    }

    #[test]
    fn dispatch_trigger_in_short_forms() {
        assert_eq!(dispatch_inputs("name: X\non: workflow_dispatch\njobs: {}\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("on: [push, workflow_dispatch]\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("on: [ push, 'workflow_dispatch' ]  # by hand too\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("on: [push, pull_request]\n"), None);
        assert_eq!(dispatch_inputs("on: push\n"), None);
        assert_eq!(dispatch_inputs("\"on\": workflow_dispatch\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("'on':\n  workflow_dispatch:\n"), Some(vec![]));
        // YAML 1.1 reads a bare `on` as true; some tools write it back that way.
        assert_eq!(dispatch_inputs("true:\n  push:\n  workflow_dispatch: {}\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("on:\n  - push\n  - workflow_dispatch\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("on: {push: {}, workflow_dispatch: {}}\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("on:\n  workflow_dispatch: # by hand\n  push:\n    branches: [main]\n"), Some(vec![]));
        assert_eq!(dispatch_inputs("name: no trigger\njobs:\n  a:\n    runs-on: x\n"), None);
    }

    #[test]
    fn a_workflow_without_dispatch_cannot_be_started() {
        let yaml =
            "name: CI\non:\n  push:\n    branches: [main]\n  pull_request:\njobs:\n  workflow_dispatch:\n    runs-on: ubuntu-latest\n";
        assert_eq!(dispatch_inputs(yaml), None, "a job named workflow_dispatch is no trigger");
        // A commented-out trigger is no trigger either.
        assert_eq!(dispatch_inputs("on:\n  push:\n  # workflow_dispatch:\n"), None);
    }

    #[test]
    fn dispatch_inputs_with_every_kind() {
        let yaml = r#"# Promote a build
name: Promote
on:
  workflow_dispatch:
    inputs:
      channel:
        description: 'Where it goes' # the store channel
        required: true
        default: 'beta'
        type: choice
        options:
          - beta
          - "stable"   # the real one
      dry_run:
        description: Only pretend
        type: boolean
        default: false
      count:
        type: number
        default: "3"
      target:
        type: environment
        required: yes
      note:
        description: "It's a \"note\" # not a comment"
      flavours:
        type: choice
        options: [plain, 'with, comma', "x"]
  push:
    branches: [main]

jobs:
  promote:
    runs-on: ubuntu-latest
    steps:
      - name: inputs
        run: echo "${{ inputs.channel }}"
      - uses: actions/checkout@v4
        with:
          description: not an input
"#;
        let inputs = dispatch_inputs(yaml).unwrap();
        assert_eq!(names(&inputs), vec!["channel", "dry_run", "count", "target", "note", "flavours"]);
        let channel = &inputs[0];
        assert_eq!(channel.description, "Where it goes");
        assert!(channel.required);
        assert_eq!(channel.default.as_deref(), Some("beta"));
        assert_eq!(channel.kind, "choice");
        assert_eq!(channel.options, vec!["beta", "stable"]);
        assert_eq!((inputs[1].kind.as_str(), inputs[1].default.as_deref(), inputs[1].required), ("boolean", Some("false"), false));
        assert_eq!((inputs[2].kind.as_str(), inputs[2].default.as_deref()), ("number", Some("3")));
        assert_eq!((inputs[3].kind.as_str(), inputs[3].required), ("environment", true));
        assert_eq!(inputs[4].description, "It's a \"note\" # not a comment");
        assert_eq!(inputs[4].kind, "string", "no type is a string");
        assert_eq!(inputs[4].default, None);
        assert_eq!(inputs[5].options, vec!["plain", "with, comma", "x"]);
    }

    #[test]
    fn dispatch_inputs_with_block_scalars_and_odd_spacing() {
        let yaml = "on:\n    workflow_dispatch:\n        inputs:\n            reason:\n                description: |\n                    Why this runs.\n                    # Kept as text.\n                required: false\n            summary:\n                description: >-\n                    One long\n                    line.\n\n                    Next.\n                type: Mystery\n            plain:\n                description: don't stop # here\n";
        let inputs = dispatch_inputs(yaml).unwrap();
        assert_eq!(names(&inputs), vec!["reason", "summary", "plain"]);
        assert_eq!(inputs[0].description, "Why this runs.\n# Kept as text.");
        assert!(!inputs[0].required);
        assert_eq!(inputs[1].description, "One long line.\nNext.");
        assert_eq!(inputs[1].kind, "string", "an unknown type reads as string");
        assert_eq!(inputs[2].description, "don't stop");
    }

    #[test]
    fn dispatch_without_inputs_and_crlf() {
        assert_eq!(dispatch_inputs("on:\r\n  workflow_dispatch:\r\n    inputs: {}\r\njobs:\r\n  a: {}\r\n"), Some(vec![]));
        let inputs = dispatch_inputs("---\non:\n  workflow_dispatch:\n    inputs:\n      tag:\n        required: true\n").unwrap();
        assert_eq!(names(&inputs), vec!["tag"]);
        assert!(inputs[0].required);
    }

    #[test]
    fn branches_contents_and_dispatch_body() {
        let branches = parse_branches(&json!([{"name": "feature"}, {"name": "main"}, {"name": "dev"}]), "main");
        assert_eq!(branches, vec!["main", "feature", "dev"]);
        assert_eq!(
            file_content(&json!({"content": "b246CndvcmtmbG93\nX2Rpc3BhdGNoCg==\n", "encoding": "base64"})).as_deref(),
            Some("on:\nworkflow_dispatch\n")
        );
        assert_eq!(file_content(&json!({})), None);
        assert_eq!(workflow_file_path(".github/workflows/ci.yml@refs/heads/main").as_deref(), Some(".github/workflows/ci.yml"));
        assert_eq!(workflow_file_path("dynamic/pages/pages-build-deployment"), None);
        let inputs: std::collections::BTreeMap<String, String> =
            [("channel".to_string(), "beta".to_string()), ("note".to_string(), String::new()), ("dry".to_string(), "false".to_string())]
                .into();
        assert_eq!(
            dispatch_body("main", &inputs),
            json!({"ref": "main", "inputs": {"channel": "beta", "dry": "false"}, "return_run_details": true})
        );
    }

    #[test]
    fn run_list_filters() {
        assert!(runs_url("acme/web", None, "all").ends_with("/repos/acme/web/actions/runs?per_page=40&exclude_pull_requests=true"));
        assert!(runs_url("acme/web", Some(5), "running")
            .ends_with("/repos/acme/web/actions/workflows/5/runs?per_page=40&exclude_pull_requests=true&status=in_progress"));
        assert!(runs_url("acme/web", None, "failed").ends_with("&status=failure"));
        assert_eq!(action_path("rerunFailed"), Some("rerun-failed-jobs"));
        assert_eq!(action_path("delete"), None);
    }
}
