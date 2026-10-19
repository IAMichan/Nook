//! Commando's voor de werkruimte: sessies die Nook draait (starten, berichten, wachtrij, stoppen, hervatten), git
//! (wijzigingen, diff, commit, push, worktrees) en gebruik. Elke actie gebeurt pas na een klik in de interface.

use std::sync::Arc;

use chrono::{DateTime, Utc};
use nook_core::agents::AgentKind;
use nook_core::workspace::git::{self, FileChange, TreeRow};
use nook_core::workspace::manager::{GitSnapshot, Manager, ProjectInfo, WorktreeRow};
use nook_core::workspace::models::{
    EventKind, ExecutionMode, NewRunConfig, PermissionPolicy, ProviderCapabilities, RunEvent, RunProvider, WorkspaceRun,
};
use nook_core::workspace::queue::MessageQueue;
use nook_core::workspace::settings::WorkspaceSettings;
use nook_core::workspace::store::{UsageFilter, UsageReport};
use serde::Serialize;
use tauri::{Emitter, State};
use uuid::Uuid;

use crate::agents::lock;
use crate::workspace::WorkspaceState;

type Res<T> = Result<T, String>;

fn id(text: &str) -> Res<Uuid> {
    Uuid::parse_str(text.strip_prefix("run:").unwrap_or(text)).map_err(|_| "Deze sessie bestaat niet meer.".to_string())
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Res<T> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    provider: RunProvider,
    name: &'static str,
    capabilities: ProviderCapabilities,
    /// Waar de agent staat; `None`: niet gevonden.
    executable: Option<String>,
    /// Kan Nook deze agent hier zelf aansturen?
    supported: bool,
    install_command: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    runs: Vec<WorkspaceRun>,
    running: Vec<Uuid>,
    git_available: bool,
    providers: Vec<ProviderInfo>,
    settings: WorkspaceSettings,
}

/// Sessies, welke er lopen, welke agents er zijn en de voorkeuren.
#[tauri::command]
pub fn workspace_overview(state: State<'_, WorkspaceState>) -> Overview {
    let m = &state.manager;
    let runs = m.runs();
    let running = runs.iter().filter(|r| m.is_running(r.id)).map(|r| r.id).collect();
    let desktop = crate::platform::capabilities().local_agents;
    let providers = RunProvider::ALL
        .iter()
        .map(|&p| {
            let kind: AgentKind = p.kind();
            ProviderInfo {
                provider: p,
                name: p.display_name(),
                capabilities: p.capabilities(),
                executable: if desktop { nook_core::agents::find_executable(kind).map(|e| e.to_string_lossy().into_owned()) } else { None },
                supported: desktop && (!p.uses_acp() || p == RunProvider::Gemini),
                install_command: kind.install_command(),
            }
        })
        .collect();
    Overview { runs, running, git_available: m.git_available(), providers, settings: lock(&state.settings).clone() }
}

#[tauri::command]
pub fn workspace_save_settings(app: tauri::AppHandle, state: State<'_, WorkspaceState>, settings: WorkspaceSettings) {
    settings.save_to(&WorkspaceSettings::file());
    *lock(&state.settings) = settings;
    let _ = app.emit("workspace-changed", ());
}

#[tauri::command]
pub fn workspace_forget_project(state: State<'_, WorkspaceState>, path: String) {
    let mut s = lock(&state.settings);
    s.forget_project(&path);
    s.save_to(&WorkspaceSettings::file());
}

#[tauri::command]
pub fn workspace_timeline(state: State<'_, WorkspaceState>, run: String) -> Res<Vec<RunEvent>> {
    Ok(state.manager.timeline(id(&run)?))
}

#[tauri::command]
pub fn workspace_queue(state: State<'_, WorkspaceState>, run: String) -> Res<MessageQueue> {
    Ok(state.manager.queue(id(&run)?))
}

