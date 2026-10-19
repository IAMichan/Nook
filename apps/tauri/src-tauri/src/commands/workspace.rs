//! Commando's voor de werkruimte: sessies die Nook draait (starten, berichten, wachtrij, stoppen, hervatten), git
//! (wijzigingen, diff, commit, push, worktrees) en gebruik. Elke actie gebeurt pas na een klik in de interface.

use std::sync::Arc;

use chrono::{DateTime, Utc};
use nook_core::agents::models::AgentStatus;
use nook_core::agents::transcript::{self, ChatKind};
use nook_core::agents::{scanner, AgentKind};
use nook_core::workspace::git::{self, FileChange, TreeRow};
use nook_core::workspace::manager::{GitSnapshot, Manager, ProjectInfo, WorktreeRow};
use nook_core::workspace::models::{
    EventKind, ExecutionMode, IsolationMode, NewRunConfig, PermissionPolicy, ProviderCapabilities, RunEvent, RunProvider, WorkspaceRun,
};
use nook_core::workspace::queue::MessageQueue;
use nook_core::workspace::settings::WorkspaceSettings;
use nook_core::workspace::source_control::{self, QuickAction, QuickState, RemoteRepository, SourceControlHost};
use nook_core::workspace::store::{UsageFilter, UsageReport};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager as _, State};
use uuid::Uuid;

