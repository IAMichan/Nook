//! The companion's `pulls` area on Windows and Linux: pull requests on the phone, as the Mac's
//! `CompanionServer+PullRequests.swift` answers them, from what Agents › Pull requests reads here. That is GitHub, with
//! the accounts in Settings › Connections; this app has no pull request page for GitLab or the other forges yet, so the
//! phone gets GitHub's only (docs/INTEGRATIONS.md). The shapes are `nook_core::companion::pull_digest`.
//!
//! Every action is the phone's own tap and keeps the rules of the pull request page here: a review or a merge goes only
//! at the head the phone saw, a merge only when the quick merge would allow it, and each lands in the action log as the
//! page writes it (`github_review_pr`, `github_merge_pr`) and as the phone's (`companion_pr_review`,
//! `companion_pr_merge`). "Work on this" (`pullWork`) needs a checkout of the pull request's branch in a worktree,
//! which the workspace here cannot make yet, so it is refused with a reason.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use nook_core::companion::pull_digest::{self, ActionKind, Group, PullAction, PullDigest, ViewedMarks};
use nook_core::companion::sessions::HUB_PREFIX;
use nook_core::companion::{feature, CompanionError, CompanionOp, CompanionRequest, CompanionResponse};
use nook_core::connectors::hub::Connector as _;
use nook_core::connectors::pulls::{self, AccountPullRequests, PullRequestDetail};
use nook_core::connectors::ConnectorError;
use nook_core::workspace::source_control::{RemoteRepository, SourceControlHost};
use serde::Serialize;
use tauri::{AppHandle, Manager as _};
use uuid::Uuid;

use crate::connectors::Connectors;
use crate::state::AppState;
use crate::workspace::WorkspaceState;

/// How long a list read from GitHub is answered as it is; an older one is read again in the background.
const FRESH: Duration = Duration::from_secs(30);

/// The last list of every account, and when it was read.
static LIST: Mutex<Option<(Instant, Vec<AccountPullRequests>)>> = Mutex::new(None);
/// One read of the list at a time.
static READING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// The `feature` names this area can answer: pull requests once a GitHub account is connected.
pub fn features(app: &AppHandle) -> Vec<&'static str> {
    let Some(c) = app.try_state::<Connectors>() else { return Vec::new() };
    if c.github.token_for(None).is_none() {
        return Vec::new();
    }
    vec![feature::PULL_REQUESTS]
}

/// The answer to one of this area's ops; `None` when it cannot.
pub async fn handle(app: &AppHandle, request: &CompanionRequest, _device: &str) -> Option<CompanionResponse> {
    app.try_state::<Connectors>()?;
    Some(match request.op {
        CompanionOp::Pulls => match &request.session {
            Some(session) => linked(app, request, session).await,
            None => list(app, request).await,
        },
        CompanionOp::Pull => pull(app, request).await,
        CompanionOp::PullAct => act(app, request).await,
        CompanionOp::PullWork => CompanionResponse {
            message: Some("Working on a pull request from the phone is not available on this computer yet.".into()),
            ..CompanionResponse::failure(&request.id, CompanionError::NotAllowedFromPhone)
        },
        _ => return None,
    })
}

fn json<T: Serialize>(value: &T) -> Option<serde_json::Value> {
    serde_json::to_value(value).ok()
}

fn failed(request: &CompanionRequest, message: impl Into<String>) -> CompanionResponse {
    CompanionResponse { message: Some(message.into()), ..CompanionResponse::failure(&request.id, CompanionError::Failed) }
}

fn audit(app: &AppHandle, tool: &str, args: &str, result: &str) {
    if let Some(state) = app.try_state::<AppState>() {
        state.store.audit(tool, args, result);
    }
}

// Lists

