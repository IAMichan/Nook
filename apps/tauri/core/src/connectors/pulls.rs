//! The pull requests under Agents › Pull requests: the list of every connected GitHub account (yours, the ones for your
//! review, and the ones in the organizations and repositories you watch), and one pull request read in full for the
//! detail view. Port of `PullRequestGraphQL`, `PullRequestWatchList`, `GitHubPullRequestList`, `PullRequestDetail` and
//! `GitHubPullRequestDetail` on the Mac. Reading only; merging runs through the `github_merge_pr` action
//! (`GitHub::execute`), with `merge_body` and `merge_error` from here.

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use futures_util::future::join_all;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::github::{api, Ci};
use super::hub::Env;
use super::{date, github_markdown, int, link, list, CResult, ConnectorError, ErrorKind};

/// Where a pull request stands: still open, closed without merging, or merged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PullState {
    #[default]
    Open,
    Closed,
    Merged,
}

/// One pull request in the list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestItem {
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub url: Option<String>,
    pub draft: bool,
    pub updated: Option<DateTime<Utc>>,
    pub author: String,
    #[serde(default)]
    pub ci: Ci,
    /// A list saved before states existed only held open pull requests.
    #[serde(default)]
    pub state: PullState,
}

impl PullRequestItem {
    pub fn id(&self) -> String {
        format!("{}#{}", self.repo, self.number)
    }
}

/// The pull requests of one GitHub account.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountPullRequests {
    /// The account's id ("github", "github.werk").
    pub id: String,
    /// How the account is named in Nook: its label, else its login.
    pub name: String,
    pub login: String,
    pub mine: Vec<PullRequestItem>,
    pub reviews: Vec<PullRequestItem>,
    /// Set when this account could not be read (token rejected, no connection).
    pub error: Option<String>,
    pub error_kind: Option<ErrorKind>,
    /// The other pull requests in the watched organizations and repositories.
    #[serde(default)]
    pub watched: Vec<PullRequestItem>,
    /// Watched entries this account could not search (a typo, or no access with this account).
    #[serde(default)]
    pub unreadable: Vec<String>,
}

/// The list for the view: whether GitHub is connected at all, and every account in the order they are set up.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestList {
    pub available: bool,
    pub accounts: Vec<AccountPullRequests>,
}

// The watch list

/// Each entry costs two searches per refresh; this keeps a refresh cheap and well inside GitHub's limits.
pub const WATCH_LIMIT: usize = 20;

fn is_owner(text: &str) -> bool {
    (1..=39).contains(&text.len()) && !text.starts_with('-') && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

fn is_repo(text: &str) -> bool {
    (1..=100).contains(&text.len()) && text != "." && text != ".." && text.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

/// "acme", "acme/web", "@acme", "github.com/acme/web" or "https://github.com/acme/web/pull/3" → "acme" or "acme/web";
/// `None` for anything that is not a GitHub owner or repository name.
pub fn normalize_watch(text: &str) -> Option<String> {
    let mut value = text.trim().to_string();
    for prefix in ["https://", "http://", "www.", "github.com/", "@"] {
        if value.to_lowercase().starts_with(prefix) {
            value = value[prefix.len()..].to_string();
        }
    }
    let parts: Vec<&str> = value.split('/').filter(|p| !p.is_empty()).collect();
    let owner = parts.first().filter(|o| is_owner(o))?;
    let Some(repo) = parts.get(1) else { return Some(owner.to_string()) };
    let repo = if repo.to_lowercase().ends_with(".git") { &repo[..repo.len() - 4] } else { repo };
    is_repo(repo).then(|| format!("{owner}/{repo}"))
}

/// The entries added to a list (separated by commas or spaces), normalized, without ones already in it (GitHub names
/// ignore case), up to `WATCH_LIMIT`.
pub fn add_watched(text: &str, current: &[String]) -> Vec<String> {
    let mut result = current.to_vec();
    for piece in text.split(|c: char| c == ',' || c.is_whitespace()).filter(|p| !p.is_empty()) {
        if result.len() >= WATCH_LIMIT {
            break;
        }
        let Some(entry) = normalize_watch(piece) else { continue };
        if !result.iter().any(|e| e.eq_ignore_ascii_case(&entry)) {
            result.push(entry);
        }
    }
    result
}

/// The search for one entry's open or closed pull requests.
pub fn watch_search(entry: &str, closed: bool) -> String {
    let scope = if entry.contains('/') { format!("repo:{entry}") } else { format!("org:{entry}") };
    format!("is:pr {} archived:false {scope} sort:updated-desc", if closed { "is:closed" } else { "is:open" })
}

// GraphQL

const ROW_FRAGMENT: &str = "fragment row on PullRequest {
  number title url isDraft updatedAt state
  author { login }
  repository { nameWithOwner }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}";

/// Four aliased searches in one request: yours and the ones waiting for your review while open; yours and the ones you
/// reviewed once closed or merged. Each row carries its state and CI as the rolled-up state of its latest commit.
pub fn graphql_body() -> Value {
    let query = format!(
        "query NookPullRequests($mine: String!, $reviews: String!, $mineClosed: String!, $reviewsClosed: String!) {{
  viewer {{ login }}
  mine: search(query: $mine, type: ISSUE, first: 50) {{ nodes {{ ...row }} }}
  reviews: search(query: $reviews, type: ISSUE, first: 50) {{ nodes {{ ...row }} }}
  mineClosed: search(query: $mineClosed, type: ISSUE, first: 30) {{ nodes {{ ...row }} }}
  reviewsClosed: search(query: $reviewsClosed, type: ISSUE, first: 30) {{ nodes {{ ...row }} }}
}}
{ROW_FRAGMENT}"
    );
    json!({"query": query, "variables": {
        "mine": "is:pr is:open archived:false author:@me sort:updated-desc",
        "reviews": "is:pr is:open archived:false review-requested:@me sort:updated-desc",
        "mineClosed": "is:pr is:closed archived:false author:@me sort:updated-desc",
        "reviewsClosed": "is:pr is:closed archived:false reviewed-by:@me -author:@me sort:updated-desc"
    }})
}

fn alias(index: usize, closed: bool) -> String {
    format!("w{index}{}", if closed { "Closed" } else { "" })
}

