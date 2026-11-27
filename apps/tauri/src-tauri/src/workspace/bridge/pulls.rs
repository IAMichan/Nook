//! Pull request / merge request status & background watching bridge tools (`get_pull_request_status`,
//! `watch_pull_request`, AG-10).
//!
//! Uses Nook's GitHub connector (`nook_core::connectors::pulls`) and GitLab PAT connector (`nook_core::connectors::gitlab`)
//! to read PR/MR state, CI checks, mergeability, reviews and comments. Active watches poll in the background every 60s
//! and wake the session when CI fails/passes, merge conflicts appear, new reviews/comments arrive, or the PR merges/closes.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use nook_core::connectors::forge;
use nook_core::connectors::pulls::{self, CheckOutcome, DetailState, EventKind as PrEventKind, PullRequestDetail};
use nook_core::workspace::bridge::{
    diff_pr_snapshots, parse_pr_target, render_pr_status, BridgeCaller, BridgeTool, PrCheckSummary, PrHost, PrReviewSummary,
    PullRequestRef, PullRequestSnapshot, PullRequestTarget, ToolResult, Verdict,
};
use nook_core::workspace::source_control::{RemoteRepository, SourceControlHost};
use serde_json::{Map, Value};
use tauri::{AppHandle, Manager};
use uuid::Uuid;

use super::{audit, check, note_run, refusal, workspace, Context};
use crate::agents::lock;
use crate::connectors::Connectors;

const WATCH_POLL_SECONDS: u64 = 60;
const MAX_WATCH_ERRORS: u32 = 5;

struct ActiveWatch {
    reference: PullRequestRef,
    handle: tauri::async_runtime::JoinHandle<()>,
}

static WATCHES: Mutex<Option<HashMap<Uuid, ActiveWatch>>> = Mutex::new(None);

fn stop_watch(run_id: Uuid) -> Option<PullRequestRef> {
    let mut guard = lock(&WATCHES);
    let removed = guard.as_mut().and_then(|map| map.remove(&run_id))?;
    removed.handle.abort();
    Some(removed.reference)
}

fn pr_ref_for_repo(repo: &RemoteRepository, number: i64, fallback_url: Option<String>) -> Result<PullRequestRef, String> {
    let url = fallback_url.or_else(|| repo.pull_request_url(number as u64)).unwrap_or_default();
    let (host, repo_key) = match &repo.host {
        SourceControlHost::Github => (PrHost::Github, repo.display_name()),
        SourceControlHost::Gitlab => (PrHost::GitLab(repo.host_name.clone()), repo.path.clone()),
        SourceControlHost::Gitea | SourceControlHost::Forgejo | SourceControlHost::Unknown(_) => {
            (PrHost::Gitea(repo.host_name.clone()), repo.path.clone())
        }
        SourceControlHost::Gitcafe => (PrHost::GitCafe(repo.host_name.clone()), repo.path.clone()),
        SourceControlHost::Bitbucket => (PrHost::Bitbucket(repo.host_name.clone()), repo.path.clone()),
        SourceControlHost::AzureDevOps => (PrHost::AzureDevOps(repo.host_name.clone()), repo.path.clone()),
    };
    Ok(PullRequestRef { host, repo: repo_key, number, url })
}

async fn resolve_target(app: &AppHandle, target: PullRequestTarget, caller: &BridgeCaller) -> Result<PullRequestRef, String> {
    match target {
        PullRequestTarget::Ref(r) => Ok(r),
        PullRequestTarget::Number(number) => {
            let repo = detect_remote(app, &caller.directory).await?;
            pr_ref_for_repo(&repo, number, None)
        }
        PullRequestTarget::Current => {
            let (repo, branch) = detect_remote_and_branch(app, &caller.directory).await?;
            let branch = branch.ok_or("This folder is not on a branch (detached HEAD). Pass url or number.")?;
            match repo.host {
                SourceControlHost::Github => find_github_branch_pr(app, &repo.display_name(), &branch).await,
                _ => find_forge_branch_pr(app, &repo, &branch).await,
            }
        }
    }
}