async fn read_list(app: &AppHandle) -> Vec<AccountPullRequests> {
    let _one = READING.lock().await;
    if let Some((at, accounts)) = LIST.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        if at.elapsed() < FRESH {
            return accounts.clone();
        }
    }
    let Some(c) = app.try_state::<Connectors>() else { return Vec::new() };
    let watching = app.try_state::<AppState>().map(|s| s.settings().watched_pull_requests).unwrap_or_default();
    let accounts = c.github.pull_request_list(&watching).await.accounts;
    *LIST.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), accounts.clone()));
    accounts
}

/// The list as read last; a list older than half a minute is read again in the background, and the first one is
/// waited for.
async fn accounts(app: &AppHandle) -> Vec<AccountPullRequests> {
    let kept = LIST.lock().unwrap_or_else(|e| e.into_inner()).clone();
    match kept {
        Some((at, accounts)) => {
            if at.elapsed() >= FRESH {
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    read_list(&app).await;
                });
            }
            accounts
        }
        None => read_list(app).await,
    }
}

/// Something changed on GitHub through the phone: the next list is read again.
fn forget_list() {
    if let Some((at, _)) = LIST.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        *at = Instant::now() - FRESH;
    }
}

/// Agents › Pull requests: yours, the ones for your review, and the watched ones, of every account that read.
async fn list(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let mut rows = Vec::new();
    for account in accounts(app).await.iter().filter(|a| a.error.is_none()) {
        rows.extend(account.mine.iter().map(|p| pull_digest::item_digest(p, Group::Mine)));
        rows.extend(account.reviews.iter().map(|p| pull_digest::item_digest(p, Group::Review)));
        rows.extend(account.watched.iter().map(|p| pull_digest::item_digest(p, Group::Watched)));
    }
    CompanionResponse { pulls: json(&pull_digest::trimmed(rows, pull_digest::MAX_LIST)), ..CompanionResponse::success(&request.id) }
}

/// The pull requests of a session's branch on GitHub. An agent outside Nook has none the phone can ask for.
async fn linked(app: &AppHandle, request: &CompanionRequest, session: &str) -> CompanionResponse {
    let empty = || CompanionResponse { pulls: json(&Vec::<PullDigest>::new()), ..CompanionResponse::success(&request.id) };
    if session.starts_with(HUB_PREFIX) {
        return empty();
    }
    let run = Uuid::parse_str(session).ok().and_then(|id| app.try_state::<WorkspaceState>()?.manager.run(id));
    let Some(run) = run else { return CompanionResponse::failure(&request.id, CompanionError::UnknownSession) };
    let manager = app.state::<WorkspaceState>().manager.clone();
    let place = tauri::async_runtime::spawn_blocking(move || {
        let git = manager.git()?;
        let dir = run.working_directory.clone();
        let remotes = git.remotes(&dir);
        let remote = if remotes.iter().any(|r| r == "origin") { Some("origin".to_string()) } else { remotes.first().cloned() }?;
        let repository = git.remote_url(&dir, &remote).and_then(|u| RemoteRepository::detect(&u))?;
        let branch = run.branch.clone().or_else(|| git.current_branch(&dir))?;
        (repository.host == SourceControlHost::Github).then(|| (repository.display_name(), branch))
    })
    .await
    .ok()
    .flatten();
    let Some((repo, branch)) = place else { return empty() };
    let Some(c) = app.try_state::<Connectors>() else { return empty() };
    let env = c.env.clone();
    for token in crate::workspace::github_tokens(app, &repo) {
        if let Ok(found) = pulls::branch_pulls(&env, &token, &repo, &branch).await {
            let rows = found.iter().filter_map(pull_digest::linked_digest).collect();
            return CompanionResponse {
                pulls: json(&pull_digest::trimmed(rows, pull_digest::MAX_LIST)),
                ..CompanionResponse::success(&request.id)
            };
        }
    }
    empty()
}

// One pull request

/// A pull request the phone names by its address, with the account to read and act on it as: the one whose list holds
/// it, else the first one with a token.
struct Target {
    url: String,
    repo: String,
    number: i64,
    account: String,
    token: String,
}