/// The watched entries in one request: an open and a closed search per entry, aliased by position.
pub fn watch_body(entries: &[String]) -> Value {
    let mut declarations = vec![];
    let mut fields = vec![];
    let mut variables = serde_json::Map::new();
    for (index, entry) in entries.iter().enumerate() {
        for closed in [false, true] {
            let name = alias(index, closed);
            declarations.push(format!("${name}: String!"));
            fields.push(format!(
                "  {name}: search(query: ${name}, type: ISSUE, first: {}) {{ nodes {{ ...row }} }}",
                if closed { 20 } else { 50 }
            ));
            variables.insert(name, json!(watch_search(entry, closed)));
        }
    }
    let query = format!("query NookWatchedPullRequests({}) {{\n{}\n}}\n{ROW_FRAGMENT}", declarations.join(", "), fields.join("\n"));
    json!({"query": query, "variables": variables})
}

pub fn rollup(state: Option<&str>) -> Ci {
    match state {
        Some("SUCCESS") => Ci::Passing,
        Some("FAILURE" | "ERROR") => Ci::Failing,
        Some("PENDING" | "EXPECTED") => Ci::Pending,
        _ => Ci::Unknown,
    }
}

pub fn pull_state(state: Option<&str>) -> PullState {
    match state {
        Some("MERGED") => PullState::Merged,
        Some("CLOSED") => PullState::Closed,
        _ => PullState::Open,
    }
}

fn payload(root: &Value) -> CResult<&Value> {
    root.get("data").filter(|d| d.is_object()).ok_or_else(|| {
        let message = root["errors"][0]["message"].as_str().unwrap_or("GitHub returned no data.");
        ConnectorError::new(format!("GitHub: {message}"))
    })
}

fn rows(search: &Value) -> Vec<PullRequestItem> {
    list(&search["nodes"])
        .iter()
        .filter_map(|n| {
            Some(PullRequestItem {
                repo: n["repository"]["nameWithOwner"].as_str()?.to_string(),
                number: int(&n["number"])?,
                title: n["title"].as_str().unwrap_or("Untitled").into(),
                url: link(n["url"].as_str()),
                draft: n["isDraft"].as_bool().unwrap_or(false),
                updated: date(&n["updatedAt"]),
                author: n["author"]["login"].as_str().unwrap_or("").into(),
                ci: rollup(list(&n["commits"]["nodes"]).last().and_then(|c| c["commit"]["statusCheckRollup"]["state"].as_str())),
                state: pull_state(n["state"].as_str()),
            })
        })
        .collect()
}

/// Your login and both lists, open pull requests first, then the closed and merged ones. GitHub's own message when the
/// query failed as a whole.
pub fn parse_graphql(root: &Value) -> CResult<(String, Vec<PullRequestItem>, Vec<PullRequestItem>)> {
    let data = payload(root)?;
    let mut mine = rows(&data["mine"]);
    mine.extend(rows(&data["mineClosed"]));
    let mut reviews = rows(&data["reviews"]);
    reviews.extend(rows(&data["reviewsClosed"]));
    Ok((data["viewer"]["login"].as_str().unwrap_or("").to_string(), mine, reviews))
}

/// Open ones first, each part newest first, every pull request once.
fn open_first(items: Vec<PullRequestItem>) -> Vec<PullRequestItem> {
    let (mut open, mut closed): (Vec<_>, Vec<_>) = items.into_iter().partition(|i| i.state == PullState::Open);
    open.sort_by_key(|i| std::cmp::Reverse(i.updated));
    closed.sort_by_key(|i| std::cmp::Reverse(i.updated));
    let mut seen = HashSet::new();
    open.into_iter().chain(closed).filter(|i| seen.insert(i.id())).collect()
}

/// The watched pull requests, and the entries GitHub would not search (their alias came back empty).
pub fn parse_watched(root: &Value, entries: &[String]) -> CResult<(Vec<PullRequestItem>, Vec<String>)> {
    let data = payload(root)?;
    let mut items = vec![];
    let mut unreadable = vec![];
    for (index, entry) in entries.iter().enumerate() {
        let open = &data[alias(index, false)];
        if !open.is_object() {
            unreadable.push(entry.clone());
            continue;
        }
        items.extend(rows(open));
        items.extend(rows(&data[alias(index, true)]));
    }
    Ok((open_first(items), unreadable))
}

async fn post_graphql(env: &Env, token: &str, body: &Value) -> CResult<Value> {
    let (status, bytes) =
        env.http.send("POST", &format!("{}/graphql", api()), &[("Authorization", format!("Bearer {token}"))], Some(body), "GitHub").await?;
    match status {
        200..=299 => serde_json::from_slice(&bytes).map_err(|_| ConnectorError::new("GitHub gaf een onverwacht antwoord.")),
        401 | 403 => Err(ConnectorError::kind(
            "De inloggegevens werden geweigerd. Controleer ze bij Instellingen › Accounts & koppelingen.",
            ErrorKind::Auth,
        )),
        429 => Err(ConnectorError::kind("Te veel verzoeken. Nook probeert het zo opnieuw.", ErrorKind::RateLimited)),
        s => Err(ConnectorError::new(format!("GitHub gaf een fout ({s})."))),
    }
}

async fn watched_once(env: &Env, token: &str, entries: &[String]) -> CResult<(Vec<PullRequestItem>, Vec<String>)> {
    parse_watched(&post_graphql(env, token, &watch_body(entries)).await?, entries)
}

/// The watched entries in one request. When GitHub turns the request down as a whole (one entry it cannot search can
/// do that), each entry is asked on its own, so only the entries that fail are left out.
async fn fetch_watched(env: &Env, token: &str, entries: &[String]) -> (Vec<PullRequestItem>, Vec<String>) {
    if entries.is_empty() {
        return (vec![], vec![]);
    }
    match watched_once(env, token, entries).await {
        Ok(result) => result,
        // Only GitHub refusing the query points at an entry; a lost connection or a rate limit says nothing about one.
        Err(e) if e.kind != ErrorKind::Other => (vec![], vec![]),
        Err(_) if entries.len() == 1 => (vec![], entries.to_vec()),
        Err(_) => {
            let parts = join_all(entries.iter().map(|entry| async move {
                let one = std::slice::from_ref(entry);
                watched_once(env, token, one).await.unwrap_or_else(|_| (vec![], one.to_vec()))
            }))
            .await;
            let mut items = vec![];
            let mut unreadable = vec![];
            for (found, failed) in parts {
                items.extend(found);
                unreadable.extend(failed);
            }
            (open_first(items), unreadable)
        }
    }
}

