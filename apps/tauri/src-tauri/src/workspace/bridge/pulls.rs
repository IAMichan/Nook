//! Pull request / merge request status & background watching bridge tools (`get_pull_request_status`,
//! `watch_pull_request`, AG-10).
//!
//! Uses Nook's GitHub connector (`nook_core::connectors::pulls`) and GitLab PAT connector (`nook_core::connectors::gitlab`)
//! to read PR/MR state, CI checks, mergeability, reviews and comments. Active watches poll in the background every 60s
//! and wake the session when CI fails/passes, merge conflicts appear, new reviews/comments arrive, or the PR merges/closes.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use nook_core::connectors::gitlab;
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

async fn resolve_target(app: &AppHandle, target: PullRequestTarget, caller: &BridgeCaller) -> Result<PullRequestRef, String> {
    match target {
        PullRequestTarget::Ref(r) => Ok(r),
        PullRequestTarget::Number(number) => {
            let repo = detect_remote(app, &caller.directory).await?;
            match repo.host {
                SourceControlHost::Github => Ok(PullRequestRef {
                    host: PrHost::Github,
                    url: format!("https://github.com/{}/pull/{number}", repo.display_name()),
                    repo: repo.display_name(),
                    number,
                }),
                SourceControlHost::Gitlab => Ok(PullRequestRef {
                    host: PrHost::GitLab(repo.host_name.clone()),
                    url: format!("https://{}/{}/-/merge_requests/{number}", repo.host_name, repo.display_name()),
                    repo: repo.display_name(),
                    number,
                }),
                _ => Err(format!("Unsupported host {} for pull request status (GitHub and GitLab are supported).", repo.host.name())),
            }
        }
        PullRequestTarget::Current => {
            let (repo, branch) = detect_remote_and_branch(app, &caller.directory).await?;
            let branch = branch.ok_or("This folder is not on a branch (detached HEAD). Pass url or number.")?;
            match repo.host {
                SourceControlHost::Github => find_github_branch_pr(app, &repo.display_name(), &branch).await,
                SourceControlHost::Gitlab => find_gitlab_branch_mr(app, &repo.host_name, &repo.display_name(), &branch).await,
                _ => Err(format!("Unsupported host {} for pull request status (GitHub and GitLab are supported).", repo.host.name())),
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

async fn find_gitlab_branch_mr(app: &AppHandle, host: &str, repo: &str, branch: &str) -> Result<PullRequestRef, String> {
    let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
    let token = gitlab::token(connectors.env.secrets.as_ref(), host)
        .ok_or_else(|| format!("No GitLab token is connected for {host} (Settings › Accounts & connections)."))?;
    let project: String = url::form_urlencoded::byte_serialize(repo.as_bytes()).collect();
    let source: String = url::form_urlencoded::byte_serialize(branch.as_bytes()).collect();
    let api_url = format!("https://{host}/api/v4/projects/{project}/merge_requests?source_branch={source}&per_page=10");
    let headers = [("PRIVATE-TOKEN", token)];
    let body = connectors.env.http.json("GET", &api_url, &headers, None, "GitLab").await.map_err(|e| e.message)?;
    let list = body.as_array().map(Vec::as_slice).unwrap_or(&[]);
    let picked = list.iter().find(|mr| mr["state"].as_str() == Some("opened")).or_else(|| list.first());
    let Some(mr) = picked else {
        return Err(format!("No merge request found on {host}/{repo} for branch \"{branch}\"."));
    };
    let number = mr["iid"].as_i64().ok_or("GitLab returned a merge request without an iid.")?;
    let web_url = mr["web_url"].as_str().map(str::to_string).unwrap_or_else(|| format!("https://{host}/{repo}/-/merge_requests/{number}"));
    Ok(PullRequestRef { host: PrHost::GitLab(host.to_string()), repo: repo.to_string(), number, url: web_url })
}

async fn fetch_snapshot(app: &AppHandle, reference: &PullRequestRef) -> Result<PullRequestSnapshot, String> {
    match &reference.host {
        PrHost::Github => fetch_github_snapshot(app, reference).await,
        PrHost::GitLab(host) => fetch_gitlab_snapshot(app, host, reference).await,
    }
}

async fn fetch_github_snapshot(app: &AppHandle, reference: &PullRequestRef) -> Result<PullRequestSnapshot, String> {
    let tokens = crate::workspace::github_tokens(app, &reference.repo);
    if tokens.is_empty() {
        return Err("No GitHub account is connected in Nook (Settings › Accounts & connections).".into());
    }
    let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
    let env = connectors.env.clone();
    let mut last_err = None;
    for token in tokens {
        match pulls::load_detail(&env, &token, &reference.repo, reference.number).await {
            Ok(detail) => return Ok(snapshot_from_github(detail, &reference.url)),
            Err(e) => last_err = Some(e.message),
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

async fn fetch_gitlab_snapshot(app: &AppHandle, host: &str, reference: &PullRequestRef) -> Result<PullRequestSnapshot, String> {
    let connectors = app.try_state::<Connectors>().ok_or("Connectors are not ready.")?;
    let token = gitlab::token(connectors.env.secrets.as_ref(), host)
        .ok_or_else(|| format!("No GitLab token is connected for {host} (Settings › Accounts & connections)."))?;
    let project: String = url::form_urlencoded::byte_serialize(reference.repo.as_bytes()).collect();
    let base = format!("https://{host}/api/v4/projects/{project}/merge_requests/{}", reference.number);
    let headers = [("PRIVATE-TOKEN", token)];
    let mr = connectors.env.http.json("GET", &base, &headers, None, "GitLab").await.map_err(|e| e.message)?;
    let notes =
        connectors.env.http.json("GET", &format!("{base}/notes?per_page=50"), &headers, None, "GitLab").await.unwrap_or(Value::Null);

    let draft = mr["draft"].as_bool().or_else(|| mr["work_in_progress"].as_bool()).unwrap_or(false);
    let state = match mr["state"].as_str().unwrap_or("opened") {
        "merged" => "merged",
        "closed" => "closed",
        _ if draft => "draft",
        _ => "open",
    }
    .to_string();
    let conflicted = mr["has_conflicts"].as_bool().unwrap_or(false);
    let merge_state = mr["detailed_merge_status"].as_str().or_else(|| mr["merge_status"].as_str()).unwrap_or("unknown").to_string();

    let mut checks = Vec::new();
    if let Some(pipeline) = mr.get("head_pipeline").filter(|v| v.is_object()) {
        let p_status = pipeline["status"].as_str().unwrap_or("unknown");
        let outcome = match p_status {
            "success" => "passing",
            "failed" | "canceled" => "failing",
            "skipped" => "skipped",
            _ => "pending",
        };
        checks.push(PrCheckSummary { name: "GitLab pipeline".into(), outcome: outcome.into(), detail: p_status.into() });
    }

    let mut comment_ids = Vec::new();
    if let Some(arr) = notes.as_array() {
        for note in arr {
            if note["system"].as_bool().unwrap_or(false) {
                continue;
            }
            if let Some(id) = note["id"].as_i64() {
                comment_ids.push(format!("gl-note-{id}"));
            }
        }
    }

    Ok(PullRequestSnapshot {
        repo: reference.repo.clone(),
        number: reference.number,
        title: mr["title"].as_str().unwrap_or("Untitled").to_string(),
        url: mr["web_url"].as_str().map(str::to_string).unwrap_or_else(|| reference.url.clone()),
        state,
        head_branch: mr["source_branch"].as_str().unwrap_or("").to_string(),
        base_branch: mr["target_branch"].as_str().unwrap_or("").to_string(),
        head_sha: mr["sha"].as_str().unwrap_or("").to_string(),
        conflicted,
        merge_state,
        checks,
        reviews: vec![],
        comment_ids,
    })
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
        loop {
            tokio::time::sleep(Duration::from_secs(WATCH_POLL_SECONDS)).await;
            let Some(ws) = workspace(&app_bg) else { break };
            let Some(run) = ws.manager.run(run_id) else { break };
            if run.archived {
                break;
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
                        ws.manager.note(run_id, &format!("PR {}#{}: {}", next.repo, next.number, diffs.join(" · ")));
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