/// Wat "Nieuwe sessie" van een map moet weten (git, branches, of de map mag).
#[tauri::command]
pub async fn workspace_inspect(state: State<'_, WorkspaceState>, path: String) -> Res<ProjectInfo> {
    let m = state.manager.clone();
    blocking(move || m.inspect_project(&path)).await
}

/// Start een nieuwe sessie. `allowShared`: je bevestigde dat er al een sessie in deze map werkt.
#[tauri::command]
pub async fn workspace_start(state: State<'_, WorkspaceState>, config: NewRunConfig, allow_shared: bool) -> Res<String> {
    {
        let mut s = lock(&state.settings);
        s.remember_project(&config.project_path);
        s.save_to(&WorkspaceSettings::file());
    }
    let m = state.manager.clone();
    blocking(move || m.start(config, allow_shared)).await?.map(|id| id.to_string())
}

/// Neemt een gesprek over dat buiten Nook begon. `fork`: de eerste beurt wordt een kopie (Claude Code).
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub fn workspace_adopt(
    state: State<'_, WorkspaceState>,
    provider: RunProvider,
    session_id: String,
    profile_id: String,
    directory: String,
    title: String,
    history: Vec<(EventKind, String)>,
    fork: bool,
) -> Res<String> {
    state.manager.adopt(provider, &session_id, &profile_id, &directory, &title, history, fork).map(|id| id.to_string())
}

#[tauri::command]
pub fn workspace_configure(
    state: State<'_, WorkspaceState>,
    run: String,
    mode: Option<ExecutionMode>,
    permission: Option<PermissionPolicy>,
    model: Option<String>,
    effort: Option<String>,
    set_effort: bool,
) -> Res<()> {
    state.manager.configure(id(&run)?, mode, permission, model, set_effort.then_some(effort));
    Ok(())
}

/// Een bericht: start een nieuwe beurt, of komt in de wachtrij als de agent nog werkt.
#[tauri::command]
pub fn workspace_send(state: State<'_, WorkspaceState>, run: String, text: String) -> Res<()> {
    state.manager.send(id(&run)?, &text)
}

/// Stuurt de lopende beurt bij (Claude Code); kan dat niet, dan komt het bericht in de wachtrij.
#[tauri::command]
pub fn workspace_steer(state: State<'_, WorkspaceState>, run: String, text: String) -> Res<bool> {
    let run = id(&run)?;
    if state.manager.steer(run, &text) {
        return Ok(true);
    }
    state.manager.enqueue(run, &text);
    Ok(false)
}

#[tauri::command]
pub fn workspace_enqueue(state: State<'_, WorkspaceState>, run: String, text: String) -> Res<()> {
    state.manager.enqueue(id(&run)?, &text);
    Ok(())
}

#[tauri::command]
pub fn workspace_queue_remove(state: State<'_, WorkspaceState>, run: String, message: Uuid) -> Res<()> {
    state.manager.remove_queued(id(&run)?, message);
    Ok(())
}

#[tauri::command]
pub fn workspace_queue_move(state: State<'_, WorkspaceState>, run: String, message: Uuid, to_index: i64) -> Res<()> {
    state.manager.move_queued(id(&run)?, message, to_index);
    Ok(())
}

#[tauri::command]
pub fn workspace_queue_edit(state: State<'_, WorkspaceState>, run: String, message: Uuid, text: String) -> Res<()> {
    state.manager.edit_queued(id(&run)?, message, &text);
    Ok(())
}

/// Zet een stilstaande wachtrij weer aan en stuurt het volgende bericht.
#[tauri::command]
pub fn workspace_queue_send_now(state: State<'_, WorkspaceState>, run: String) -> Res<()> {
    state.manager.send_queued_now(id(&run)?);
    Ok(())
}

#[tauri::command]
pub fn workspace_queue_steer(state: State<'_, WorkspaceState>, run: String, message: Uuid) -> Res<()> {
    state.manager.steer_queued(id(&run)?, message);
    Ok(())
}