/// One account to read: its id, its name in Nook, its known login and its token.
pub struct Target {
    pub id: String,
    pub name: String,
    pub login: String,
    pub token: String,
}

async fn load_account(env: &Env, target: &Target, watching: &[String]) -> AccountPullRequests {
    let (list, watched) = futures_util::join!(
        async { parse_graphql(&post_graphql(env, &target.token, &graphql_body()).await?) },
        fetch_watched(env, &target.token, watching)
    );
    match list {
        Ok((login, mine, reviews)) => AccountPullRequests {
            id: target.id.clone(),
            name: target.name.clone(),
            login: if login.is_empty() { target.login.clone() } else { login },
            mine,
            reviews,
            error: None,
            error_kind: None,
            watched: watched.0,
            unreadable: watched.1,
        },
        Err(e) => AccountPullRequests {
            id: target.id.clone(),
            name: target.name.clone(),
            login: target.login.clone(),
            mine: vec![],
            reviews: vec![],
            error: Some(e.message),
            error_kind: Some(e.kind),
            watched: vec![],
            unreadable: vec![],
        },
    }
}

/// All accounts at once, in the order given. One failing account does not hide the others.
pub async fn load(env: &Env, targets: &[Target], watching: &[String]) -> Vec<AccountPullRequests> {
    let loaded = join_all(targets.iter().map(|t| load_account(env, t, watching))).await;
    dedupe_watched(loaded)
}

/// Yours and your reviews stay where they are; a watched pull request only shows where nothing lists it yet, under the
/// first account that has it.
pub fn dedupe_watched(mut accounts: Vec<AccountPullRequests>) -> Vec<AccountPullRequests> {
    let mut seen: HashSet<String> = accounts.iter().flat_map(|a| a.mine.iter().chain(&a.reviews).map(PullRequestItem::id)).collect();
    for account in &mut accounts {
        account.watched.retain(|i| seen.insert(i.id()));
    }
    accounts
}

// One pull request in full

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DetailState {
    Open,
    Draft,
    Merged,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckOutcome {
    Passing,
    Failing,
    Pending,
    Skipped,
}

/// One check run or commit status on the latest commit.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestCheck {
    pub name: String,
    pub outcome: CheckOutcome,
    /// The conclusion or state GitHub gave ("success", "failure", "in_progress"…), shown next to the name.
    pub detail: String,
    pub url: Option<String>,
}

/// What a timeline entry is.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum EventKind {
    Comment,
    /// APPROVED, CHANGES_REQUESTED, COMMENTED or DISMISSED.
    Review {
        state: String,
    },
    LineComment {
        path: String,
        line: Option<i64>,
    },
    /// A commit on the branch; the body is its subject.
    Commit {
        sha: String,
    },
    /// One of `ACTIVITY_TYPES` ("labeled", "merged"…) with what it is about: a label, a login, the new title, a short
    /// sha or a reference.
    Activity {
        event: String,
        detail: String,
    },
}

/// One entry in the timeline: a review, a comment, a line comment, a commit, or something that happened.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestEvent {
    pub id: String,
    #[serde(flatten)]
    pub kind: EventKind,
    pub author: String,
    /// Markdown (see `github_markdown`).
    pub body: String,
    pub date: Option<DateTime<Utc>>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestCommit {
    pub sha: String,
    pub message: String,
    pub author: String,
    pub date: Option<DateTime<Utc>>,
}

impl PullRequestCommit {
    pub fn subject(&self) -> String {
        self.message.lines().next().unwrap_or("").to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestFile {
    pub path: String,
    /// added, removed, modified, renamed, copied, changed or unchanged.
    pub status: String,
    pub additions: i64,
    pub deletions: i64,
    /// The unified diff. `None` for binary files and for diffs GitHub leaves out because they are too large.
    pub patch: Option<String>,
    pub previous_path: Option<String>,
}

pub const MERGE_METHODS: [&str; 3] = ["merge", "squash", "rebase"];

/// Everything the detail view shows about one pull request.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestDetail {
    pub repo: String,
    pub number: i64,
    pub title: String,
    /// Markdown (see `github_markdown`).
    pub body: String,
    pub url: Option<String>,
    pub author: String,
    pub state: DetailState,
    pub base_branch: String,
    pub head_branch: String,
    /// The commit the view shows. A merge is sent with it, so GitHub refuses when someone pushed in the meantime.
    pub head_sha: String,
    pub additions: i64,
    pub deletions: i64,
    pub changed_files: i64,
    pub created: Option<DateTime<Utc>>,
    pub updated: Option<DateTime<Utc>>,
    /// GitHub computes this lazily: `None` while it is still working it out.
    pub mergeable: Option<bool>,
    /// GitHub's `mergeable_state`: clean, unstable, blocked, behind, dirty, draft, has_hooks or unknown.
    pub merge_state: String,
    pub checks: Vec<PullRequestCheck>,
    pub events: Vec<PullRequestEvent>,
    pub commits: Vec<PullRequestCommit>,
    pub files: Vec<PullRequestFile>,
    /// The merge methods the repository allows, in GitHub's order.
    pub methods: Vec<String>,
    /// Whether the account may push to the repository, and so merge. `None` when GitHub did not say.
    pub can_push: Option<bool>,
    // Worked out by `finish`, for the view.
    pub is_open: bool,
    pub can_merge: bool,
    pub check_summary: Ci,
    /// Why it cannot be merged right now, or what GitHub warns about: a key the view words, `None` when all is well.
    pub merge_note: Option<String>,
}

impl PullRequestDetail {
    pub fn id(&self) -> String {
        format!("{}#{}", self.repo, self.number)
    }

    fn conflicted(&self) -> bool {
        self.mergeable == Some(false) || self.merge_state == "dirty"
    }

    /// The checks together: failing as soon as one fails, pending while one still runs.
    fn summary(&self) -> Ci {
        if self.checks.is_empty() {
            Ci::Unknown
        } else if self.checks.iter().any(|c| c.outcome == CheckOutcome::Failing) {
            Ci::Failing
        } else if self.checks.iter().any(|c| c.outcome == CheckOutcome::Pending) {
            Ci::Pending
        } else {
            Ci::Passing
        }
    }