async fn target(app: &AppHandle, address: Option<&str>) -> Option<Target> {
    let url = address?.trim().to_string();
    let (repo, number) = pull_digest::parse_url(&url)?;
    let listed = accounts(app)
        .await
        .into_iter()
        .find(|a| a.mine.iter().chain(&a.reviews).chain(&a.watched).any(|p| p.repo.eq_ignore_ascii_case(&repo) && p.number == number));
    let c = app.try_state::<Connectors>()?;
    let (account, token) = c.github.token_for(listed.as_ref().map(|a| a.id.as_str()))?;
    Some(Target { url, repo, number, account, token })
}

async fn read(app: &AppHandle, target: &Target) -> Result<PullRequestDetail, ConnectorError> {
    let env = app.state::<Connectors>().env.clone();
    pulls::load_detail(&env, &target.token, &target.repo, target.number).await
}

fn marks_path(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|d| d.join("companion-pull-viewed.json"))
}

async fn load_marks(app: &AppHandle) -> ViewedMarks {
    let Some(path) = marks_path(app) else { return ViewedMarks::default() };
    tauri::async_runtime::spawn_blocking(move || std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default())
        .await
        .unwrap_or_default()
}

async fn save_marks(app: &AppHandle, marks: ViewedMarks) {
    let Some(path) = marks_path(app) else { return };
    let _ = tauri::async_runtime::spawn_blocking(move || {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec(&marks) {
            let _ = std::fs::write(path, data);
        }
    })
    .await;
}

fn now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}

fn answer(request: &CompanionRequest, detail: &PullRequestDetail, url: &str, marks: &ViewedMarks) -> CompanionResponse {
    CompanionResponse { pull: json(&pull_digest::detail_digest(detail, url, marks, now())), ..CompanionResponse::success(&request.id) }
}

/// One pull request in full: its summary, checks and files with their patches and viewed marks.
async fn pull(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let Some(target) = target(app, request.item.as_deref()).await else {
        return CompanionResponse::failure(&request.id, CompanionError::UnknownItem);
    };
    match read(app, &target).await {
        Ok(detail) => answer(request, &detail, &target.url, &load_marks(app).await),
        Err(e) => failed(request, e.message),
    }
}

const MOVED_ON: &str = "This pull request changed since your phone read it. Look at it again first.";

/// What the phone asks of a pull request: a review (with comments on lines), a viewed mark, or a merge.
async fn act(app: &AppHandle, request: &CompanionRequest) -> CompanionResponse {
    let Some(action) = PullAction::parse(request.pull_action.as_ref()) else {
        return CompanionResponse::failure(&request.id, CompanionError::BadRequest);
    };
    let Some(target) = target(app, request.item.as_deref()).await else {
        return CompanionResponse::failure(&request.id, CompanionError::UnknownItem);
    };
    let detail = match read(app, &target).await {
        Ok(detail) => detail,
        Err(e) => return failed(request, e.message),
    };
    match action.kind {
        ActionKind::Viewed | ActionKind::Unviewed => {
            let Some(file) = detail.files.iter().find(|f| Some(f.path.as_str()) == action.path.as_deref()) else {
                return CompanionResponse::failure(&request.id, CompanionError::UnknownItem);
            };
            let mut marks = load_marks(app).await;
            marks.set(&ViewedMarks::key(&detail.repo, detail.number), file, action.kind == ActionKind::Viewed);
            save_marks(app, marks.clone()).await;
            answer(request, &detail, &target.url, &marks)
        }
        ActionKind::Approve | ActionKind::RequestChanges | ActionKind::Comment => review(app, request, &action, &target, &detail).await,
        ActionKind::Merge => merge(app, request, &action, &target, &detail).await,
    }
}