#[tauri::command]
pub fn workspace_stop(state: State<'_, WorkspaceState>, run: String) -> Res<()> {
    state.manager.stop(id(&run)?);
    Ok(())
}

#[tauri::command]
pub fn workspace_retry(state: State<'_, WorkspaceState>, run: String) -> Res<()> {
    state.manager.retry(id(&run)?)
}

#[tauri::command]
pub fn workspace_rename(state: State<'_, WorkspaceState>, run: String, title: String) -> Res<()> {
    state.manager.rename(id(&run)?, &title);
    Ok(())
}

#[tauri::command]
pub fn workspace_archive(state: State<'_, WorkspaceState>, run: String, archived: bool) -> Res<()> {
    state.manager.set_archived(id(&run)?, archived);
    Ok(())
}

#[tauri::command]
pub fn workspace_mark_reviewed(state: State<'_, WorkspaceState>, run: String) -> Res<()> {
    state.manager.mark_reviewed(id(&run)?);
    Ok(())
}

/// Haalt een sessie weg (niet terwijl hij loopt). De worktree blijft staan; die haal je apart weg.
#[tauri::command]
pub fn workspace_delete(state: State<'_, WorkspaceState>, run: String) -> Res<()> {
    state.manager.delete(id(&run)?)
}

#[tauri::command]
pub fn workspace_usage(state: State<'_, WorkspaceState>, filter: UsageFilter) -> UsageReport {
    state.manager.usage_report(&filter)
}

// MARK: Git

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitView {
    snapshot: Option<GitSnapshot>,
    tree: Vec<TreeRow>,
}

/// De laatst bekende git-stand van een sessie; `refresh` leest hem opnieuw (het antwoord komt als `workspace-changed`).
#[tauri::command]
pub fn workspace_git(state: State<'_, WorkspaceState>, run: String, refresh: bool) -> Res<GitView> {
    let run = id(&run)?;
    if refresh {
        state.manager.refresh_git(run);
    }
    let snapshot = state.manager.git_snapshot(run);
    let tree = snapshot.as_ref().and_then(|s| s.status.as_ref()).map(|s| git::changed_files_tree(&s.files)).unwrap_or_default();
    Ok(GitView { snapshot, tree })
}

#[tauri::command]
pub async fn workspace_diff(state: State<'_, WorkspaceState>, run: String, file: FileChange) -> Res<String> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.diff(run, &file)).await?
}

#[tauri::command]
pub async fn workspace_commit(state: State<'_, WorkspaceState>, run: String, message: String, paths: Vec<String>) -> Res<String> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.commit(run, &message, &paths)).await?
}

#[tauri::command]
pub async fn workspace_push(state: State<'_, WorkspaceState>, run: String) -> Res<String> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.push(run)).await?
}

#[tauri::command]
pub fn workspace_can_revert(state: State<'_, WorkspaceState>, run: String, before: DateTime<Utc>) -> Res<bool> {
    Ok(state.manager.can_revert(id(&run)?, before))
}

/// Zet de bestanden terug naar hoe ze waren voor dit bericht (na jouw bevestiging in de interface).
#[tauri::command]
pub async fn workspace_revert(state: State<'_, WorkspaceState>, run: String, before: DateTime<Utc>) -> Res<()> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.revert_files(run, before)).await?
}

#[tauri::command]
pub async fn workspace_worktrees(state: State<'_, WorkspaceState>, refresh: bool) -> Res<Vec<WorktreeRow>> {
    let m: Arc<Manager> = state.manager.clone();
    if refresh {
        let m2 = m.clone();
        blocking(move || m2.refresh_worktrees()).await?;
    }
    Ok(m.worktree_rows())
}

/// Haalt een worktree weg (na bevestiging). Weigert zolang er een sessie in loopt.
#[tauri::command]
pub async fn workspace_remove_worktree(state: State<'_, WorkspaceState>, repo: String, path: String, force: bool) -> Res<()> {
    let m = state.manager.clone();
    blocking(move || m.remove_worktree_at(&repo, &path, force)).await?
}