    fn note(&self) -> Option<&'static str> {
        match self.state {
            DetailState::Merged => return Some("merged"),
            DetailState::Closed => return Some("closed"),
            DetailState::Draft => return Some("draft"),
            DetailState::Open => {}
        }
        if self.can_push == Some(false) {
            return Some("noAccess");
        }
        if self.conflicted() {
            return Some("conflict");
        }
        match self.merge_state.as_str() {
            "blocked" => return Some("blocked"),
            "behind" => return Some("behind"),
            "unstable" => return Some("unstable"),
            _ => {}
        }
        if self.mergeable.is_none() {
            return Some("checking");
        }
        (self.summary() == Ci::Failing).then_some("unstable")
    }

    /// Fills in what the view needs to decide. GitHub has the last word on a merge (branch protection, an admin
    /// bypass), so only what certainly fails holds the button back.
    pub fn finish(mut self) -> Self {
        self.is_open = matches!(self.state, DetailState::Open | DetailState::Draft);
        self.can_merge = self.state == DetailState::Open && !self.conflicted() && self.can_push != Some(false) && !self.methods.is_empty();
        self.check_summary = self.summary();
        self.merge_note = self.note().map(str::to_string);
        self
    }
}

fn login(user: &Value) -> String {
    user["login"].as_str().unwrap_or("?").to_string()
}

fn text(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}

/// The pull request itself, with the repository's merge methods and push right when the repository could be read.
pub fn parse_detail(pull: &Value, repository: Option<&Value>) -> Option<PullRequestDetail> {
    let number = int(&pull["number"])?;
    let base = &pull["base"];
    let head = &pull["head"];
    let repo = base["repo"]["full_name"].as_str().or_else(|| repository.and_then(|r| r["full_name"].as_str())).unwrap_or("").to_string();
    let merged = pull["merged"].as_bool() == Some(true) || pull["merged_at"].is_string();
    let state = if merged {
        DetailState::Merged
    } else if pull["state"].as_str() != Some("open") {
        DetailState::Closed
    } else if pull["draft"].as_bool() == Some(true) {
        DetailState::Draft
    } else {
        DetailState::Open
    };
    let (methods, can_push) = match repository {
        Some(r) => (merge_methods(r), r["permissions"]["push"].as_bool()),
        None => (MERGE_METHODS.iter().map(|m| m.to_string()).collect(), None),
    };
    Some(
        PullRequestDetail {
            repo,
            number,
            title: pull["title"].as_str().unwrap_or("Untitled").to_string(),
            body: github_markdown::markdown(pull["body"].as_str().unwrap_or("")),
            url: link(pull["html_url"].as_str()),
            author: login(&pull["user"]),
            state,
            base_branch: text(&base["ref"]),
            head_branch: text(&head["ref"]),
            head_sha: text(&head["sha"]),
            additions: int(&pull["additions"]).unwrap_or(0),
            deletions: int(&pull["deletions"]).unwrap_or(0),
            changed_files: int(&pull["changed_files"]).unwrap_or(0),
            created: date(&pull["created_at"]),
            updated: date(&pull["updated_at"]),
            mergeable: pull["mergeable"].as_bool(),
            merge_state: pull["mergeable_state"].as_str().unwrap_or("unknown").to_lowercase(),
            checks: vec![],
            events: vec![],
            commits: vec![],
            files: vec![],
            methods,
            can_push,
            is_open: false,
            can_merge: false,
            check_summary: Ci::Unknown,
            merge_note: None,
        }
        .finish(),
    )
}

/// The methods the repository allows. GitHub only sends the `allow_*` fields to accounts with write access; a field
/// that is missing counts as allowed.
pub fn merge_methods(repository: &Value) -> Vec<String> {
    [("merge", "allow_merge_commit"), ("squash", "allow_squash_merge"), ("rebase", "allow_rebase_merge")]
        .into_iter()
        .filter(|(_, field)| repository[*field].as_bool().unwrap_or(true))
        .map(|(method, _)| method.to_string())
        .collect()
}

/// Check runs (GitHub Actions and apps) and the older commit statuses in one list: failing first, then running.
pub fn parse_checks(runs: &[Value], statuses: &[Value]) -> Vec<PullRequestCheck> {
    let bad = ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"];
    let mut result: Vec<PullRequestCheck> = runs
        .iter()
        .map(|run| {
            let status = run["status"].as_str().unwrap_or("");
            let conclusion = run["conclusion"].as_str().unwrap_or("");
            let outcome = if status != "completed" {
                CheckOutcome::Pending
            } else if bad.contains(&conclusion) {
                CheckOutcome::Failing
            } else if ["skipped", "neutral"].contains(&conclusion) {
                CheckOutcome::Skipped
            } else {
                CheckOutcome::Passing
            };
            PullRequestCheck {
                name: run["name"].as_str().unwrap_or("?").to_string(),
                outcome,
                detail: if status == "completed" { conclusion } else { status }.to_string(),
                url: link(run["html_url"].as_str().or(run["details_url"].as_str())),
            }
        })
        .collect();
    // The combined status lists every context once, with its latest state.
    for status in statuses {
        let state = status["state"].as_str().unwrap_or("");
        let outcome = match state {
            "success" => CheckOutcome::Passing,
            "pending" => CheckOutcome::Pending,
            _ => CheckOutcome::Failing,
        };
        let description = status["description"].as_str().unwrap_or("");
        result.push(PullRequestCheck {
            name: status["context"].as_str().unwrap_or("?").to_string(),
            outcome,
            detail: if description.is_empty() { state } else { description }.to_string(),
            url: link(status["target_url"].as_str()),
        });
    }
    let rank = |c: &PullRequestCheck| match c.outcome {
        CheckOutcome::Failing => 0,
        CheckOutcome::Pending => 1,
        CheckOutcome::Passing => 2,
        CheckOutcome::Skipped => 3,
    };
    // A stable sort keeps GitHub's order within each outcome.
    result.sort_by_key(rank);
    result
}

/// The timeline events Nook shows, by GitHub's name. Comments, reviews and commits come from their own lists, which
/// carry more; subscriptions and mentions say nothing about the pull request itself.
pub const ACTIVITY_TYPES: [&str; 23] = [
    "labeled",
    "unlabeled",
    "assigned",
    "unassigned",
    "review_requested",
    "review_request_removed",
    "renamed",
    "head_ref_force_pushed",
    "head_ref_deleted",
    "head_ref_restored",
    "base_ref_changed",
    "merged",
    "closed",
    "reopened",
    "ready_for_review",
    "convert_to_draft",
    "cross-referenced",
    "referenced",
    "milestoned",
    "demilestoned",
    "auto_merge_enabled",
    "auto_merge_disabled",
    "review_dismissed",
];