use crate::agents::{lock, AgentsState};
use crate::state::AppState;
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
pub async fn workspace_start(state: State<'_, WorkspaceState>, mut config: NewRunConfig, allow_shared: bool) -> Res<String> {
    // De branchnaam komt uit de opdracht, pas op het moment van starten.
    if config.isolation == IsolationMode::Worktree && config.branch_name.trim().is_empty() {
        config.branch_name = nook_core::workspace::models::branch_name(&config.task, Uuid::new_v4());
    }
    // In Plan-modus leest de agent alleen; de veiligste rechten gaan mee voor als je later verdergaat.
    if config.mode == ExecutionMode::Plan {
        config.permission = config.provider.capabilities().policies.first().copied().unwrap_or_default();
    }
    let m = state.manager.clone();
    let chosen = config.clone();
    let id = blocking(move || m.start(config, allow_shared)).await??;
    let mut s = lock(&state.settings);
    s.remember_project(&chosen.project_path);
    s.default_provider = chosen.provider;
    s.default_models.insert(chosen.provider.id().into(), chosen.model.clone());
    s.default_mode = chosen.mode;
    s.default_isolation = chosen.isolation;
    s.default_permission = chosen.permission;
    s.save_to(&WorkspaceSettings::file());
    Ok(id.to_string())
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

/// "Hervat bij reset" aan of uit voor een sessie die op een gebruikslimiet stopte.
#[tauri::command]
pub fn workspace_set_auto_resume(state: State<'_, WorkspaceState>, run: String, on: bool) -> Res<()> {
    state.manager.set_auto_resume(id(&run)?, on);
    Ok(())
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

/// Kloont een repository naast het gekozen project (of in `~/Developer`). Pas na jouw klik op Kloon.
#[tauri::command]
pub async fn workspace_clone(state: State<'_, WorkspaceState>, url: String, near: Option<String>) -> Res<String> {
    if !git::is_clone_url(&url) {
        return Err("Dat is geen adres van een repository.".into());
    }
    let m = state.manager.clone();
    blocking(move || {
        let git = m.git().ok_or("Git is niet gevonden.")?;
        let parent = near
            .and_then(|p| std::path::Path::new(&p).parent().map(|p| p.to_string_lossy().into_owned()))
            .unwrap_or_else(|| nook_core::agents::home_dir().join("Developer").to_string_lossy().into_owned());
        std::fs::create_dir_all(&parent).map_err(|e| e.to_string())?;
        git.clone(&url, &parent).map_err(|e| e.0)
    })
    .await?
}

// MARK: De git-knop en pull requests

/// De GitHub-tokens uit de kluis (het hoofdaccount van de koppeling GitHub). Nooit uit een bestand.
fn github_tokens(app: &AppHandle) -> Vec<String> {
    let secrets = app.state::<AppState>().secrets.clone();
    ["connector.github.token"].iter().filter_map(|k| secrets.read(k)).map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).collect()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickView {
    state: QuickState,
    action: Option<QuickAction>,
    label: Option<&'static str>,
    reason: Option<&'static str>,
    repository: Option<RemoteRepository>,
    host_name: Option<String>,
    remote: Option<String>,
    base: Option<String>,
    pull_request: Option<String>,
    can_create_here: bool,
}

/// Wat de git-knop van een sessie nu zou doen, en waarom niet als er niets te doen is.
#[tauri::command]
pub async fn workspace_quick(app: AppHandle, run: String) -> Res<QuickView> {
    let id = id(&run)?;
    let ws = app.state::<WorkspaceState>();
    let m = ws.manager.clone();
    let run = m.run(id).ok_or("Deze sessie bestaat niet meer.")?;
    let (mut state, repository, remote, base) = blocking(move || {
        let git = m.git()?;
        let dir = run.working_directory.clone();
        let status = git.status(&dir).ok()?;
        let remotes = git.remotes(&dir);
        let remote = if remotes.iter().any(|r| r == "origin") { Some("origin".to_string()) } else { remotes.first().cloned() };
        let repository = remote.as_deref().and_then(|r| git.remote_url(&dir, r)).and_then(|u| RemoteRepository::detect(&u));
        let base = remote
            .as_deref()
            .and_then(|r| git.default_branch(&dir, r))
            .or_else(|| run.base_branch.clone().map(|b| b.trim_start_matches("origin/").to_string()));
        let compare = base.as_deref().map(|b| git.comparison_base(&dir, b, remote.as_deref().unwrap_or("origin")));
        let state = QuickState {
            has_changes: !status.files.is_empty(),
            is_default_branch: status.branch.is_some() && status.branch == base,
            branch: status.branch.clone(),
            has_upstream: status.upstream.is_some(),
            has_remote: remote.is_some(),
            ahead: status.ahead,
            behind: status.behind,
            ahead_of_base: compare.and_then(|c| git.commits_ahead(&dir, &c)).unwrap_or(0),
            has_open_pull_request: false,
        };
        Some((state, repository, remote, base))
    })
    .await?
    .ok_or("Git kon de stand van deze map niet lezen.")?;
    let tokens = github_tokens(&app);
    let mut pull_request = None;
    if let (Some(repo), Some(branch)) = (&repository, &state.branch) {
        if repo.host == SourceControlHost::Github && !tokens.is_empty() {
            pull_request = source_control::open_github_pull_request(&tokens, &repo.display_name(), branch).await;
        }
    }
    state.has_open_pull_request = pull_request.is_some();
    let resolved = source_control::resolve(&state);
    let can_create_here = repository.as_ref().is_some_and(|r| r.host == SourceControlHost::Github) && !tokens.is_empty();
    Ok(QuickView {
        action: resolved.ok(),
        label: resolved.ok().map(QuickAction::label),
        reason: resolved.err().map(|r| r.message()),
        host_name: repository.as_ref().map(|r| r.host.name()),
        state,
        repository,
        remote,
        base,
        pull_request,
        can_create_here,
    })
}

#[tauri::command]
pub async fn workspace_pull(state: State<'_, WorkspaceState>, run: String) -> Res<()> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.pull(run)).await?
}

/// Commit alles (git add -A) met onderwerp en tekst. Pas na jouw klik op Commit.
#[tauri::command]
pub async fn workspace_commit_all(state: State<'_, WorkspaceState>, run: String, subject: String, body: String) -> Res<String> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || {
        let r = m.run(run).ok_or("Deze sessie bestaat niet meer.")?;
        if r.status.is_active() {
            return Err("Kan niet terwijl de agent werkt.".to_string());
        }
        let git = m.git().ok_or("Git is niet gevonden.")?;
        let sha = git.commit_all(&r.working_directory, subject.trim(), &body).map_err(|e| e.0)?;
        m.note(run, &format!("Commit {sha}: {}", subject.trim()));
        m.mark_reviewed(run);
        m.refresh_git(run);
        Ok(sha)
    })
    .await?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestDraft {
    title: String,
    body: String,
    head: String,
    base: String,
}

/// Wat het formulier voor een pull request vooraf invult: de naam van de sessie, de opdracht, of de sjabloon van de repo.
#[tauri::command]
pub async fn workspace_pull_request_draft(state: State<'_, WorkspaceState>, run: String, base: String) -> Res<PullRequestDraft> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || {
        let r = m.run(run).ok_or("Deze sessie bestaat niet meer.")?;
        let git = m.git().ok_or("Git is niet gevonden.")?;
        let head = git.current_branch(&r.working_directory).ok_or("Er is geen branch uitgecheckt.")?;
        let root = r.repo_root.clone().unwrap_or_else(|| r.working_directory.clone());
        let body = source_control::pull_request_template(&root)
            .unwrap_or_else(|| format!("Gemaakt met een agent in Nook.\n\nOpdracht:\n{}", r.task.trim()));
        Ok::<_, String>(PullRequestDraft { title: r.title.clone(), body, head, base })
    })
    .await?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestResult {
    url: String,
    /// `true`: Nook maakte hem zelf (GitHub-koppeling); `false`: open deze pagina om hem af te maken.
    created: bool,
}