async fn detect_remote_and_branch(app: &AppHandle, directory: &str) -> Result<(RemoteRepository, Option<String>), String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let manager = ws.manager.clone();
    let dir = directory.to_string();
    let (remote_url, branch) = tauri::async_runtime::spawn_blocking(move || {
        let g = manager.git()?;
        let remotes = g.remotes(&dir);
        let remote = if remotes.iter().any(|r| r == "origin") {
            "origin".to_string()
        } else {
            remotes.first().cloned().unwrap_or_else(|| "origin".into())
        };
        Some((g.remote_url(&dir, &remote), g.current_branch(&dir)))
    })
    .await
    .map_err(|e| e.to_string())?
    .ok_or("Git is not available on this computer.")?;
    let repo = remote_url
        .as_deref()
        .and_then(RemoteRepository::detect)
        .ok_or("This folder has no remote Nook recognises. Pass url or repository + number.")?;
    Ok((repo, branch))
}

async fn detect_remote(app: &AppHandle, directory: &str) -> Result<RemoteRepository, String> {
    Ok(detect_remote_and_branch(app, directory).await?.0)
}

async fn find_github_branch_pr(app: &AppHandle, repo: &str, branch: &str) -> Result<PullRequestRef, String> {
    let tokens = crate::workspace::github_tokens(app, repo);
    if tokens.is_empty() {
        return Err("No GitHub account is connected in Nook (Settings › Accounts & connections).".into());
    }
    let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
    let env = connectors.env.clone();
    let mut last_err = None;
    for token in tokens {
        match pulls::branch_pulls(&env, &token, repo, branch).await {
            Ok(list) => {
                // Prefer an open PR; fall back to the most recent closed/merged PR for this branch.
                let picked = list.iter().find(|p| p["state"].as_str() == Some("open")).or_else(|| list.first());
                if let Some(pr) = picked {
                    if let Some(number) = pr["number"].as_i64() {
                        let url = pr["html_url"]
                            .as_str()
                            .map(str::to_string)
                            .unwrap_or_else(|| format!("https://github.com/{repo}/pull/{number}"));
                        return Ok(PullRequestRef { host: PrHost::Github, repo: repo.to_string(), number, url });
                    }
                }
                return Err(format!("No pull request found on {repo} for branch \"{branch}\"."));
            }
            Err(e) => last_err = Some(e.message),
        }
    }
    Err(last_err.unwrap_or_else(|| format!("Could not query pull requests for {repo}.")))
}

async fn find_forge_branch_pr(app: &AppHandle, repo: &RemoteRepository, branch: &str) -> Result<PullRequestRef, String> {
    let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
    if forge::token_for_repo(connectors.env.secrets.as_ref(), repo).is_none() {
        return Err(format!("No token is connected for {} (Settings › Pull requests › Code hosts).", repo.host_name));
    }
    let summary = forge::branch_pull_requests(&connectors.env.http, connectors.env.secrets.as_ref(), repo, branch)
        .await
        .ok_or_else(|| format!("Could not query {} for pull requests on branch \"{branch}\".", repo.host_name))?;
    let picked = summary.open.or_else(|| summary.all.into_iter().next()).ok_or_else(|| {
        let kind = if repo.host.uses_merge_requests() { "merge request" } else { "pull request" };
        format!("No {kind} found on {}/{} for branch \"{branch}\".", repo.host_name, repo.display_name())
    })?;
    pr_ref_for_repo(repo, picked.number, Some(picked.url))
}

async fn fetch_snapshot(app: &AppHandle, reference: &PullRequestRef) -> Result<PullRequestSnapshot, String> {
    match &reference.host {
        PrHost::Github => fetch_github_snapshot(app, reference).await,
        _ => {
            let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
            forge::fetch_snapshot(&connectors.env.http, connectors.env.secrets.as_ref(), reference).await
        }
    }
}