/// What a timeline event is about, as shown after its sentence.
pub fn activity_detail(event: &str, item: &Value) -> String {
    let field = |key: &str, name: &str| item[key][name].as_str().map(str::to_string);
    match event {
        "labeled" | "unlabeled" => field("label", "name").unwrap_or_default(),
        "assigned" | "unassigned" => field("assignee", "login").map(|l| format!("@{l}")).unwrap_or_default(),
        "review_requested" | "review_request_removed" => {
            field("requested_reviewer", "login").map(|l| format!("@{l}")).or_else(|| field("requested_team", "name")).unwrap_or_default()
        }
        "renamed" => field("rename", "to").unwrap_or_default(),
        "merged" | "referenced" => item["commit_id"].as_str().map(|s| s.chars().take(7).collect()).unwrap_or_default(),
        "milestoned" | "demilestoned" => field("milestone", "title").unwrap_or_default(),
        "cross-referenced" => {
            let issue = &item["source"]["issue"];
            let repo = issue["repository"]["full_name"].as_str().unwrap_or("");
            let number = int(&issue["number"]).map(|n| format!("#{n}")).unwrap_or_default();
            let title = issue["title"].as_str().map(|t| format!(" {t}")).unwrap_or_default();
            format!("{repo}{number}{title}")
        }
        _ => String::new(),
    }
}

/// The whole history as one timeline, oldest first: reviews, comments, line comments, commits, and the events of
/// `/issues/{number}/timeline`. Pending reviews (not sent yet) and empty "commented" reviews (the wrapper of line
/// comments) are left out.
pub fn parse_events(
    reviews: &[Value],
    comments: &[Value],
    line_comments: &[Value],
    timeline: &[Value],
    commits: &[PullRequestCommit],
) -> Vec<PullRequestEvent> {
    let mut result = vec![];
    let id = |prefix: &str, item: &Value, fallback: usize| {
        format!("{prefix}-{}", int(&item["id"]).map(|i| i.to_string()).unwrap_or_else(|| format!("#{fallback}")))
    };
    for commit in commits {
        result.push(PullRequestEvent {
            id: format!("commit-{}", commit.sha),
            kind: EventKind::Commit { sha: commit.sha.clone() },
            author: commit.author.clone(),
            body: commit.subject(),
            date: commit.date,
            url: None,
        });
    }
    for (index, item) in timeline.iter().enumerate() {
        let Some(event) = item["event"].as_str().filter(|e| ACTIVITY_TYPES.contains(e)) else { continue };
        result.push(PullRequestEvent {
            id: id("timeline", item, index),
            kind: EventKind::Activity { event: event.to_string(), detail: activity_detail(event, item) },
            author: login(&item["actor"]),
            body: String::new(),
            date: date(&item["created_at"]),
            url: None,
        });
    }
    for review in reviews {
        let state = review["state"].as_str().unwrap_or("").to_uppercase();
        let body = github_markdown::markdown(review["body"].as_str().unwrap_or(""));
        if state == "PENDING" || (state == "COMMENTED" && body.is_empty()) {
            continue;
        }
        result.push(PullRequestEvent {
            id: id("review", review, result.len()),
            kind: EventKind::Review { state },
            author: login(&review["user"]),
            body,
            date: date(&review["submitted_at"]),
            url: link(review["html_url"].as_str()),
        });
    }
    for comment in comments {
        result.push(PullRequestEvent {
            id: id("comment", comment, result.len()),
            kind: EventKind::Comment,
            author: login(&comment["user"]),
            body: github_markdown::markdown(comment["body"].as_str().unwrap_or("")),
            date: date(&comment["created_at"]),
            url: link(comment["html_url"].as_str()),
        });
    }
    for comment in line_comments {
        result.push(PullRequestEvent {
            id: id("line", comment, result.len()),
            kind: EventKind::LineComment {
                path: text(&comment["path"]),
                line: int(&comment["line"]).or_else(|| int(&comment["original_line"])),
            },
            author: login(&comment["user"]),
            body: github_markdown::markdown(comment["body"].as_str().unwrap_or("")),
            date: date(&comment["created_at"]),
            url: link(comment["html_url"].as_str()),
        });
    }
    // Oldest first; an event without a date goes first, and the sort is stable.
    result.sort_by_key(|e| e.date);
    result
}

pub fn parse_commits(items: &[Value]) -> Vec<PullRequestCommit> {
    items
        .iter()
        .filter_map(|item| {
            let sha = item["sha"].as_str()?.to_string();
            let commit = &item["commit"];
            let account = login(&item["author"]);
            Some(PullRequestCommit {
                sha,
                message: text(&commit["message"]),
                author: if account != "?" { account } else { commit["author"]["name"].as_str().unwrap_or("?").to_string() },
                date: date(&commit["author"]["date"]),
            })
        })
        .collect()
}

pub fn parse_files(items: &[Value]) -> Vec<PullRequestFile> {
    items
        .iter()
        .filter_map(|item| {
            Some(PullRequestFile {
                path: item["filename"].as_str()?.to_string(),
                status: item["status"].as_str().unwrap_or("modified").to_string(),
                additions: int(&item["additions"]).unwrap_or(0),
                deletions: int(&item["deletions"]).unwrap_or(0),
                patch: item["patch"].as_str().map(str::to_string),
                previous_path: item["previous_filename"].as_str().map(str::to_string),
            })
        })
        .collect()
}

/// The body of `PUT /repos/{repo}/pulls/{number}/merge`. With `sha`, GitHub only merges that exact head.
pub fn merge_body(method: &str, sha: Option<&str>) -> Value {
    let mut body = json!({"merge_method": method});
    if let Some(sha) = sha.filter(|s| !s.is_empty()) {
        body["sha"] = json!(sha);
    }
    body
}

/// GitHub's refusal of a merge, in words: its own message, with the reason for the common statuses.
pub fn merge_error(status: u16, object: &Value) -> ConnectorError {
    let message = object["message"].as_str().map(str::trim).unwrap_or("");
    let with = |text: &str| if message.is_empty() { text.to_string() } else { format!("{text} {message}") };
    match status {
        401 => ConnectorError::kind(
            "GitHub weigerde de verbinding (401). Koppel opnieuw bij Instellingen › Accounts & koppelingen.",
            ErrorKind::Auth,
        ),
        403 => ConnectorError::new(with("GitHub stond de merge niet toe (403).")),
        404 => ConnectorError::new("GitHub kon de pull request niet vinden, of dit account heeft er geen toegang toe (404)."),
        405 => ConnectorError::new(with("GitHub kan deze pull request niet mergen (405).")),
        409 => ConnectorError::new("De branch is veranderd sinds je hem opende (409). Bekijk de nieuwe commits en probeer het opnieuw."),
        422 => ConnectorError::new(with("GitHub weigerde de merge (422).")),
        _ if message.is_empty() => ConnectorError::new(format!("GitHub gaf een fout ({status}).")),
        _ => ConnectorError::new(format!("GitHub: {message}")),
    }
}