/// Maakt de pull request: via je GitHub-koppeling als die er is, anders de pagina van de host met alles ingevuld.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn workspace_create_pull_request(
    app: AppHandle,
    run: String,
    title: String,
    body: String,
    base: String,
    head: String,
    draft: bool,
) -> Res<PullRequestResult> {
    let run = id(&run)?;
    let ws = app.state::<WorkspaceState>();
    let m = ws.manager.clone();
    let r = m.run(run).ok_or("Deze sessie bestaat niet meer.")?;
    let dir = r.working_directory.clone();
    let m2 = m.clone();
    let repository = blocking(move || {
        let git = m2.git()?;
        let remotes = git.remotes(&dir);
        let remote = if remotes.iter().any(|r| r == "origin") { "origin".to_string() } else { remotes.first()?.clone() };
        git.remote_url(&dir, &remote).and_then(|u| RemoteRepository::detect(&u))
    })
    .await?
    .ok_or("Deze repository heeft geen remote die Nook herkent. Push de branch en open de pull request bij je eigen host.")?;
    let tokens = github_tokens(&app);
    if repository.host == SourceControlHost::Github && !tokens.is_empty() {
        let url =
            source_control::create_github_pull_request(&tokens, &repository.display_name(), &title, &body, &head, &base, draft).await?;
        m.note(run, &format!("Pull request geopend: {url}"));
        return Ok(PullRequestResult { url, created: true });
    }
    let url = repository
        .new_pull_request_url(&base, &head, Some(&title), Some(&body), draft)
        .ok_or("Deze repository heeft geen remote die Nook herkent. Push de branch en open de pull request bij je eigen host.")?;
    m.note(run, &format!("{head} gepusht; {} geopend om de pull request af te maken", repository.host.name()));
    Ok(PullRequestResult { url, created: false })
}

// MARK: Verdergaan in Nook

fn nook_provider(kind: AgentKind) -> Res<RunProvider> {
    match kind {
        AgentKind::Claude => Ok(RunProvider::Claude),
        AgentKind::Codex => Ok(RunProvider::Codex),
        AgentKind::Gemini => Ok(RunProvider::Gemini),
        other => Err(format!("Nook kan {} nog niet zelf aansturen. Claude Code, Codex en Gemini CLI wel.", other.name())),
    }
}

/// Het gesprek tot nu toe voor een sessie die Nook overneemt: het hele transcript met het denken van de agent, of, als
/// dat niet te lezen is, de laatste opdracht en het laatste antwoord.
fn earlier_conversation(path: &str, prompt: &str, reply: &str) -> Vec<(EventKind, String)> {
    let messages = if path.is_empty() { vec![] } else { transcript::recent(path, transcript::FULL_LIMIT) };
    if !messages.is_empty() {
        return messages
            .into_iter()
            .map(|m| {
                let kind = match m.kind {
                    ChatKind::User => EventKind::User,
                    ChatKind::Assistant => EventKind::Assistant,
                    ChatKind::Thinking => EventKind::Thinking,
                };
                (kind, m.text)
            })
            .collect();
    }
    let mut earlier = vec![];
    if !prompt.is_empty() {
        earlier.push((EventKind::User, prompt.to_string()));
    }
    if !reply.is_empty() {
        earlier.push((EventKind::Assistant, reply.to_string()));
    }
    earlier
}