async fn fetch_github_snapshot(app: &AppHandle, reference: &PullRequestRef) -> Result<PullRequestSnapshot, String> {
    let tokens = crate::workspace::github_tokens(app, &reference.repo);
    if tokens.is_empty() {
        return Err("No GitHub account is connected in Nook (Settings › Accounts & connections).".into());
    }
    let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
    let env = connectors.env.clone();
    let host = nook_core::connectors::ForgeRateBudget::host_of(&nook_core::connectors::github::api())
        .unwrap_or_else(|| "api.github.com".to_string());
    let use_graphql = env.http.budget.prefers_graphql(&host, chrono::Utc::now());
    let mut last_err = None;
    for token in tokens {
        if use_graphql {
            match pulls::load_snapshot_graphql(&env, &token, &reference.repo, reference.number, &reference.url).await {
                Ok(snapshot) => return Ok(snapshot),
                Err(e) if e.kind == nook_core::connectors::ErrorKind::RateLimited => last_err = Some(e.message),
                Err(e) => {
                    last_err = Some(e.message);
                    if let Ok(detail) = pulls::load_detail(&env, &token, &reference.repo, reference.number).await {
                        return Ok(snapshot_from_github(detail, &reference.url));
                    }
                }
            }
        } else {
            match pulls::load_detail(&env, &token, &reference.repo, reference.number).await {
                Ok(detail) => return Ok(snapshot_from_github(detail, &reference.url)),
                Err(e) => last_err = Some(e.message),
            }
        }
    }
    Err(last_err.unwrap_or_else(|| format!("Could not read pull request {}#{}.", reference.repo, reference.number)))
}

fn snapshot_from_github(detail: PullRequestDetail, fallback_url: &str) -> PullRequestSnapshot {
    let state = match detail.state {
        DetailState::Open => "open",
        DetailState::Draft => "draft",
        DetailState::Merged => "merged",
        DetailState::Closed => "closed",
    }
    .to_string();
    let checks = detail
        .checks
        .iter()
        .map(|c| PrCheckSummary {
            name: c.name.clone(),
            outcome: match c.outcome {
                CheckOutcome::Passing => "passing",
                CheckOutcome::Failing => "failing",
                CheckOutcome::Pending => "pending",
                CheckOutcome::Skipped => "skipped",
            }
            .into(),
            detail: c.detail.clone(),
        })
        .collect();
    let mut reviews = Vec::new();
    let mut comment_ids = Vec::new();
    for event in &detail.events {
        match &event.kind {
            PrEventKind::Review { state } => {
                reviews.push(PrReviewSummary {
                    id: event.id.clone(),
                    author: event.author.clone(),
                    state: state.clone(),
                    body: event.body.clone(),
                });
            }
            PrEventKind::Comment | PrEventKind::LineComment { .. } => {
                comment_ids.push(event.id.clone());
            }
            _ => {}
        }
    }
    PullRequestSnapshot {
        repo: detail.repo.clone(),
        number: detail.number,
        title: detail.title.clone(),
        url: detail.url.clone().unwrap_or_else(|| fallback_url.to_string()),
        state,
        head_branch: detail.head_branch.clone(),
        base_branch: detail.base_branch.clone(),
        head_sha: detail.head_sha.clone(),
        conflicted: detail.conflicted(),
        merge_state: detail.merge_state.clone(),
        checks,
        reviews,
        comment_ids,
    }
}

pub(super) async fn get_pull_request_status(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    if let Verdict::Refuse(reason) = check(app, BridgeTool::GetPullRequestStatus, caller, None) {
        return Err(refusal(reason).into());
    }
    let target = parse_pr_target(a)?;
    let reference = resolve_target(app, target, caller).await?;
    let snapshot = fetch_snapshot(app, &reference).await?;
    Ok(ToolResult::text(render_pr_status(&snapshot)))
}