/// Reads one pull request completely, with the token of the account it was listed under. Only the pull request itself
/// must load; a part that fails (no access to checks, say) stays empty instead of hiding the rest.
pub async fn load_detail(env: &Env, token: &str, repo: &str, number: i64) -> CResult<PullRequestDetail> {
    let base = format!("{}/repos/{repo}", api());
    let headers = super::github::headers(token);
    let get = move |path: String| {
        let url = format!("{base}{path}");
        let headers = headers.clone();
        async move { env.http.json("GET", &url, &headers, None, "GitHub").await }
    };
    let get = &get;
    // Every page of a list (100 per page), up to `pages` pages.
    let all = move |path: String, pages: usize| async move {
        let mut result = vec![];
        for page in 1..=pages {
            let separator = if path.contains('?') { '&' } else { '?' };
            let chunk = get(format!("{path}{separator}per_page=100&page={page}")).await.unwrap_or(Value::Null);
            let chunk = list(&chunk).to_vec();
            let full = chunk.len() >= 100;
            result.extend(chunk);
            if !full {
                break;
            }
        }
        result
    };
    let pull = get(format!("/pulls/{number}")).await?;
    let (repository, reviews, comments, line_comments, commits, files, timeline) = futures_util::join!(
        get(String::new()),
        all(format!("/pulls/{number}/reviews"), 3),
        all(format!("/issues/{number}/comments"), 3),
        all(format!("/pulls/{number}/comments"), 3),
        all(format!("/pulls/{number}/commits"), 3),
        all(format!("/pulls/{number}/files"), 30),
        all(format!("/issues/{number}/timeline"), 5),
    );
    let repository = repository.ok().filter(Value::is_object);
    let mut detail = parse_detail(&pull, repository.as_ref()).ok_or_else(|| ConnectorError::new("GitHub gaf een onverwacht antwoord."))?;
    if !detail.head_sha.is_empty() {
        let sha = detail.head_sha.clone();
        let (runs, status) =
            futures_util::join!(get(format!("/commits/{sha}/check-runs?per_page=100")), get(format!("/commits/{sha}/status?per_page=100")));
        let runs = runs.unwrap_or(Value::Null);
        let status = status.unwrap_or(Value::Null);
        detail.checks = parse_checks(list(&runs["check_runs"]), list(&status["statuses"]));
    }
    detail.commits = parse_commits(&commits);
    detail.events = parse_events(&reviews, &comments, &line_comments, &timeline, &detail.commits);
    detail.files = parse_files(&files);
    Ok(detail.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(repo: &str, number: i64, updated: &str, state: PullState) -> PullRequestItem {
        PullRequestItem {
            repo: repo.into(),
            number,
            title: "T".into(),
            url: None,
            draft: false,
            updated: date(&json!(updated)),
            author: "ada".into(),
            ci: Ci::Unknown,
            state,
        }
    }

    fn node(number: i64, repo: &str, state: &str, updated: &str) -> Value {
        json!({"number": number, "title": "T", "url": format!("https://github.com/{repo}/pull/{number}"), "isDraft": false,
               "updatedAt": updated, "state": state, "author": {"login": "ada"}, "repository": {"nameWithOwner": repo},
               "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}})
    }

    #[test]
    fn watch_entries_normalize() {
        assert_eq!(normalize_watch("acme").as_deref(), Some("acme"));
        assert_eq!(normalize_watch(" @acme ").as_deref(), Some("acme"));
        assert_eq!(normalize_watch("acme/web.git").as_deref(), Some("acme/web"));
        assert_eq!(normalize_watch("https://github.com/acme/web/pull/3").as_deref(), Some("acme/web"));
        assert_eq!(normalize_watch("github.com/acme").as_deref(), Some("acme"));
        assert_eq!(normalize_watch("-acme"), None);
        assert_eq!(normalize_watch("ac me"), None);
        assert_eq!(normalize_watch("acme/.."), None);
        assert_eq!(normalize_watch(""), None);
        assert_eq!(normalize_watch(&"a".repeat(40)), None);
    }

    #[test]
    fn watch_list_adds_without_duplicates_up_to_the_limit() {
        let list = add_watched("acme, Acme/Web acme/web nonsense!", &["ACME".to_string()]);
        assert_eq!(list, vec!["ACME", "Acme/Web"]);
        let full: Vec<String> = (0..WATCH_LIMIT).map(|i| format!("org{i}")).collect();
        assert_eq!(add_watched("extra", &full).len(), WATCH_LIMIT);
        assert_eq!(watch_search("acme/web", true), "is:pr is:closed archived:false repo:acme/web sort:updated-desc");
        assert_eq!(watch_search("acme", false), "is:pr is:open archived:false org:acme sort:updated-desc");
    }

    #[test]
    fn graphql_rows_states_and_errors() {
        assert_eq!(rollup(Some("SUCCESS")), Ci::Passing);
        assert_eq!(rollup(Some("ERROR")), Ci::Failing);
        assert_eq!(rollup(Some("EXPECTED")), Ci::Pending);
        assert_eq!(rollup(None), Ci::Unknown);
        assert_eq!(pull_state(Some("MERGED")), PullState::Merged);
        assert_eq!(pull_state(Some("CLOSED")), PullState::Closed);
        assert_eq!(pull_state(None), PullState::Open);
        assert_eq!(parse_graphql(&json!({"errors": [{"message": "Bad credentials"}]})).unwrap_err().message, "GitHub: Bad credentials");
        let body = graphql_body();
        assert!(body["query"].as_str().unwrap().contains("mineClosed: search"));
        assert!(body["query"].as_str().unwrap().contains("updatedAt state"));
        assert!(body["variables"]["reviewsClosed"].as_str().unwrap().contains("reviewed-by:@me -author:@me"));
        let root = json!({"data": {"viewer": {"login": "ada"},
            "mine": {"nodes": [node(1, "a/b", "OPEN", "2026-10-18T12:00:00Z")]},
            "mineClosed": {"nodes": [node(2, "a/b", "MERGED", "2026-10-19T12:00:00Z")]},
            "reviews": {"nodes": []}, "reviewsClosed": {"nodes": [node(3, "a/c", "CLOSED", "2026-10-17T12:00:00Z")]}}});
        let (login, mine, reviews) = parse_graphql(&root).unwrap();
        assert_eq!(login, "ada");
        assert_eq!(mine.iter().map(|i| (i.number, i.state)).collect::<Vec<_>>(), vec![(1, PullState::Open), (2, PullState::Merged)]);
        assert_eq!(mine[0].ci, Ci::Passing);
        assert_eq!(reviews[0].state, PullState::Closed);
    }

    #[test]
    fn watched_query_and_answer() {
        let entries = vec!["acme".to_string(), "acme/web".to_string(), "typo".to_string()];
        let body = watch_body(&entries);
        let query = body["query"].as_str().unwrap();
        assert!(query.starts_with("query NookWatchedPullRequests($w0: String!, $w0Closed: String!, $w1: String!"));
        assert!(query.contains("w1Closed: search(query: $w1Closed, type: ISSUE, first: 20)"));
        assert!(query.contains("fragment row on PullRequest"));
        assert_eq!(body["variables"]["w1"], "is:pr is:open archived:false repo:acme/web sort:updated-desc");
        let root = json!({"data": {
            "w0": {"nodes": [node(1, "acme/api", "OPEN", "2026-10-17T12:00:00Z"), node(2, "acme/web", "OPEN", "2026-10-19T12:00:00Z")]},
            "w0Closed": {"nodes": [node(3, "acme/api", "MERGED", "2026-10-20T12:00:00Z")]},
            "w1": {"nodes": [node(2, "acme/web", "OPEN", "2026-10-19T12:00:00Z")]}, "w1Closed": {"nodes": []},
            "w2": null, "w2Closed": null}, "errors": [{"message": "Could not resolve"}]});
        let (items, unreadable) = parse_watched(&root, &entries).unwrap();
        assert_eq!(items.iter().map(|i| i.number).collect::<Vec<_>>(), vec![2, 1, 3]);
        assert_eq!(unreadable, vec!["typo"]);
        assert!(parse_watched(&json!({"data": null, "errors": [{"message": "x"}]}), &entries).is_err());
    }

    #[test]
    fn a_watched_pull_request_shows_once() {
        let account = |id: &str, mine: Vec<PullRequestItem>, watched: Vec<PullRequestItem>| AccountPullRequests {
            id: id.into(),
            name: id.into(),
            login: id.into(),
            mine,
            reviews: vec![],
            error: None,
            error_kind: None,
            watched,
            unreadable: vec![],
        };
        let a = item("acme/web", 1, "2026-10-19T12:00:00Z", PullState::Open);
        let b = item("acme/web", 2, "2026-10-19T12:00:00Z", PullState::Open);
        let accounts = dedupe_watched(vec![
            account("github", vec![], vec![a.clone(), b.clone()]),
            account("github.werk", vec![a.clone()], vec![b.clone()]),
        ]);
        // #1 is the second account's own; #2 shows under the first account that lists it.
        assert_eq!(accounts[0].watched, vec![b]);
        assert!(accounts[1].watched.is_empty());
    }

    #[test]
    fn saved_lists_without_states_still_load() {
        let old = r#"{"repo":"a/b","number":1,"title":"T","url":null,"draft":false,"updated":null,"author":"ada","ci":"passing"}"#;
        assert_eq!(serde_json::from_str::<PullRequestItem>(old).unwrap().state, PullState::Open);
        let account = r#"{"id":"github","name":"GitHub","login":"ada","mine":[],"reviews":[],"error":null,"errorKind":null}"#;
        assert!(serde_json::from_str::<AccountPullRequests>(account).unwrap().watched.is_empty());
    }

    fn pull(extra: Value) -> Value {
        let mut base = json!({"number": 7, "title": "Fix", "body": "<b>Hi</b>", "html_url": "https://github.com/a/b/pull/7",
            "user": {"login": "ada"}, "state": "open", "draft": false, "base": {"ref": "main", "repo": {"full_name": "a/b"}},
            "head": {"ref": "fix", "sha": "abc123"}, "additions": 3, "deletions": 1, "changed_files": 2,
            "mergeable": true, "mergeable_state": "clean", "created_at": "2026-10-18T12:00:00Z"});
        for (k, v) in extra.as_object().unwrap() {
            base[k] = v.clone();
        }
        base
    }

    #[test]
    fn detail_states_and_merge_notes() {
        let detail = parse_detail(&pull(json!({})), None).unwrap();
        assert_eq!(detail.id(), "a/b#7");
        assert_eq!(detail.body, "**Hi**");
        assert_eq!(detail.state, DetailState::Open);
        assert!(detail.can_merge && detail.is_open);
        assert_eq!(detail.merge_note, None);
        assert_eq!(detail.methods, vec!["merge", "squash", "rebase"]);

        let merged = parse_detail(&pull(json!({"state": "closed", "merged_at": "2026-10-19T12:00:00Z"})), None).unwrap();
        assert_eq!((merged.state, merged.can_merge, merged.merge_note.as_deref()), (DetailState::Merged, false, Some("merged")));
        let draft = parse_detail(&pull(json!({"draft": true})), None).unwrap();
        assert_eq!((draft.state, draft.can_merge, draft.is_open), (DetailState::Draft, false, true));
        let conflict = parse_detail(&pull(json!({"mergeable": false, "mergeable_state": "dirty"})), None).unwrap();
        assert_eq!((conflict.can_merge, conflict.merge_note.as_deref()), (false, Some("conflict")));
        let checking = parse_detail(&pull(json!({"mergeable": null, "mergeable_state": "unknown"})), None).unwrap();
        assert_eq!((checking.can_merge, checking.merge_note.as_deref()), (true, Some("checking")));
        let blocked = parse_detail(&pull(json!({"mergeable_state": "BLOCKED"})), None).unwrap();
        assert_eq!(blocked.merge_note.as_deref(), Some("blocked"));

        let repository =
            json!({"full_name": "a/b", "allow_merge_commit": false, "allow_rebase_merge": true, "permissions": {"push": false}});
        let read_only = parse_detail(&pull(json!({})), Some(&repository)).unwrap();
        assert_eq!(read_only.methods, vec!["squash", "rebase"]);
        assert_eq!((read_only.can_merge, read_only.merge_note.as_deref()), (false, Some("noAccess")));

        let mut failing = parse_detail(&pull(json!({})), None).unwrap();
        failing.checks = parse_checks(&[json!({"name": "ci", "status": "completed", "conclusion": "failure"})], &[]);
        let failing = failing.finish();
        assert_eq!((failing.check_summary, failing.merge_note.as_deref(), failing.can_merge), (Ci::Failing, Some("unstable"), true));
    }

    #[test]
    fn checks_failing_first() {
        let runs = [
            json!({"name": "lint", "status": "completed", "conclusion": "success", "html_url": "https://x.y/1"}),
            json!({"name": "build", "status": "in_progress"}),
            json!({"name": "docs", "status": "completed", "conclusion": "skipped"}),
            json!({"name": "test", "status": "completed", "conclusion": "timed_out", "details_url": "https://x.y/2"}),
        ];
        let statuses = [json!({"context": "deploy", "state": "error", "description": "", "target_url": "javascript:x"})];
        let checks = parse_checks(&runs, &statuses);
        let names: Vec<(&str, CheckOutcome, &str)> = checks.iter().map(|c| (c.name.as_str(), c.outcome, c.detail.as_str())).collect();
        assert_eq!(
            names,
            vec![
                ("test", CheckOutcome::Failing, "timed_out"),
                ("deploy", CheckOutcome::Failing, "error"),
                ("build", CheckOutcome::Pending, "in_progress"),
                ("lint", CheckOutcome::Passing, "success"),
                ("docs", CheckOutcome::Skipped, "skipped"),
            ]
        );
        assert_eq!(checks[0].url.as_deref(), Some("https://x.y/2"));
        // Only https links are kept, so the view never opens anything else.
        assert_eq!(checks[1].url, None);
    }

    #[test]
    fn one_timeline_oldest_first() {
        let commits = parse_commits(&[
            json!({"sha": "c1abcdef0", "commit": {"message": "Add parser\n\nBody", "author": {"name": "Ada L", "date": "2026-10-18T13:00:00Z"}}, "author": null}),
        ]);
        assert_eq!((commits[0].author.as_str(), commits[0].subject()), ("Ada L", "Add parser".to_string()));
        let events = parse_events(
            &[
                json!({"id": 1, "state": "APPROVED", "body": "", "user": {"login": "bob"}, "submitted_at": "2026-10-18T15:00:00Z"}),
                json!({"id": 2, "state": "COMMENTED", "body": "", "user": {"login": "bob"}, "submitted_at": "2026-10-18T15:01:00Z"}),
                json!({"id": 3, "state": "PENDING", "body": "draft", "user": {"login": "bob"}}),
            ],
            &[json!({"id": 4, "body": "<!-- bot -->Nice &amp; tidy", "user": {"login": "cy"}, "created_at": "2026-10-18T14:00:00Z"})],
            &[
                json!({"id": 5, "body": "typo", "path": "a.rs", "original_line": 3, "user": {"login": "cy"}, "created_at": "2026-10-18T14:30:00Z"}),
            ],
            &[
                json!({"id": 6, "event": "labeled", "label": {"name": "bug"}, "actor": {"login": "ada"}, "created_at": "2026-10-18T12:30:00Z"}),
                json!({"id": 7, "event": "subscribed", "actor": {"login": "ada"}, "created_at": "2026-10-18T12:31:00Z"}),
                json!({"id": 8, "event": "cross-referenced", "source": {"issue": {"number": 9, "title": "Crash", "repository": {"full_name": "a/c"}}}, "actor": {"login": "dee"}, "created_at": "2026-10-18T16:00:00Z"}),
            ],
            &commits,
        );
        let kinds: Vec<&EventKind> = events.iter().map(|e| &e.kind).collect();
        assert_eq!(
            kinds,
            vec![
                &EventKind::Activity { event: "labeled".into(), detail: "bug".into() },
                &EventKind::Commit { sha: "c1abcdef0".into() },
                &EventKind::Comment,
                &EventKind::LineComment { path: "a.rs".into(), line: Some(3) },
                &EventKind::Review { state: "APPROVED".into() },
                &EventKind::Activity { event: "cross-referenced".into(), detail: "a/c#9 Crash".into() },
            ]
        );
        assert_eq!(events[2].body, "Nice & tidy");
        assert_eq!(events[2].id, "comment-4");
        let json = serde_json::to_value(&events[3]).unwrap();
        assert_eq!((json["kind"].as_str(), json["path"].as_str(), json["line"].as_i64()), (Some("lineComment"), Some("a.rs"), Some(3)));
    }

    #[test]
    fn files_and_merging() {
        let files = parse_files(&[
            json!({"filename": "b.rs", "previous_filename": "a.rs", "status": "renamed", "additions": 1, "deletions": 0}),
            json!({"status": "added"}),
        ]);
        assert_eq!(files.len(), 1);
        assert_eq!((files[0].previous_path.as_deref(), files[0].patch.as_deref()), (Some("a.rs"), None));
        assert_eq!(merge_body("squash", Some("abc")), json!({"merge_method": "squash", "sha": "abc"}));
        assert_eq!(merge_body("merge", Some("")), json!({"merge_method": "merge"}));
        assert_eq!(merge_error(401, &json!({})).kind, ErrorKind::Auth);
        assert!(merge_error(409, &json!({"message": "Head branch was modified"})).message.starts_with("De branch is veranderd"));
        assert_eq!(
            merge_error(405, &json!({"message": "Pull Request is not mergeable"})).message,
            "GitHub kan deze pull request niet mergen (405). Pull Request is not mergeable"
        );
        assert_eq!(merge_error(500, &json!({})).message, "GitHub gaf een fout (500).");
    }

    #[test]
    fn open_first_sorts_newest_and_dedupes() {
        let items = vec![
            item("a/b", 1, "2026-10-17T12:00:00Z", PullState::Closed),
            item("a/b", 2, "2026-10-17T12:00:00Z", PullState::Open),
            item("a/b", 3, "2026-10-19T12:00:00Z", PullState::Open),
            item("a/b", 3, "2026-10-19T12:00:00Z", PullState::Open),
        ];
        assert_eq!(open_first(items).iter().map(|i| i.number).collect::<Vec<_>>(), vec![3, 2, 1]);
    }
}