/// Gaat verder in Nook met een sessie die in een terminal draait (of draaide). Standaard blijft de terminal met rust:
/// een Claude Code-sessie die nog loopt, gaat verder in een kopie (`--fork-session`). `ending_terminal`: alleen als je
/// dat expliciet kiest, eerst het oorspronkelijke proces beëindigen en hetzelfde gesprek hier voortzetten.
#[tauri::command]
pub async fn workspace_continue_live(app: AppHandle, session_id: String, message: Option<String>, ending_terminal: bool) -> Res<String> {
    let agents_state = app.state::<AgentsState>();
    let session = agents_state
        .hub
        .sessions()
        .into_iter()
        .chain(agents_state.hub.detected())
        .find(|s| s.id == session_id)
        .ok_or("Deze sessie bestaat niet meer.")?;
    let kind = AgentKind::from_agent_name(&session.name).ok_or_else(|| format!("Nook kan {} nog niet zelf aansturen.", session.name))?;
    let provider = nook_provider(kind)?;
    let history = lock(&agents_state.last_history).clone();
    let conversation = if !session.session_id.is_empty() {
        session.session_id.clone()
    } else {
        history
            .sessions
            .iter()
            .find(|p| p.agent == kind && !session.transcript_path.is_empty() && p.path == session.transcript_path)
            .map(|p| p.session_id.clone())
            .ok_or("Ik vind het gesprek van deze sessie niet, dus ik kan hem niet voortzetten.")?
    };
    let busy = !session.is_detected() && matches!(session.status, AgentStatus::Running | AgentStatus::Waiting);
    let mut fork = false;
    if ending_terminal {
        let pid = agents_state.hub.process_id(&session.id).ok_or_else(|| format!("Ik vind het proces van {} niet meer.", session.name))?;
        if !scanner::terminate(pid) {
            return Err(format!("Ik kon {} niet beëindigen. Draait hij nog?", session.name));
        }
        agents_state.hub.forget(&session.id);
        // De agent even de tijd geven om het laatste van zijn gesprek weg te schrijven.
        tokio::time::sleep(std::time::Duration::from_millis(1_200)).await;
    } else if busy || session.is_detected() {
        // Twee processen mogen niet in één gesprek schrijven: ga verder in een kopie.
        if provider != RunProvider::Claude {
            return Err(format!(
                "{} draait nog in een terminal. Kies Neem over in Nook (dat sluit de terminal af), of wacht tot hij klaar is.",
                session.name
            ));
        }
        fork = true;
    }
    let profile = {
        let profiles = lock(&agents_state.profiles);
        profiles.profile_for_home(kind, &session.home).unwrap_or_else(|| profiles.preferred(kind))
    };
    let path = if session.transcript_path.is_empty() {
        history.sessions.iter().find(|p| p.session_id == conversation).map(|p| p.path.clone()).unwrap_or_default()
    } else {
        session.transcript_path.clone()
    };
    let (prompt, reply) = (session.last_prompt.clone(), session.last_reply.clone());
    let earlier = blocking(move || earlier_conversation(&path, &prompt, &reply)).await?;
    let title = if session.last_prompt.is_empty() { session.project.clone() } else { session.last_prompt.clone() };
    let ws = app.state::<WorkspaceState>();
    let id = ws.manager.adopt(provider, &conversation, &profile.id, &session.cwd, &title, earlier, fork)?;
    if let Some(text) = message.filter(|m| !m.trim().is_empty()) {
        ws.manager.send(id, &text)?;
    }
    Ok(id.to_string())
}

/// Zet een eerdere sessie voort in Nook, eventueel met een eerste bericht.
#[tauri::command]
pub async fn workspace_continue_past(app: AppHandle, key: String, message: Option<String>) -> Res<String> {
    let agents_state = app.state::<AgentsState>();
    let past = lock(&agents_state.last_history).sessions.iter().find(|p| p.id() == key).cloned().ok_or("Deze sessie bestaat niet meer.")?;
    let provider = nook_provider(past.agent)?;
    let folder = past.resume_folder();
    if folder.is_empty() {
        return Err("Deze sessie heeft geen map, dus Nook kan hem niet voortzetten.".into());
    }
    if !std::path::Path::new(&folder).is_dir() {
        return Err(format!("De map van deze sessie bestaat niet meer: {folder}"));
    }
    let profile = {
        let profiles = lock(&agents_state.profiles);
        profiles.profile(&past.profile_id).unwrap_or_else(|| profiles.preferred(past.agent))
    };
    let (path, prompt, reply) = (past.path.clone(), past.last_prompt.clone(), past.last_reply.clone());
    let earlier = blocking(move || earlier_conversation(&path, &prompt, &reply)).await?;
    let ws = app.state::<WorkspaceState>();
    let id = ws.manager.adopt(provider, &past.session_id, &profile.id, &folder, &past.title, earlier, false)?;
    if let Some(text) = message.filter(|m| !m.trim().is_empty()) {
        ws.manager.send(id, &text)?;
    }
    Ok(id.to_string())
}