pub(super) async fn watch_pull_request(
    app: &AppHandle,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    _context: &Context,
) -> Result<ToolResult, String> {
    if let Verdict::Refuse(reason) = check(app, BridgeTool::WatchPullRequest, caller, None) {
        return Err(refusal(reason).into());
    }
    let run_id = caller
        .run
        .as_deref()
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or("watch_pull_request requires a Nook-managed session so Nook can wake it when the pull request changes.")?;

    if a.get("stop").and_then(Value::as_bool) == Some(true) {
        return match stop_watch(run_id) {
            Some(prev) => {
                audit(app, BridgeTool::WatchPullRequest, caller, &prev.url, "gestopt");
                note_run(app, caller, &format!("Volgen van PR {}#{} gestopt", prev.repo, prev.number));
                Ok(ToolResult::text(format!("Stopped watching {}#{} ({}).", prev.repo, prev.number, prev.url)))
            }
            None => Ok(ToolResult::text("No pull request was being watched for this session.")),
        };
    }

    let target = parse_pr_target(a)?;
    let reference = resolve_target(app, target, caller).await?;
    let initial = fetch_snapshot(app, &reference).await?;

    if initial.is_terminal() {
        return Ok(ToolResult::text(format!(
            "Not watching {}#{} because it is already {}.\n\n{}",
            initial.repo,
            initial.number,
            initial.state,
            render_pr_status(&initial)
        )));
    }

    // Replace any previous watch for this session.
    let _ = stop_watch(run_id);

    let app_bg = app.clone();
    let ref_bg = reference.clone();
    let mut last_snapshot = initial.clone();
    let handle = tauri::async_runtime::spawn(async move {
        let mut failures = 0u32;
        let is_github = matches!(ref_bg.host, PrHost::Github);
        loop {
            let slowdown = app_bg
                .try_state::<Connectors>()
                .map(|c| c.env.http.budget.slowdown_for_page(Some(&ref_bg.url), is_github, chrono::Utc::now()))
                .unwrap_or(1.0);
            let wait_secs = ((WATCH_POLL_SECONDS as f64) * slowdown).round().max(WATCH_POLL_SECONDS as f64) as u64;
            tokio::time::sleep(Duration::from_secs(wait_secs)).await;
            let Some(ws) = workspace(&app_bg) else { break };
            let Some(run) = ws.manager.run(run_id) else { break };
            if run.archived {
                break;
            }
            if let Some(connectors) = app_bg.try_state::<Connectors>() {
                if !connectors.env.http.budget.allows_background_for_page(Some(&ref_bg.url), is_github, chrono::Utc::now()) {
                    continue;
                }
            }
            match fetch_snapshot(&app_bg, &ref_bg).await {
                Ok(next) => {
                    failures = 0;
                    let diffs = diff_pr_snapshots(&last_snapshot, &next);
                    if !diffs.is_empty() {
                        let summary = format!(
                            "Watched pull request {}#{} updated ({}):\n- {}\n\nUse get_pull_request_status for full details.",
                            next.repo,
                            next.number,
                            next.url,
                            diffs.join("\n- ")
                        );
                        ws.manager.append_event(
                            run_id,
                            nook_core::workspace::models::RunEvent::new(
                                nook_core::workspace::models::EventKind::System,
                                format!("PR {}#{}: {}", next.repo, next.number, diffs.join(" · ")),
                            )
                            .with_tool("prwatch"),
                        );
                        if run.status.is_active() {
                            ws.manager.enqueue(run_id, &summary);
                        } else {
                            let _ = ws.manager.send(run_id, &summary);
                        }
                    }
                    let done = next.is_terminal();
                    last_snapshot = next;
                    if done {
                        break;
                    }
                }
                Err(_) => {
                    failures += 1;
                    if failures >= MAX_WATCH_ERRORS {
                        ws.manager.note(
                            run_id,
                            &format!("Volgen van PR {}#{} gestopt na herhaalde verbindingsfouten.", ref_bg.repo, ref_bg.number),
                        );
                        break;
                    }
                }
            }
        }
        if let Some(map) = lock(&WATCHES).as_mut() {
            map.remove(&run_id);
        }
    });

    lock(&WATCHES).get_or_insert_with(HashMap::new).insert(run_id, ActiveWatch { reference: reference.clone(), handle });

    audit(app, BridgeTool::WatchPullRequest, caller, &reference.url, "gestart");
    note_run(app, caller, &format!("Volgt PR {}#{} ({})", reference.repo, reference.number, reference.url));

    Ok(ToolResult::text(format!(
        "Now watching {}#{} ({}). Nook will check every {WATCH_POLL_SECONDS}s and wake this session on CI failures, merge conflicts, new reviews/comments, or merge/close.\n\n{}",
        initial.repo,
        initial.number,
        initial.url,
        render_pr_status(&initial)
    )))
}