async fn review(
    app: &AppHandle,
    request: &CompanionRequest,
    action: &PullAction,
    target: &Target,
    detail: &PullRequestDetail,
) -> CompanionResponse {
    if action.head.as_deref().is_some_and(|h| !h.is_empty() && h != detail.head_sha) {
        return failed(request, MOVED_ON);
    }
    let Some(event) = action.event() else { return CompanionResponse::failure(&request.id, CompanionError::BadRequest) };
    let body = action.review_body();
    let notes = action.comments.clone().unwrap_or_default();
    let c = app.state::<Connectors>();
    let args = format!("{}#{} · {event} · {}", detail.repo, detail.number, target.account);
    let result = if notes.is_empty() {
        let input =
            serde_json::json!({"repo": detail.repo, "number": detail.number, "event": event, "body": body, "account": target.account});
        c.github.execute("github_review_pr", &input).await.unwrap_or_else(|| Err(ConnectorError::not_set_up("GitHub")))
    } else {
        let comments = pull_digest::review_comments(&notes);
        pulls::review_with_comments(&c.env, &target.token, &detail.repo, detail.number, event, &body, &detail.head_sha, comments)
            .await
            .map(|_| format!("Review with {} comments on {}#{}", notes.len(), detail.repo, detail.number))
    };
    match result {
        Ok(text) => {
            audit(app, "github_review_pr", &args, &text);
            let note = if notes.is_empty() { String::new() } else { format!(" · {} comments", notes.len()) };
            audit(app, "companion_pr_review", &format!("{}#{} · {event}{note}", detail.repo, detail.number), "ok");
        }
        Err(e) => {
            audit(app, "github_review_pr", &args, &format!("error: {}", e.message));
            return failed(request, e.message);
        }
    }
    forget_list();
    match read(app, target).await {
        Ok(fresh) => answer(request, &fresh, &target.url, &load_marks(app).await),
        Err(_) => answer(request, detail, &target.url, &load_marks(app).await),
    }
}

async fn merge(
    app: &AppHandle,
    request: &CompanionRequest,
    action: &PullAction,
    target: &Target,
    detail: &PullRequestDetail,
) -> CompanionResponse {
    if action.head.as_deref() != Some(detail.head_sha.as_str()) {
        return failed(request, MOVED_ON);
    }
    if let Some(blocker) = pull_digest::blocker(detail) {
        let why = match blocker {
            "merged" => "is already merged",
            "closed" => "is closed",
            "draft" => "is still a draft",
            "access" => "cannot be merged with this account",
            _ => "has a merge conflict",
        };
        return failed(request, format!("#{} {why}.", detail.number));
    }
    let Some(method) = pull_digest::merge_method(action.method.as_deref(), &detail.methods) else {
        return failed(request, format!("The repository allows no merge method for #{}.", detail.number));
    };
    let c = app.state::<Connectors>();
    let input = serde_json::json!({
        "repo": detail.repo, "number": detail.number, "method": method, "sha": detail.head_sha, "account": target.account
    });
    let short: String = detail.head_sha.chars().take(7).collect();
    let args = format!("{}#{} · {method} · {short} · {}", detail.repo, detail.number, target.account);
    match c.github.execute("github_merge_pr", &input).await.unwrap_or_else(|| Err(ConnectorError::not_set_up("GitHub"))) {
        Ok(text) => {
            audit(app, "github_merge_pr", &args, &text);
            audit(
                app,
                "companion_pr_merge",
                &format!("{}#{} · {method} · {} → {}", detail.repo, detail.number, detail.head_branch, detail.base_branch),
                "ok",
            );
        }
        Err(e) => {
            audit(app, "github_merge_pr", &args, &format!("error: {}", e.message));
            return failed(request, e.message);
        }
    }
    forget_list();
    let fresh = read(app, target).await.ok();
    let marks = load_marks(app).await;
    CompanionResponse {
        message: Some("merged".into()),
        pull: fresh.map(|d| pull_digest::detail_digest(&d, &target.url, &marks, now())).and_then(|d| json(&d)),
        ..CompanionResponse::success(&request.id)
    }
}
