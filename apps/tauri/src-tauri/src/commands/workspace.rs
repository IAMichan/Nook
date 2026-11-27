//! Commando's voor de werkruimte: sessies die Nook draait (starten, berichten, wachtrij, stoppen, hervatten), git
//! (wijzigingen, diff, commit, push, worktrees) en gebruik. Elke actie gebeurt pas na een klik in de interface.

use std::sync::Arc;

use chrono::{DateTime, Utc};
use nook_core::agents::models::AgentStatus;
use nook_core::agents::transcript::{self, ChatKind};
use nook_core::agents::{scanner, AgentKind};
use nook_core::i18n::{tr, trf};
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
use crate::workspace::WorkspaceState;

type Res<T> = Result<T, String>;

fn id(text: &str) -> Res<Uuid> {
    Uuid::parse_str(text.strip_prefix("run:").unwrap_or(text))
        .map_err(|_| tr("Deze sessie bestaat niet meer.", "This session no longer exists.").to_string())
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
    worktree_setups: std::collections::HashMap<Uuid, nook_core::workspace::worktree_setup::WorktreeSetupProgress>,
}

/// Connects `Manager` to Nook's live OpenTelemetry settings and keychain headers (AG-33 / SV-05).
fn ensure_telemetry_provider(app: &AppHandle, manager: &Arc<Manager>) {
    if manager.has_telemetry_provider() {
        return;
    }
    let handle = app.clone();
    manager.set_telemetry_provider(move || {
        use nook_core::services::telemetry::{OtlpConfig, HEADERS_SECRET_ACCOUNT};
        let state = handle.state::<crate::state::AppState>();
        let saved = state.settings().telemetry;
        let saved_headers = state.secrets.read(HEADERS_SECRET_ACCOUNT).unwrap_or_default();
        OtlpConfig::resolve_process(&saved, &saved_headers)
    });
}

/// Sessies, welke er lopen, welke agents er zijn en de voorkeuren.
#[tauri::command(async)]
pub fn workspace_overview(app: AppHandle, state: State<'_, WorkspaceState>) -> Overview {
    let m = &state.manager;
    ensure_telemetry_provider(&app, m);
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
                executable: if desktop {
                    nook_core::workspace::driver::session_executable(
                        p,
                        nook_core::agents::find_executable(kind).map(|e| e.to_string_lossy().into_owned()),
                    )
                } else {
                    None
                },
                // Every agent runs here: Claude Code over its stream, Codex over app-server, the rest over ACP.
                supported: desktop,
                install_command: kind.install_command(),
            }
        })
        .collect();
    Overview {
        runs,
        running,
        git_available: m.git_available(),
        providers,
        settings: lock(&state.settings).clone(),
        worktree_setups: m.visible_setups(),
    }
}

#[tauri::command]
pub fn workspace_save_settings(app: tauri::AppHandle, state: State<'_, WorkspaceState>, mut settings: WorkspaceSettings) {
    let mut current = lock(&state.settings);
    settings.favorite_projects = current.favorite_projects.clone();
    settings.recent_projects = current.recent_projects.clone();
    settings.last_project = current.last_project.clone();
    // Per-project values have their own commands; a save from elsewhere never drops them.
    settings.project_overrides = current.project_overrides.clone();
    settings.save_to(&WorkspaceSettings::file());
    *current = settings;
    drop(current);
    // Raising or removing `max_working_sessions` lets waiting turns start immediately (AG-75).
    state.manager.start_waiting_turns();
    let _ = app.emit("workspace-changed", ());
}

/// What one project sets for itself and the values a new session there starts with (Settings › Projects; the
/// new-session screen reads `defaults` to fill in its choices).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSettingsView {
    pub path: String,
    #[serde(rename = "override")]
    pub own: nook_core::workspace::settings::ProjectOverride,
    pub defaults: nook_core::workspace::settings::ProjectDefaults,
}

#[tauri::command]
pub fn workspace_project_settings(app: AppHandle, state: State<'_, WorkspaceState>, path: String) -> ProjectSettingsView {
    let worktrees = app.state::<crate::state::AppState>().settings().worktrees;
    let s = lock(&state.settings);
    ProjectSettingsView { own: s.project(&path), defaults: s.defaults_for_with_worktrees(&path, &worktrees), path }
}

/// Saves what one project sets for itself; every field left empty follows the setting for all projects.
#[tauri::command]
pub fn workspace_set_project_settings(
    app: tauri::AppHandle,
    state: State<'_, WorkspaceState>,
    path: String,
    value: nook_core::workspace::settings::ProjectOverride,
) -> ProjectSettingsView {
    let worktrees = app.state::<crate::state::AppState>().settings().worktrees;
    let mut s = lock(&state.settings);
    s.set_project(&path, value);
    s.save_to(&WorkspaceSettings::file());
    let view = ProjectSettingsView { own: s.project(&path), defaults: s.defaults_for_with_worktrees(&path, &worktrees), path };
    drop(s);
    let _ = app.emit("workspace-changed", ());
    view
}

#[tauri::command]
pub fn workspace_forget_project(state: State<'_, WorkspaceState>, path: String) {
    let mut s = lock(&state.settings);
    s.forget_project(&path);
    s.save_to(&WorkspaceSettings::file());
}

#[tauri::command]
pub fn workspace_toggle_favorite_project(app: tauri::AppHandle, state: State<'_, WorkspaceState>, path: String) {
    let mut s = lock(&state.settings);
    s.toggle_favorite_project(&path);
    s.save_to(&WorkspaceSettings::file());
    drop(s);
    let _ = app.emit("workspace-changed", ());
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
pub async fn workspace_start(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    mut config: NewRunConfig,
    allow_shared: bool,
) -> Res<String> {
    // "Or start without a project": an empty folder of its own under ~/.nook/scratch, named after the task.
    let scratch = config.project_path.trim().is_empty();
    if scratch {
        config.project_path = nook_core::workspace::scratch::create(&config.task).map_err(|e| {
            trf("Nook kon er geen map voor maken: {error}", "Nook could not make a folder for it: {error}", &[("error", &e.to_string())])
        })?;
        config.isolation = IsolationMode::Folder;
        config.base_branch.clear();
    }
    // What the project sets for itself (Settings › Projects): its branch prefix, and the instructions for every agent,
    // which go before the session's own (`agentInstructions` on the Mac).
    let (project, commit_style, commit_instructions, no_agent_credits) = {
        let s = lock(&state.settings);
        (s.defaults_for(&config.project_path), s.commit_style, s.commit_instructions.clone(), s.no_agent_credits)
    };
    let every = project.agent_instructions.trim();
    if !every.is_empty() {
        let own = config.instructions.trim();
        config.instructions = if own.is_empty() { every.to_string() } else { format!("{every}\n\n{own}") };
    }
    let style_rules = commit_style.commit_rules(&[], &commit_instructions);
    if !style_rules.is_empty() {
        let block = format!("Commit style rules:\n{}", style_rules.join("\n"));
        let own = config.instructions.trim();
        config.instructions = if own.is_empty() { block } else { format!("{own}\n\n{block}") };
    }
    if no_agent_credits {
        config.instructions = nook_core::workspace::commit_style::launch_instructions(&config.instructions, None, true);
    }
    // De branchnaam komt uit de opdracht, pas op het moment van starten.
    if config.isolation == IsolationMode::Worktree && config.branch_name.trim().is_empty() {
        config.branch_name = nook_core::workspace::models::branch_name_with(&project.branch_prefix, &config.task, Uuid::new_v4());
    }
    let picked_permission = config.permission;
    // In Plan-modus leest de agent alleen; de veiligste rechten gaan mee voor als je later verdergaat.
    if config.mode == ExecutionMode::Plan {
        config.permission = config.provider.capabilities().policies.first().copied().unwrap_or_default();
    }
    let m = state.manager.clone();
    ensure_telemetry_provider(&app, &m);
    let chosen = config.clone();
    let id = blocking(move || m.start(config, allow_shared)).await??;
    crate::workspace::automation::title_new_session(&app, id, !chosen.title.trim().is_empty());
    let mut s = lock(&state.settings);
    // A folder without a project stays out of Recent until you turn it into a project.
    if !scratch {
        s.remember_project(&chosen.project_path);
    }
    s.default_provider = chosen.provider;
    s.default_models.insert(chosen.provider.id().into(), chosen.model.clone());
    s.default_profiles.insert(chosen.provider.id().into(), chosen.profile_id.clone());
    match chosen.effort.as_ref().filter(|e| !e.is_empty()) {
        Some(e) => s.default_efforts.insert(chosen.provider.id().into(), e.clone()),
        None => s.default_efforts.remove(chosen.provider.id()),
    };
    s.default_mode = chosen.mode;
    if !scratch {
        s.default_isolation = chosen.isolation;
    }
    s.default_permission = chosen.permission;
    if !scratch {
        s.remember_folder_choices(&chosen, picked_permission);
    }
    s.save_to(&WorkspaceSettings::file());
    Ok(id.to_string())
}

/// Sessions whose title or conversation holds `query`, archived ones too (search across sessions, #1498).
#[tauri::command]
pub async fn workspace_search(state: State<'_, WorkspaceState>, query: String) -> Res<Vec<nook_core::workspace::manager::SearchHit>> {
    let m = state.manager.clone();
    blocking(move || m.search(&query, 60)).await
}

/// Your saved prompts (`PromptLibrary`), newest edit first.
#[tauri::command]
pub fn workspace_prompts() -> Vec<nook_core::workspace::prompts::SavedPrompt> {
    nook_core::workspace::prompts::PromptLibrary::load(&nook_core::workspace::prompts::PromptLibrary::file()).prompts
}

/// Saves a prompt (new or edited); false when it has no title or words.
#[tauri::command]
pub fn workspace_save_prompt(prompt: nook_core::workspace::prompts::SavedPrompt) -> Res<bool> {
    use nook_core::workspace::prompts::PromptLibrary;
    let file = PromptLibrary::file();
    let mut lib = PromptLibrary::load(&file);
    let kept = lib.save(prompt);
    if kept {
        lib.save_to(&file).map_err(|e| e.to_string())?;
    }
    Ok(kept)
}

#[tauri::command]
pub fn workspace_delete_prompt(id: Uuid) -> Res<()> {
    use nook_core::workspace::prompts::PromptLibrary;
    let file = PromptLibrary::file();
    let mut lib = PromptLibrary::load(&file);
    lib.remove(id);
    lib.save_to(&file).map_err(|e| e.to_string())
}

/// When the model list in use was last edited (`ModelManifest.updatedAt`), as a date; Settings shows it.
#[tauri::command]
pub fn workspace_model_list_date() -> Option<String> {
    nook_core::workspace::model_manifest::updated_at().map(|d| d.format("%Y-%m-%d").to_string())
}

/// The models Nook offers each agent (`ModelManifest`), by agent id.
#[tauri::command]
pub fn workspace_models() -> std::collections::BTreeMap<String, Vec<nook_core::workspace::model_manifest::CatalogModel>> {
    nook_core::workspace::model_manifest::all(chrono::Utc::now())
}

/// The `@` list's files (`FileMentions`): the best matches of `query` in the project at `root`. The walk is kept a
/// minute per folder, so typing does not walk again.
#[tauri::command]
pub async fn workspace_files(root: String, query: String) -> Res<Vec<String>> {
    type Cache = std::collections::HashMap<String, (std::time::Instant, std::sync::Arc<Vec<String>>)>;
    static CACHE: std::sync::LazyLock<std::sync::Mutex<Cache>> = std::sync::LazyLock::new(Default::default);
    let cached = lock(&CACHE).get(&root).filter(|(at, _)| at.elapsed().as_secs() < 60).map(|(_, f)| f.clone());
    let files = match cached {
        Some(f) => f,
        None => {
            let dir = root.clone();
            let f = std::sync::Arc::new(blocking(move || nook_core::workspace::project_files::list(std::path::Path::new(&dir))).await?);
            lock(&CACHE).insert(root, (std::time::Instant::now(), f.clone()));
            f
        }
    };
    Ok(nook_core::workspace::project_files::search(&files, &query, 30))
}

/// A picture pasted, dropped or captured (PDF spot crop) into a composer, kept as a file the agent reads (`ImageAttachment` on the Mac).
#[tauri::command]
pub async fn workspace_save_picture(data: String, extension: String, name: Option<String>) -> Res<String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(data.split(',').next_back().unwrap_or("")).map_err(|e| e.to_string())?;
    if bytes.len() > 20 * 1024 * 1024 {
        return Err(tr("Deze afbeelding is te groot.", "This picture is too large.").into());
    }
    blocking(move || {
        nook_core::workspace::project_files::save_picture_named(&bytes, &extension, name.as_deref())
            .map(|p| p.to_string_lossy().into_owned())
            .map_err(|e| e.to_string())
    })
    .await?
}

/// A project's own icon (`ProjectFavicons`) as a picture the window can draw, or `None`; read once per folder.
#[tauri::command]
pub async fn workspace_favicon(path: String) -> Res<Option<String>> {
    static CACHE: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, Option<String>>>> =
        std::sync::LazyLock::new(Default::default);
    if let Some(hit) = lock(&CACHE).get(&path) {
        return Ok(hit.clone());
    }
    let key = path.clone();
    let found =
        blocking(move || nook_core::workspace::favicon::find(&path).and_then(|p| nook_core::workspace::favicon::data_url(&p))).await?;
    lock(&CACHE).insert(key, found.clone());
    Ok(found)
}

/// The skills a session's agent reads (`SkillIndex`), for the composer's `$` list; for the new-session composer, the
/// skills of `folder` for `provider`.
#[tauri::command]
pub async fn workspace_skills(
    state: State<'_, WorkspaceState>,
    run: Option<String>,
    folder: Option<String>,
    provider: Option<RunProvider>,
) -> Res<Vec<nook_core::workspace::skills::Skill>> {
    use nook_core::workspace::skills;
    let (working, project, provider) = match run {
        Some(run) => {
            let r = state.manager.run(id(&run)?).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
            (r.working_directory, r.project_path, r.provider)
        }
        None => (folder.clone().unwrap_or_default(), folder.unwrap_or_default(), provider.unwrap_or(RunProvider::Claude)),
    };
    blocking(move || {
        let home = dirs::home_dir().unwrap_or_default();
        let project = skills::project_folder(&working, &project);
        skills::scan(&skills::roots(provider, &home, project.as_deref()))
    })
    .await
}

/// A new session that starts from this one (`fork`); `keep`: how many timeline entries stay, for a fork from an earlier
/// point. Returns the new session's id.
#[tauri::command]
pub fn workspace_fork(state: State<'_, WorkspaceState>, run: String, keep: Option<usize>) -> Res<String> {
    Ok(state.manager.fork(id(&run)?, keep)?.to_string())
}

/// The `/` commands a session's agent announced itself, for the composer's `/` list.
#[tauri::command]
pub fn workspace_agent_commands(state: State<'_, WorkspaceState>, run: String) -> Res<Vec<nook_core::workspace::driver::SlashCommand>> {
    Ok(state.manager.agent_commands(id(&run)?))
}

/// The CPU and memory of a working session's agent and everything it started (`ResourceUsageBadge`); `None` while
/// it has no process, and on the first reading.
#[tauri::command]
pub async fn workspace_resources(
    state: State<'_, WorkspaceState>,
    run: String,
) -> Res<Option<nook_core::workspace::resources::ResourceUsage>> {
    static METERS: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<Uuid, nook_core::workspace::resources::Meter>>> =
        std::sync::LazyLock::new(Default::default);
    let id = id(&run)?;
    let Some(pid) = state.manager.agent_pid(id) else {
        lock(&METERS).remove(&id);
        return Ok(None);
    };
    blocking(move || lock(&METERS).entry(id).or_default().measure(&[pid])).await
}

/// Antigravity's ACP server (`AntigravitySetupRow`): whether this computer has a release, whether it is installed,
/// its version and the download's size.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AntigravitySetup {
    supported: bool,
    installed: bool,
    busy: bool,
    version: &'static str,
    download_bytes: u64,
}

static ANTIGRAVITY_BUSY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[tauri::command]
pub fn antigravity_setup() -> AntigravitySetup {
    use nook_core::workspace::{antigravity::Paths, antigravity_install as install};
    let asset = install::current();
    AntigravitySetup {
        supported: asset.is_some(),
        installed: install::installed(&Paths::current()).is_some(),
        busy: ANTIGRAVITY_BUSY.load(std::sync::atomic::Ordering::SeqCst),
        version: install::VERSION,
        download_bytes: asset.map_or(0, |a| a.archive_bytes),
    }
}

/// Installs the pinned release in the background; `antigravity-install` events carry the phase (`downloading` with
/// `fraction`, `verifying`, `unpacking`, `checking`, then `done` or `failed` with `error`).
#[tauri::command]
pub fn antigravity_install(app: AppHandle) {
    use std::sync::atomic::Ordering;
    if ANTIGRAVITY_BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        use nook_core::workspace::{antigravity::Paths, antigravity_install as install};
        let emit = |phase: &str, fraction: f64, error: Option<&str>| {
            let _ = app.emit("antigravity-install", serde_json::json!({"phase": phase, "fraction": fraction, "error": error}));
        };
        let progress_app = app.clone();
        let result = install::install(&Paths::current(), move |p| {
            let (phase, fraction) = match p {
                install::Phase::Downloading(f) => ("downloading", f),
                install::Phase::Verifying => ("verifying", 1.0),
                install::Phase::Unpacking => ("unpacking", 1.0),
                install::Phase::Checking => ("checking", 1.0),
            };
            let _ = progress_app.emit("antigravity-install", serde_json::json!({"phase": phase, "fraction": fraction}));
        })
        .await;
        ANTIGRAVITY_BUSY.store(false, Ordering::SeqCst);
        match result {
            Ok(()) => emit("done", 1.0, None),
            Err(e) => emit("failed", 0.0, Some(&e)),
        }
        // The agent's executable is found again for the new-session screen.
        let _ = app.emit("workspace-changed", ());
    });
}

#[tauri::command]
pub fn antigravity_uninstall(app: AppHandle) -> Res<()> {
    if ANTIGRAVITY_BUSY.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(tr("Antigravity wordt nog geïnstalleerd.", "Antigravity is still being installed.").into());
    }
    nook_core::workspace::antigravity_install::uninstall(&nook_core::workspace::antigravity::Paths::current())?;
    let _ = app.emit("workspace-changed", ());
    Ok(())
}

/// "Export…" (`SessionExport`): writes a session's Markdown where you chose in the save dialog. Only `.md` files.
#[tauri::command]
pub async fn workspace_save_markdown(path: String, text: String) -> Res<()> {
    let lower = path.to_lowercase();
    if !lower.ends_with(".md") && !lower.ends_with(".markdown") {
        return Err(tr("Alleen een Markdown-bestand (.md).", "Only a Markdown file (.md).").into());
    }
    blocking(move || std::fs::write(&path, text).map_err(|e| e.to_string())).await?
}

/// `/clear`: the session's next message starts a new conversation with the agent; the timeline keeps everything.
#[tauri::command]
pub fn workspace_clear(app: AppHandle, state: State<'_, WorkspaceState>, run: String) -> Res<bool> {
    let id = id(&run)?;
    let cleared = state.manager.clear_conversation(id);
    if cleared {
        if let Some(auto) = app.try_state::<crate::workspace::automation::AutomationState>() {
            auto.handoffs.forget(id);
        }
    }
    Ok(cleared)
}

/// "Turn into project" for a session without a project (`ScratchProjects`): its folder becomes a favorite project.
#[tauri::command]
pub fn workspace_keep_scratch(app: AppHandle, state: State<'_, WorkspaceState>, path: String) -> Res<()> {
    if !nook_core::workspace::scratch::is_scratch(&path) {
        return Err(tr("Deze map is geen map zonder project.", "This folder isn't a folder without a project.").into());
    }
    {
        let mut s = lock(&state.settings);
        if !s.favorite_projects.iter().any(|p| p == &path) {
            s.favorite_projects.push(path.clone());
        }
        s.remember_project(&path);
        s.save_to(&WorkspaceSettings::file());
    }
    let _ = app.emit("workspace-changed", ());
    Ok(())
}

/// "Make it a git repository": `git init` in a session's folder, then git is read again for the sessions there.
#[tauri::command]
pub async fn workspace_init_git(state: State<'_, WorkspaceState>, path: String) -> Res<()> {
    let m = state.manager.clone();
    blocking(move || -> Result<(), String> {
        let git = m.git().ok_or_else(|| tr("Git is niet gevonden.", "Git was not found.").to_string())?;
        git.init_repository(&path).map_err(|e| e.0)?;
        m.adopt_repository(&path);
        Ok(())
    })
    .await?
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
pub fn workspace_send(app: AppHandle, state: State<'_, WorkspaceState>, run: String, text: String) -> Res<()> {
    ensure_telemetry_provider(&app, &state.manager);
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

/// After a launch: "Continue where you left off." for the sessions quitting cut off, when Settings asks for it. `skip`
/// holds the sessions you settled or snoozed. Only the first call after a launch does anything.
#[tauri::command]
pub fn workspace_continue_interrupted(state: State<'_, WorkspaceState>, skip: Vec<String>) -> usize {
    let enabled = state.settings.lock().map(|s| s.continue_after_relaunch).unwrap_or(false);
    let skip = skip.iter().filter_map(|s| s.parse().ok()).collect();
    state.manager.continue_interrupted(enabled, &skip)
}

/// Leaves a question asked before a restart unanswered (`runq:<run>:<request>`).
#[tauri::command]
pub fn workspace_dismiss_question(state: State<'_, WorkspaceState>, id: String) -> Res<()> {
    let missing = || nook_core::i18n::tr("Deze vraag bestaat niet meer.", "This question no longer exists.");
    let rest = id.strip_prefix("runq:").ok_or_else(missing)?;
    let (run, request) = rest.split_once(':').ok_or_else(missing)?;
    state.manager.dismiss_question(self::id(run)?, request);
    Ok(())
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

/// Stages or discards one hunk of a changed file (`HunkPatch`, `applyHunk`): the hunk is cut out of the file's diff
/// as a patch of its own and applied to the index or, reversed, to the working tree.
#[tauri::command]
pub async fn workspace_apply_hunk(
    state: State<'_, WorkspaceState>,
    run: String,
    file: FileChange,
    index: usize,
    action: nook_core::workspace::hunk::HunkAction,
) -> Res<()> {
    let id = id(&run)?;
    let m = state.manager.clone();
    let m2 = m.clone();
    blocking(move || {
        let r = m.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let diff = m.diff(id, &file)?;
        let git = m.git().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        nook_core::workspace::hunk::apply_hunk_to_repo(git, &r.working_directory, &diff, index, action)
    })
    .await??;
    m2.refresh_git(id);
    Ok(())
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
pub fn workspace_can_revert(
    state: State<'_, WorkspaceState>,
    run: String,
    before: DateTime<Utc>,
    conversation_only: Option<bool>,
) -> Res<bool> {
    let run = id(&run)?;
    if conversation_only.unwrap_or(false) {
        Ok(state.manager.can_edit_from_here(run, before))
    } else {
        Ok(state.manager.can_revert(run, before))
    }
}

/// Zet de bestanden (en het gesprek) terug naar hoe ze waren voor dit bericht, of alleen het gesprek (`keep_files`).
#[tauri::command]
pub async fn workspace_revert(state: State<'_, WorkspaceState>, run: String, before: DateTime<Utc>, keep_files: Option<bool>) -> Res<()> {
    let run = id(&run)?;
    let m = state.manager.clone();
    if keep_files.unwrap_or(false) {
        blocking(move || m.edit_from_here(run, before, false)).await?
    } else {
        blocking(move || m.revert_files(run, before)).await?
    }
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

/// Kloont een repository naast het gekozen project (of in `~/Developer`, of `<root>/<host>/<owner>/<repo>` bij
/// host-indeling). Pas na jouw klik op Kloon.
#[tauri::command]
pub async fn workspace_clone(app: AppHandle, state: State<'_, WorkspaceState>, url: String, near: Option<String>) -> Res<String> {
    use nook_core::workspace::source_control_rules::CloneLayout;

    let clean = CloneLayout::repository_url_from_page(&url);
    if !git::is_clone_url(&clean) {
        return Err(tr("Dat is geen adres van een repository.", "That is not the address of a repository.").into());
    }
    let host_layout = app.state::<crate::state::AppState>().settings().worktrees.clone_host_layout;
    let m = state.manager.clone();
    blocking(move || {
        let git = m.git().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let developer = nook_core::agents::home_dir().join("Developer");
        let parent = CloneLayout::clone_parent(near.as_deref().map(std::path::Path::new), host_layout, &developer);
        let parent_str = parent.to_string_lossy().into_owned();
        // With its progress in the main window's clone notices, Hide and Cancel (`CloneCenter` on the Mac).
        crate::workspace::clones::clone(&app, git, &clean, &parent_str, host_layout)
    })
    .await?
}

/// What publishing a local folder to GitHub would do, shown before confirmation (`PublishPlan` on macOS).
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishPlan {
    pub folder: String,
    pub name: String,
    pub needs_repository: bool,
    pub needs_first_commit: bool,
}

/// Returns a `PublishPlan` for `folder` when it has no remote yet, or `None` when already published or git is unavailable.
#[tauri::command]
pub async fn workspace_publish_plan(state: State<'_, WorkspaceState>, folder: String) -> Res<Option<PublishPlan>> {
    use nook_core::workspace::source_control_rules::RepositoryPublish;

    let m = state.manager.clone();
    blocking(move || {
        let git = m.git()?;
        let root = git.repository_root(&folder).map(|r| git.main_checkout(&r).unwrap_or(r));
        let remotes = root.as_deref().map(|r| git.remotes(r)).unwrap_or_default();
        if !RepositoryPublish::can_publish(root.is_some(), &remotes) {
            return None;
        }
        let path = root.clone().unwrap_or(folder);
        let leaf = std::path::Path::new(&path).file_name().and_then(|n| n.to_str()).unwrap_or("project");
        Some(PublishPlan {
            name: RepositoryPublish::suggested_name(leaf),
            needs_repository: root.is_none(),
            needs_first_commit: !git.has_commits(&path),
            folder: path,
        })
    })
    .await
}

/// Publishes a local project to a new GitHub repository, adds `origin`, and pushes the current branch.
/// Returns the created repository's GitHub web URL.
#[tauri::command]
pub async fn workspace_publish_repository(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    folder: String,
    name: String,
    owner: Option<String>,
    is_private: bool,
) -> Res<String> {
    use nook_core::workspace::source_control_rules::create_github_repository;

    let m = state.manager.clone();
    let prep_folder = folder.clone();
    let branch = blocking(move || -> Res<String> {
        let git = m.git().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        git.prepare_publish(&prep_folder).map_err(|e| e.0)
    })
    .await??;

    let clean_owner = owner.map(|o| o.trim().to_string()).filter(|o| !o.is_empty());
    let token_hint = clean_owner.as_deref().unwrap_or("");
    let tokens = crate::workspace::github_tokens(&app, token_hint);
    let made = create_github_repository(&tokens, &name, clean_owner.as_deref(), is_private).await?;

    let m2 = state.manager.clone();
    let push_folder = folder.clone();
    let clone_url = made.clone_url.clone();
    let token = made.token.clone();
    blocking(move || -> Res<()> {
        let git = m2.git().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        git.publish(&push_folder, &clone_url, &branch, Some(&token)).map_err(|e| e.0)
    })
    .await??;

    let norm = nook_core::workspace::paths::normalize(&folder);
    for run in state.manager.runs() {
        let matches = run.repo_root.as_deref().map(nook_core::workspace::paths::normalize).as_deref() == Some(norm.as_str())
            || nook_core::workspace::paths::normalize(&run.project_path) == norm;
        if matches {
            state.manager.refresh_git(run.id);
        }
    }
    let _ = app.emit("workspace-changed", ());
    Ok(made.html_url)
}

/// Copies an image file (<4 MB) into Nook's `project-icons` directory so a project's icon survives moves (`ProjectIconStore`).
#[tauri::command]
pub async fn workspace_project_icon_save(source_path: String) -> Res<String> {
    blocking(move || {
        let dir = nook_core::paths::support_directory().join("project-icons");
        nook_core::workspace::source_control_rules::store_project_icon(std::path::Path::new(&source_path), &dir)
            .map(|p| p.to_string_lossy().into_owned())
    })
    .await?
}

// MARK: De git-knop en pull requests

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickView {
    state: QuickState,
    action: Option<QuickAction>,
    label: Option<&'static str>,
    reason: Option<&'static str>,
    /// Waar het werk van de actie heen gaat: bij de open pull request, of een nieuwe branch.
    destination: Option<&'static str>,
    /// De andere weg naast de hoofdactie: een eigen nieuwe branch en pull request.
    alternatives: Vec<QuickAction>,
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
    let run = m.run(id).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
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
            pull_request_landed: false,
        };
        Some((state, repository, remote, base))
    })
    .await?
    .ok_or(tr("Git kon de stand van deze map niet lezen.", "Git could not read the state of this folder."))?;
    let tokens = repository.as_ref().map(|r| crate::workspace::github_tokens(&app, &r.display_name())).unwrap_or_default();
    let mut pull_request = None;
    if let (Some(repo), Some(branch)) = (&repository, &state.branch) {
        if repo.host == SourceControlHost::Github && !tokens.is_empty() {
            let (open, landed) = source_control::github_branch_pull_requests(&tokens, &repo.display_name(), branch).await;
            pull_request = open;
            state.pull_request_landed = landed;
        }
    }
    state.has_open_pull_request = pull_request.is_some();
    let resolved = source_control::resolve(&state);
    let destination = resolved.ok().and_then(|a| source_control::destination(&state, a));
    let alternatives = source_control::alternatives(&state);
    let can_create_here = repository.as_ref().is_some_and(|r| r.host == SourceControlHost::Github) && !tokens.is_empty();
    Ok(QuickView {
        action: resolved.ok(),
        label: resolved.ok().map(QuickAction::label),
        reason: resolved.err().map(|r| r.message()),
        destination,
        alternatives,
        host_name: repository.as_ref().map(|r| r.host.name()),
        state,
        repository,
        remote,
        base,
        pull_request,
        can_create_here,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartedBranch {
    branch: String,
    cut: Option<String>,
}

/// Een nieuwe branch voor een nieuwe pull request (na jouw klik op "Nieuwe branch en PR").
#[tauri::command]
pub async fn workspace_start_branch(state: State<'_, WorkspaceState>, run: String, topic: String) -> Res<StartedBranch> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.start_branch(run, &topic).map(|(branch, cut)| StartedBranch { branch, cut })).await?
}

#[tauri::command]
pub async fn workspace_move_onto_base(state: State<'_, WorkspaceState>, run: String, cut: String) -> Res<bool> {
    let run = id(&run)?;
    let m = state.manager.clone();
    blocking(move || m.move_onto_base(run, &cut)).await?
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
    let omit_credits = {
        let s = lock(&state.settings);
        s.no_agent_credits || s.strip_agent_credits
    };
    let clean_body = if omit_credits { nook_core::workspace::commit_style::strip_agent_credits(&body) } else { body };
    let m = state.manager.clone();
    blocking(move || {
        let r = m.run(run).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        if r.status.is_active() {
            return Err(tr("Kan niet terwijl de agent werkt.", "Not possible while the agent works.").to_string());
        }
        let git = m.git().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let sha = git.commit_all(&r.working_directory, subject.trim(), &clean_body).map_err(|e| e.0)?;
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
        let r = m.run(run).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
        let git = m.git().ok_or(tr("Git is niet gevonden.", "Git was not found."))?;
        let head = git.current_branch(&r.working_directory).ok_or(tr("Er is geen branch uitgecheckt.", "No branch is checked out."))?;
        let root = r.repo_root.clone().unwrap_or_else(|| r.working_directory.clone());
        let body = source_control::pull_request_template(&root)
            // Pull request text goes to GitHub, so it is always English.
            .unwrap_or_else(|| format!("Made with an agent in Nook.\n\nTask:\n{}", r.task.trim()));
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
    let r = m.run(run).ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
    let dir = r.working_directory.clone();
    let m2 = m.clone();
    let repository = blocking(move || {
        let git = m2.git()?;
        let remotes = git.remotes(&dir);
        let remote = if remotes.iter().any(|r| r == "origin") { "origin".to_string() } else { remotes.first()?.clone() };
        git.remote_url(&dir, &remote).and_then(|u| RemoteRepository::detect(&u))
    })
    .await?
    .ok_or(tr(
        "Deze repository heeft geen remote die Nook herkent. Push de branch en open de pull request bij je eigen host.",
        "This repository has no remote Nook recognizes. Push the branch and open the pull request on your own host.",
    ))?;
    let tokens = crate::workspace::github_tokens(&app, &repository.display_name());
    if repository.host == SourceControlHost::Github && !tokens.is_empty() {
        let url =
            source_control::create_github_pull_request(&tokens, &repository.display_name(), &title, &body, &head, &base, draft).await?;
        m.note(run, &trf("Pull request geopend: {url}", "Pull request opened: {url}", &[("url", &url)]));
        return Ok(PullRequestResult { url, created: true });
    }
    let url = repository.new_pull_request_url(&base, &head, Some(&title), Some(&body), draft).ok_or(tr(
        "Deze repository heeft geen remote die Nook herkent. Push de branch en open de pull request bij je eigen host.",
        "This repository has no remote Nook recognizes. Push the branch and open the pull request on your own host.",
    ))?;
    m.note(
        run,
        &trf(
            "{head} gepusht; {host} geopend om de pull request af te maken",
            "Pushed {head}; opened {host} to finish the pull request",
            &[("head", &head), ("host", &repository.host.name())],
        ),
    );
    Ok(PullRequestResult { url, created: false })
}

// MARK: Verdergaan in Nook

fn nook_provider(kind: AgentKind) -> Res<RunProvider> {
    RunProvider::continues(kind).ok_or_else(|| {
        trf(
            "Nook kan {agent} nog niet zelf aansturen. Claude Code, Codex en Gemini CLI wel.",
            "Nook can't drive {agent} itself yet. It can drive Claude Code, Codex and Gemini CLI.",
            &[("agent", &kind.name())],
        )
    })
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
    continue_live(&app, &session_id, message, ending_terminal).await
}

/// The work of `workspace_continue_live`, also for a message from the phone to a terminal session (`companion`).
pub async fn continue_live(app: &AppHandle, session_id: &str, message: Option<String>, ending_terminal: bool) -> Res<String> {
    let agents_state = app.state::<AgentsState>();
    let session = agents_state
        .hub
        .sessions()
        .into_iter()
        .chain(agents_state.hub.detected())
        .find(|s| s.id == session_id)
        .ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
    let kind = AgentKind::from_agent_name(&session.name).ok_or_else(|| {
        trf("Nook kan {agent} nog niet zelf aansturen.", "Nook can't drive {agent} itself yet.", &[("agent", &session.name)])
    })?;
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
            .ok_or(tr(
                "Ik vind het gesprek van deze sessie niet, dus ik kan hem niet voortzetten.",
                "I can't find this session's conversation, so I can't continue it.",
            ))?
    };
    let busy = !session.is_detected() && matches!(session.status, AgentStatus::Running | AgentStatus::Waiting);
    let mut fork = false;
    if ending_terminal {
        let pid = agents_state.hub.process_id(&session.id).ok_or_else(|| {
            trf("Ik vind het proces van {agent} niet meer.", "I can no longer find the process of {agent}.", &[("agent", &session.name)])
        })?;
        if !scanner::terminate(pid) {
            return Err(trf(
                "Ik kon {agent} niet beëindigen. Draait hij nog?",
                "I could not end {agent}. Is it still running?",
                &[("agent", &session.name)],
            ));
        }
        agents_state.hub.forget(&session.id);
        // De agent even de tijd geven om het laatste van zijn gesprek weg te schrijven.
        tokio::time::sleep(std::time::Duration::from_millis(1_200)).await;
    } else if busy || session.is_detected() {
        // Twee processen mogen niet in één gesprek schrijven: ga verder in een kopie.
        if provider != RunProvider::Claude {
            return Err(trf(
                "{agent} draait nog in een terminal. Kies Neem over in Nook (dat sluit de terminal af), of wacht tot hij klaar is.",
                "{agent} is still running in a terminal. Choose Take over in Nook (that closes the terminal), or wait until it is done.",
                &[("agent", &session.name)],
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
    let past = lock(&agents_state.last_history)
        .sessions
        .iter()
        .find(|p| p.id() == key)
        .cloned()
        .ok_or(tr("Deze sessie bestaat niet meer.", "This session no longer exists."))?;
    let provider = nook_provider(past.agent)?;
    let folder = past.resume_folder();
    if folder.is_empty() {
        return Err(tr(
            "Deze sessie heeft geen map, dus Nook kan hem niet voortzetten.",
            "This session has no folder, so Nook can't continue it.",
        )
        .into());
    }
    if !std::path::Path::new(&folder).is_dir() {
        return Err(trf(
            "De map van deze sessie bestaat niet meer: {folder}",
            "This session's folder no longer exists: {folder}",
            &[("folder", &folder)],
        ));
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

/// Sets or clears a session's active goal (`/goal`, AG-67); empty text clears it.
#[tauri::command]
pub fn workspace_set_goal(state: State<'_, WorkspaceState>, run: String, goal: Option<String>) -> Res<Option<String>> {
    state.manager.set_goal(id(&run)?, goal)
}

/// Computes the context window breakdown and compaction pressure for a session (AG-65 & AG-66).
#[tauri::command]
pub fn workspace_context_usage(
    state: State<'_, WorkspaceState>,
    run: String,
) -> Res<Option<nook_core::workspace::context_usage::ContextUsage>> {
    Ok(state.manager.context_usage(id(&run)?))
}

// MARK: Coding agent versions (`AgentUpdatesSection` on the Mac)

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentVersionInfo {
    pub provider: RunProvider,
    pub executable: Option<String>,
    pub version: Option<String>,
    pub install_command: &'static str,
}

fn read_cli_version(executable: &str) -> Option<String> {
    let mut cmd = std::process::Command::new(executable);
    cmd.arg("--version");
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let output = cmd.output().ok()?;
    let combined = if !output.stdout.is_empty() {
        String::from_utf8_lossy(&output.stdout).into_owned()
    } else {
        String::from_utf8_lossy(&output.stderr).into_owned()
    };
    let line = combined.lines().map(str::trim).find(|l| !l.is_empty())?;
    // Extract semver-like token (e.g., "1.0.32" or "v2.1.0") if present, otherwise first line truncated.
    for token in line.split_whitespace() {
        let cleaned = token.trim_matches(|c: char| matches!(c, '(' | ')' | ',' | ';' | ':')).trim_start_matches('v');
        let parts: Vec<&str> = cleaned.split('.').collect();
        if parts.len() >= 2 && parts[0].chars().all(|c| c.is_ascii_digit()) && !parts[0].is_empty() {
            return Some(cleaned.to_string());
        }
    }
    Some(line.chars().take(40).collect())
}

/// Inspects each runnable coding agent's CLI binary and version (Settings › Coding agents).
#[tauri::command]
pub async fn workspace_agent_versions() -> Res<std::collections::BTreeMap<String, AgentVersionInfo>> {
    blocking(move || {
        let mut out = std::collections::BTreeMap::new();
        for provider in RunProvider::ALL {
            let kind = provider.kind();
            let exe = nook_core::workspace::driver::session_executable(
                provider,
                nook_core::agents::find_executable(kind).map(|e| e.to_string_lossy().into_owned()),
            );
            let version = exe.as_deref().and_then(read_cli_version);
            out.insert(
                provider.id().to_string(),
                AgentVersionInfo { provider, executable: exe, version, install_command: kind.install_command() },
            );
        }
        out
    })
    .await
}

// MARK: Skills catalog, preview, toggle & folder opening (Settings › Coding agents › Skills)

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillCatalogEntry {
    pub name: String,
    pub description: String,
    pub path: String,
    pub folder: String,
    pub source: String,
    pub scope: &'static str,
    pub providers: Vec<RunProvider>,
    pub enabled: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillFolderInfo {
    pub path: String,
    pub label: String,
    pub scope: &'static str,
    pub exists: bool,
    pub count: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillsCatalogView {
    pub skills: Vec<SkillCatalogEntry>,
    pub folders: Vec<SkillFolderInfo>,
}

/// Discovers skills across global and optional project skill folders for the chosen agents.
#[tauri::command]
pub async fn workspace_skills_catalog(
    app: AppHandle,
    project: Option<String>,
    providers: Option<Vec<RunProvider>>,
) -> Res<SkillsCatalogView> {
    let disabled = app.state::<crate::state::AppState>().settings().disabled_skills;
    let chosen: Vec<RunProvider> = match providers {
        Some(list) if !list.is_empty() => list,
        _ => RunProvider::ALL.to_vec(),
    };
    blocking(move || {
        use nook_core::workspace::skills;
        use std::collections::{BTreeMap, BTreeSet};
        use std::path::{Path, PathBuf};

        let home = dirs::home_dir().unwrap_or_default();
        let project_dir = project.as_deref().map(str::trim).filter(|p| !p.is_empty()).map(PathBuf::from).filter(|p| p.is_dir());

        // Collect unique roots and track which providers read each root.
        let mut root_providers: BTreeMap<PathBuf, BTreeSet<RunProvider>> = BTreeMap::new();
        let mut ordered_roots: Vec<PathBuf> = Vec::new();
        for &p in &chosen {
            for r in skills::roots(p, &home, project_dir.as_deref()) {
                if !root_providers.contains_key(&r) {
                    ordered_roots.push(r.clone());
                }
                root_providers.entry(r).or_default().insert(p);
            }
        }

        let mut folders = Vec::new();
        let mut by_path: BTreeMap<String, SkillCatalogEntry> = BTreeMap::new();

        for root in &ordered_roots {
            let scope = if project_dir.as_ref().is_some_and(|pd| root.starts_with(pd)) { "project" } else { "user" };
            let label = format!(
                "{}/{}",
                root.parent().and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            );
            let exists = root.is_dir();
            let found = if exists { skills::scan(std::slice::from_ref(root)) } else { Vec::new() };
            let count = found.len();
            folders.push(SkillFolderInfo { path: root.to_string_lossy().into_owned(), label: label.clone(), scope, exists, count });

            let root_provs: Vec<RunProvider> = root_providers.get(root).map(|s| s.iter().copied().collect()).unwrap_or_default();
            for s in found {
                let folder = Path::new(&s.path)
                    .parent()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_else(|| root.to_string_lossy().into_owned());
                let enabled = !disabled.contains(&s.path);
                by_path
                    .entry(s.path.clone())
                    .and_modify(|e| {
                        for &p in &root_provs {
                            if !e.providers.contains(&p) {
                                e.providers.push(p);
                            }
                        }
                    })
                    .or_insert(SkillCatalogEntry {
                        name: s.name,
                        description: s.description,
                        path: s.path,
                        folder,
                        source: s.source,
                        scope,
                        providers: root_provs.clone(),
                        enabled,
                    });
            }
        }

        let mut skills: Vec<SkillCatalogEntry> = by_path.into_values().collect();
        skills.sort_by(|a, b| a.scope.cmp(b.scope).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        SkillsCatalogView { skills, folders }
    })
    .await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillDocument {
    pub path: String,
    pub name: String,
    pub description: String,
    pub content: String,
    pub scripts: Vec<String>,
}

/// Reads a discovered skill's Markdown document (bounded to 128 KB) and lists any script files beside it.
#[tauri::command]
pub async fn workspace_read_skill(path: String) -> Res<SkillDocument> {
    blocking(move || {
        use std::io::Read;
        use std::path::Path;
        let file = Path::new(&path);
        let lower = path.to_lowercase();
        if !lower.ends_with(".md") || !file.is_file() {
            return Err(tr("Nook kon deze skill niet lezen.", "Nook could not read this skill.").to_string());
        }
        let f = std::fs::File::open(file).map_err(|e| e.to_string())?;
        let mut bytes = Vec::new();
        f.take(128 * 1024).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        let content = String::from_utf8_lossy(&bytes).into_owned();
        let meta = nook_core::workspace::skills::front_matter(&content);
        let fallback = file.parent().and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.clone());
        let name =
            meta.get("name").map(|s| s.trim_matches('"').trim_matches('\'').to_string()).filter(|s| !s.is_empty()).unwrap_or(fallback);
        let description = meta.get("description").map(|s| s.trim_matches('"').trim_matches('\'').to_string()).unwrap_or_default();

        // List scripts inside the skill directory (for folder skills with SKILL.md).
        let mut scripts = Vec::new();
        if file.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case("SKILL.md")) {
            if let Some(dir) = file.parent() {
                collect_scripts(dir, dir, &mut scripts);
            }
        }
        scripts.sort();
        Ok(SkillDocument { path, name, description, content, scripts })
    })
    .await?
}

fn collect_scripts(base: &std::path::Path, dir: &std::path::Path, out: &mut Vec<String>) {
    const EXTS: [&str; 9] = ["sh", "bash", "zsh", "ps1", "bat", "cmd", "py", "js", "ts"];
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if out.len() >= 32 {
            return;
        }
        let path = entry.path();
        if path.is_dir() {
            if !entry.file_name().to_string_lossy().starts_with('.') {
                collect_scripts(base, &path, out);
            }
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if EXTS.iter().any(|&e| e.eq_ignore_ascii_case(ext)) {
                if let Ok(rel) = path.strip_prefix(base) {
                    out.push(rel.to_string_lossy().into_owned());
                }
            }
        }
    }
}

/// Toggles a skill on or off in Settings (non-destructive; stored in `Settings.disabled_skills`).
#[tauri::command]
pub fn workspace_toggle_skill(app: AppHandle, path: String, enabled: bool) -> bool {
    let state = app.state::<crate::state::AppState>();
    let saved = state.update_settings(|s| {
        if enabled {
            s.disabled_skills.remove(&path);
        } else {
            s.disabled_skills.insert(path.clone());
        }
    });
    let _ = app.emit("settings-changed", saved);
    enabled
}

/// Opens a skills folder in the system file manager (creating standard skills folders if missing).
#[tauri::command]
pub fn workspace_open_skills_folder(app: AppHandle, path: String) -> Res<String> {
    use tauri_plugin_opener::OpenerExt;
    let folder = std::path::PathBuf::from(&path);
    if !folder.exists() {
        std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
    }
    app.opener().open_path(folder.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())?;
    Ok(folder.display().to_string())
}

// MARK: Worktree cleanup (`WorktreeCleanupReportView` on the Mac)

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeCleanupEntry {
    pub path: String,
    pub title: Option<String>,
    /// "removed" | "kept" | "failed"
    pub outcome: &'static str,
    pub reason: String,
    pub bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeOrphan {
    pub path: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeCleanupReport {
    pub finished_at: DateTime<Utc>,
    pub entries: Vec<WorktreeCleanupEntry>,
    pub orphans: Vec<WorktreeOrphan>,
    pub bytes_freed: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeCleanupStatus {
    pub total_worktrees: usize,
    pub stale_count: usize,
    pub orphans: Vec<WorktreeOrphan>,
    pub latest_report: Option<WorktreeCleanupReport>,
}

static LAST_CLEANUP_REPORT: std::sync::LazyLock<std::sync::Mutex<Option<WorktreeCleanupReport>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(None));

fn dir_size_bounded(path: &std::path::Path, budget: &mut usize) -> u64 {
    if *budget == 0 {
        return 0;
    }
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    let mut total = 0u64;
    for entry in entries.flatten() {
        if *budget == 0 {
            break;
        }
        *budget -= 1;
        let Ok(meta) = entry.metadata() else { continue };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            total = total.saturating_add(dir_size_bounded(&entry.path(), budget));
        } else {
            total = total.saturating_add(meta.len());
        }
    }
    total
}

fn find_orphan_folders(root: &str, known_paths: &[String]) -> Vec<WorktreeOrphan> {
    let root_path = std::path::Path::new(root);
    let Ok(repos) = std::fs::read_dir(root_path) else { return Vec::new() };
    let known: std::collections::HashSet<String> = known_paths.iter().map(|p| nook_core::workspace::paths::normalize(p)).collect();
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    let mut orphans = Vec::new();
    for repo_entry in repos.flatten() {
        let repo_dir = repo_entry.path();
        if !repo_dir.is_dir() {
            continue;
        }
        let Ok(children) = std::fs::read_dir(&repo_dir) else { continue };
        for child in children.flatten() {
            let child_path = child.path();
            if !child_path.is_dir() {
                continue;
            }
            let norm = nook_core::workspace::paths::normalize(&child_path.to_string_lossy());
            if known.contains(&norm) {
                continue;
            }
            let modified = child.metadata().and_then(|m| m.modified()).ok();
            if modified.is_some_and(|m| m > cutoff) {
                continue;
            }
            let mut budget = 4000;
            let bytes = dir_size_bounded(&child_path, &mut budget);
            orphans.push(WorktreeOrphan { path: child_path.to_string_lossy().into_owned(), bytes });
        }
    }
    orphans.sort_by(|a, b| a.path.cmp(&b.path));
    orphans
}

enum CleanupVerdict {
    Skip,
    Remove { reason: &'static str, title: Option<String> },
    Keep { reason: &'static str, title: Option<String> },
}

fn evaluate_worktree(
    row: &WorktreeRow,
    runs: &[WorkspaceRun],
    running: &std::collections::HashSet<Uuid>,
    rules: &nook_core::settings::WorktreeSettings,
    now: DateTime<Utc>,
) -> CleanupVerdict {
    if row.worktree.is_main {
        return CleanupVerdict::Skip;
    }
    let linked: Vec<&WorkspaceRun> = runs.iter().filter(|r| row.run_ids.contains(&r.id)).collect();
    let title = linked.first().map(|r| r.title.clone()).filter(|t| !t.is_empty());

    // Determine whether any cleanup rule applies to this worktree.
    let mut matched_reason: Option<&'static str> = None;
    if linked.is_empty() && rules.cleanup_on_delete {
        matched_reason = Some("deletedSession");
    } else if !linked.is_empty() {
        let all_archived = linked.iter().all(|r| r.archived);
        let newest_update = linked.iter().map(|r| r.updated_at).max().unwrap_or(now);
        let age_days = (now - newest_update).num_days().max(0) as u32;
        if rules.cleanup_settled_days > 0 && all_archived && age_days >= rules.cleanup_settled_days {
            matched_reason = Some("settled");
        } else if rules.cleanup_inactive_days > 0 && age_days >= rules.cleanup_inactive_days {
            matched_reason = Some("inactive");
        } else if rules.cleanup_unchanged && row.ahead == Some(0) && row.changed_files == Some(0) {
            matched_reason = Some("unchanged");
        }
    }
    let Some(reason) = matched_reason else {
        return CleanupVerdict::Skip;
    };

    // Safety guards: never remove active, shared, symlinked, or dirty worktrees.
    if row.run_ids.iter().any(|id| running.contains(id)) || linked.iter().any(|r| r.status.is_active()) {
        return CleanupVerdict::Keep { reason: "active", title };
    }
    if linked.len() > 1 {
        return CleanupVerdict::Keep { reason: "shared", title };
    }
    if std::fs::symlink_metadata(&row.worktree.path).is_ok_and(|m| m.file_type().is_symlink()) {
        return CleanupVerdict::Keep { reason: "symlink", title };
    }
    if row.changed_files.unwrap_or(0) > 0 {
        return CleanupVerdict::Keep { reason: "uncommittedChanges", title };
    }
    if rules.keep_when == "anyLocalFiles" && row.ahead.unwrap_or(0) > 0 {
        return CleanupVerdict::Keep { reason: "unpushedCommits", title };
    }

    CleanupVerdict::Remove { reason, title }
}

/// Counts total & stale worktrees, orphan folders under the worktree root, and returns the latest cleanup report.
#[tauri::command]
pub async fn workspace_worktree_cleanup_status(app: AppHandle, state: State<'_, WorkspaceState>) -> Res<WorktreeCleanupStatus> {
    let m = state.manager.clone();
    let rules = app.state::<crate::state::AppState>().settings().worktrees;
    let root = lock(&state.settings).worktree_root();
    blocking(move || {
        m.refresh_worktrees();
        let rows = m.worktree_rows();
        let runs = m.runs();
        let running: std::collections::HashSet<Uuid> = runs.iter().filter(|r| m.is_running(r.id)).map(|r| r.id).collect();
        let now = Utc::now();
        let mut stale_count = 0usize;
        let mut total_worktrees = 0usize;
        let mut known_paths = Vec::new();
        for row in &rows {
            known_paths.push(row.worktree.path.clone());
            if !row.worktree.is_main {
                total_worktrees += 1;
            }
            if matches!(evaluate_worktree(row, &runs, &running, &rules, now), CleanupVerdict::Remove { .. }) {
                stale_count += 1;
            }
        }
        for r in &runs {
            if let Some(ref p) = r.worktree_path {
                known_paths.push(p.clone());
            }
        }
        let orphans = find_orphan_folders(&root, &known_paths);
        let latest_report = lock(&LAST_CLEANUP_REPORT).clone();
        WorktreeCleanupStatus { total_worktrees, stale_count, orphans, latest_report }
    })
    .await
}

/// Runs worktree cleanup immediately using the saved `Settings.worktrees` rules and returns a full report.
#[tauri::command]
pub async fn workspace_worktree_cleanup_now(app: AppHandle, state: State<'_, WorkspaceState>) -> Res<WorktreeCleanupReport> {
    let m = state.manager.clone();
    let rules = app.state::<crate::state::AppState>().settings().worktrees;
    let root = lock(&state.settings).worktree_root();
    let report = blocking(move || {
        m.refresh_worktrees();
        let rows = m.worktree_rows();
        let runs = m.runs();
        let running: std::collections::HashSet<Uuid> = runs.iter().filter(|r| m.is_running(r.id)).map(|r| r.id).collect();
        let now = Utc::now();
        let mut entries = Vec::new();
        let mut bytes_freed = 0u64;

        for row in &rows {
            match evaluate_worktree(row, &runs, &running, &rules, now) {
                CleanupVerdict::Skip => {}
                CleanupVerdict::Keep { reason, title } => {
                    entries.push(WorktreeCleanupEntry {
                        path: row.worktree.path.clone(),
                        title,
                        outcome: "kept",
                        reason: reason.into(),
                        bytes: None,
                    });
                }
                CleanupVerdict::Remove { reason, title } => {
                    let mut budget = 6000;
                    let size = dir_size_bounded(std::path::Path::new(&row.worktree.path), &mut budget);
                    match m.remove_worktree_at(&row.repo_root, &row.worktree.path, false) {
                        Ok(()) => {
                            bytes_freed = bytes_freed.saturating_add(size);
                            entries.push(WorktreeCleanupEntry {
                                path: row.worktree.path.clone(),
                                title,
                                outcome: "removed",
                                reason: reason.into(),
                                bytes: Some(size),
                            });
                        }
                        Err(err) => {
                            entries.push(WorktreeCleanupEntry {
                                path: row.worktree.path.clone(),
                                title,
                                outcome: "failed",
                                reason: err,
                                bytes: None,
                            });
                        }
                    }
                }
            }
        }

        let after_rows = m.worktree_rows();
        let mut known_paths: Vec<String> = after_rows.iter().map(|r| r.worktree.path.clone()).collect();
        for r in &runs {
            if let Some(ref p) = r.worktree_path {
                known_paths.push(p.clone());
            }
        }
        let orphans = find_orphan_folders(&root, &known_paths);
        let report = WorktreeCleanupReport { finished_at: Utc::now(), entries, orphans, bytes_freed };
        *lock(&LAST_CLEANUP_REPORT) = Some(report.clone());
        report
    })
    .await?;
    let _ = app.emit("workspace-changed", ());
    Ok(report)
}

/// Opens an existing folder (or the parent folder of a file) in the system file manager.
#[tauri::command]
pub fn workspace_reveal_path(app: AppHandle, path: String) -> Res<()> {
    use tauri_plugin_opener::OpenerExt;
    let p = std::path::PathBuf::from(&path);
    let target = if p.is_dir() {
        p
    } else if let Some(parent) = p.parent().filter(|d| d.is_dir()) {
        parent.to_path_buf()
    } else {
        return Err(tr("Deze map bestaat niet meer.", "This folder no longer exists.").to_string());
    };
    app.opener().open_path(target.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())?;
    Ok(())
}

// MARK: Side chat (`/btw`, `/side`, AG-61)

const SIDE_CHAT_SYSTEM: &str = "You are answering a quick side question (/btw or /side) about a coding-agent session in Nook. \
The main coding agent keeps running separately and uninterrupted. Answer directly, concisely, and accurately using the session context provided. \
Do not claim you ran tools or edited files. Reply in the same language as the user's question.";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SideChatReply {
    pub question: String,
    pub answer: String,
    pub model: String,
    pub created_at: DateTime<Utc>,
}

/// Answers a quick side question (`/btw <question>`, `/side <question>`) about a session using a bounded summary of
/// its recent timeline as context, without interrupting the main agent turn (AG-61).
#[tauri::command]
pub async fn workspace_side_chat(app: AppHandle, state: State<'_, WorkspaceState>, run: String, question: String) -> Res<SideChatReply> {
    let run_id = id(&run)?;
    let clean = question.trim().to_string();
    if clean.is_empty() {
        return Err(tr("Stel een vraag na /btw of /side.", "Ask a question after /btw or /side.").to_string());
    }
    let session =
        state.manager.run(run_id).ok_or_else(|| tr("Deze sessie bestaat niet meer.", "This session no longer exists.").to_string())?;
    let events = state.manager.timeline(run_id);

    // Match macOS `SideChat.cutoff`: exclude the currently in-flight user turn while the main agent works.
    let cutoff = if session.status.is_active() {
        events.iter().rposition(|e| e.kind == EventKind::User).unwrap_or(events.len())
    } else {
        events.len()
    };
    let slice = &events[..cutoff.min(events.len())];
    let summary = nook_core::workspace::handoff::render(slice, 0, session.provider.display_name(), 6_000).map(|r| r.text);

    let mut prompt = String::new();
    prompt.push_str(&format!("Session title: {}\n", session.title));
    prompt.push_str(&format!("Agent: {}\n", session.provider.display_name()));
    if !session.project_path.is_empty() {
        prompt.push_str(&format!("Project: {}\n", session.project_name()));
    }
    if let Some(ref goal) = session.goal {
        if !goal.trim().is_empty() {
            prompt.push_str(&format!("Goal: {}\n", goal.trim()));
        }
    }
    if !session.task.trim().is_empty() {
        prompt.push_str(&format!("Initial task: {}\n", session.task.trim()));
    }
    if let Some(ref ctx) = summary {
        prompt.push_str("\nRecent session timeline:\n");
        prompt.push_str(ctx);
        prompt.push('\n');
    }
    prompt.push_str(&format!("\nSide question: {clean}\n"));

    let app_state = app.state::<crate::state::AppState>();
    let settings = app_state.settings();
    let model = settings.active_model();
    let env = nook_core::brain::service::BrainEnv {
        key: app_state.key_for(settings.provider),
        memory_gb: crate::brain::memory_gb(),
        country: crate::brain::country(),
        timezone: crate::brain::timezone(),
    };

    let answer = tokio::time::timeout(
        std::time::Duration::from_secs(90),
        nook_core::brain::service::complete(&settings, &env, SIDE_CHAT_SYSTEM, &prompt),
    )
    .await
    .map_err(|_| tr("Het zijgesprek duurde te lang.", "The side chat timed out.").to_string())?
    .map_err(|e| e.to_string())?;

    Ok(SideChatReply { question: clean, answer: answer.trim().to_string(), model, created_at: Utc::now() })
}

// MARK: Text generation — session title regeneration & next-prompt suggestions (AG-70)

const TITLE_SYSTEM: &str = "You write short, specific titles for coding-agent sessions in Nook. \
Return only the title itself on a single line (3 to 7 words, no quotes, no trailing period, no markdown). \
Use the same language as the user's messages.";

const NEXT_PROMPT_SYSTEM: &str = "You suggest the single most natural next message the user might send to their coding agent in Nook, \
based on the conversation so far and the agent's latest reply. \
Write from the user's perspective as a direct instruction or question to the agent (one short sentence, under 120 characters, no quotes, no 'Prompt:' prefix, no markdown). \
Use the same language as the user's messages. If no follow-up makes sense, reply with NONE.";

fn fallback_session_title(user_messages: &[String], goal: Option<&str>, task: &str) -> String {
    let source = user_messages.last().map(String::as_str).or(goal).filter(|s| !s.trim().is_empty()).unwrap_or(task);
    let first_line = source.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("Session");
    let words: Vec<&str> = first_line.split_whitespace().take(7).collect();
    let candidate = words.join(" ").trim_matches(|c: char| c == '"' || c == '\'' || c == '.' || c == ':').to_string();
    if candidate.is_empty() {
        "Session".into()
    } else {
        nook_core::agents::text::shorten(&candidate, 60)
    }
}

/// Regenerates a session title from the user messages in its timeline (and active goal / project title instructions),
/// updates the run in `WorkspaceManager`, emits `workspace-changed`, and returns the new title (AG-70).
#[tauri::command]
pub async fn workspace_regenerate_title(app: AppHandle, state: State<'_, WorkspaceState>, run: String) -> Res<String> {
    let run_id = id(&run)?;
    let session =
        state.manager.run(run_id).ok_or_else(|| tr("Deze sessie bestaat niet meer.", "This session no longer exists.").to_string())?;
    let events = state.manager.timeline(run_id);
    let mut user_messages: Vec<String> = events
        .iter()
        .filter(|e| !e.rolled_back.unwrap_or(false) && e.kind == EventKind::User && !e.text.trim().is_empty())
        .map(|e| e.text.trim().to_string())
        .collect();
    if user_messages.is_empty() && !session.task.trim().is_empty() {
        user_messages.push(session.task.trim().to_string());
    }
    if user_messages.is_empty() {
        return Err(tr(
            "Stuur eerst een bericht voordat je de titel opnieuw laat maken.",
            "Send a message first before regenerating the title.",
        )
        .to_string());
    }

    let custom_instructions = {
        let ws_settings = state.settings.lock().unwrap_or_else(|e| e.into_inner());
        let defaults = ws_settings.defaults_for(&session.project_path);
        let trimmed = defaults.title_instructions.trim().to_string();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    };

    let mut prompt = String::new();
    if let Some(ref goal) = session.goal {
        if !goal.trim().is_empty() {
            prompt.push_str(&format!("Active goal: {}\n\n", goal.trim()));
        }
    }
    prompt.push_str("User messages in this session:\n");
    for (idx, msg) in user_messages.iter().rev().take(6).rev().enumerate() {
        prompt.push_str(&format!("{}. {}\n", idx + 1, nook_core::agents::text::shorten(msg, 400)));
    }
    if let Some(ref extra) = custom_instructions {
        prompt.push_str(&format!("\nAdditional project title instructions: {extra}\n"));
    }

    let app_state = app.state::<crate::state::AppState>();
    let settings = app_state.settings();
    let env = nook_core::brain::service::BrainEnv {
        key: app_state.key_for(settings.provider),
        memory_gb: crate::brain::memory_gb(),
        country: crate::brain::country(),
        timezone: crate::brain::timezone(),
    };

    let generated = tokio::time::timeout(
        std::time::Duration::from_secs(20),
        nook_core::brain::service::complete(&settings, &env, TITLE_SYSTEM, &prompt),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(|raw| {
        raw.lines().next().unwrap_or("").trim().trim_matches(|c: char| c == '"' || c == '\'' || c == '`' || c == '.').trim().to_string()
    })
    .filter(|s| !s.is_empty());

    let new_title = generated.unwrap_or_else(|| fallback_session_title(&user_messages, session.goal.as_deref(), &session.task));
    state.manager.rename(run_id, &new_title);
    let _ = app.emit("workspace-changed", ());
    Ok(new_title)
}

/// Suggests the single next follow-up prompt after a completed turn (`None` while running or before the first assistant reply) (AG-70).
#[tauri::command]
pub async fn workspace_suggest_next_prompt(app: AppHandle, state: State<'_, WorkspaceState>, run: String) -> Res<Option<String>> {
    let run_id = id(&run)?;
    let Some(session) = state.manager.run(run_id) else {
        return Ok(None);
    };
    if session.status.is_active() {
        return Ok(None);
    }
    let events = state.manager.timeline(run_id);
    let visible: Vec<_> = events
        .iter()
        .filter(|e| {
            !e.rolled_back.unwrap_or(false) && matches!(e.kind, EventKind::User | EventKind::Assistant) && !e.text.trim().is_empty()
        })
        .collect();
    let has_user = visible.iter().any(|e| e.kind == EventKind::User);
    let ends_with_assistant = visible.last().is_some_and(|e| e.kind == EventKind::Assistant);
    if !has_user || !ends_with_assistant {
        return Ok(None);
    }

    let mut prompt = String::new();
    prompt.push_str(&format!("Session title: {}\n", session.title));
    if let Some(ref goal) = session.goal {
        if !goal.trim().is_empty() {
            prompt.push_str(&format!("Active goal: {}\n", goal.trim()));
        }
    }
    prompt.push_str("\nRecent conversation:\n");
    let start = visible.len().saturating_sub(6);
    for ev in &visible[start..] {
        let role = if ev.kind == EventKind::User { "User" } else { "Assistant" };
        prompt.push_str(&format!("{role}: {}\n", nook_core::agents::text::shorten(ev.text.trim(), 600)));
    }

    let app_state = app.state::<crate::state::AppState>();
    let settings = app_state.settings();
    let env = nook_core::brain::service::BrainEnv {
        key: app_state.key_for(settings.provider),
        memory_gb: crate::brain::memory_gb(),
        country: crate::brain::country(),
        timezone: crate::brain::timezone(),
    };

    let raw = match tokio::time::timeout(
        std::time::Duration::from_secs(15),
        nook_core::brain::service::complete(&settings, &env, NEXT_PROMPT_SYSTEM, &prompt),
    )
    .await
    {
        Ok(Ok(reply)) => reply,
        _ => return Ok(None),
    };

    let first_line = raw.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let stripped = first_line
        .strip_prefix("Prompt:")
        .or_else(|| first_line.strip_prefix("Suggestion:"))
        .unwrap_or(first_line)
        .trim()
        .trim_matches(|c: char| c == '"' || c == '\'' || c == '`')
        .trim();
    if stripped.is_empty() || stripped.len() > 240 || matches!(stripped.to_ascii_lowercase().as_str(), "none" | "null" | "n/a" | "-") {
        return Ok(None);
    }
    Ok(Some(stripped.to_string()))
}

// MARK: Token tuning, agent readiness & session advice (AG-32)

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TuningSnapshot {
    pub rows: Vec<nook_core::workspace::tuning::TuningAdvice>,
    pub applied: nook_core::workspace::tuning::AppliedTuning,
    pub settings_file: String,
    pub home: String,
}

/// Scans every supported coding agent's local configuration for unused token overhead (`AgentTuning.scan` + `withApplied`, AG-32).
#[tauri::command]
pub async fn workspace_tuning_scan() -> Res<TuningSnapshot> {
    blocking(move || {
        let home = dirs::home_dir().unwrap_or_else(nook_core::paths::support_directory);
        let settings_file = home.join(".claude").join("settings.json").to_string_lossy().into_owned();
        let applied = nook_core::workspace::tuning::AppliedTuning::load_from(&nook_core::workspace::tuning::AppliedTuning::file());
        let advice = nook_core::workspace::tuning::scan(&home, Utc::now());
        let rows = nook_core::workspace::tuning::with_applied(advice, &applied, &settings_file);
        TuningSnapshot { rows, applied, settings_file, home: home.to_string_lossy().into_owned() }
    })
    .await
}

/// Applies or removes a Claude Code tuning suggestion for sessions started by Nook (`AgentTuning.Applied`, AG-32).
#[tauri::command]
pub fn workspace_tuning_set(
    app: AppHandle,
    advice: nook_core::workspace::tuning::TuningAdvice,
    on: bool,
) -> Res<nook_core::workspace::tuning::AppliedTuning> {
    let file = nook_core::workspace::tuning::AppliedTuning::file();
    let mut applied = nook_core::workspace::tuning::AppliedTuning::load_from(&file);
    applied.set(&advice, on);
    applied.save_to(&file);
    let kind_label =
        serde_json::to_value(advice.kind).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_else(|| format!("{:?}", advice.kind));
    let args = format!("{} · {} · {}", advice.provider.display_name(), kind_label, advice.items.join(", "));
    if let Some(app_state) = app.try_state::<crate::state::AppState>() {
        app_state.store.audit("token_tuning", &args, if on { "applied in Nook sessions" } else { "removed" });
    }
    Ok(applied)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentReadinessItem {
    pub provider: RunProvider,
    pub state: nook_core::workspace::readiness::ReadinessState,
    pub action: nook_core::workspace::readiness::ReadinessAction,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessSnapshot {
    pub agents: Vec<AgentReadinessItem>,
    pub any_ready: bool,
    pub projects: Vec<nook_core::workspace::readiness::ProjectCandidate>,
}

/// Classifies every coding agent's readiness state and collects recent git project candidates (`AgentReadiness`, AG-32).
#[tauri::command]
pub async fn workspace_readiness(app: AppHandle, state: State<'_, WorkspaceState>) -> Res<ReadinessSnapshot> {
    let runs = state.manager.runs();
    let (recent_projects, favorite_projects) = {
        let ws = lock(&state.settings);
        (ws.recent_projects.clone(), ws.favorite_projects.clone())
    };
    let (live_names, history_accounts, profiles) = if let Some(agents) = app.try_state::<crate::agents::AgentsState>() {
        let live: std::collections::HashSet<String> = agents.hub.sessions().into_iter().map(|s| s.name.to_lowercase()).collect();
        let hist = lock(&agents.last_history).accounts.clone();
        let profs = lock(&agents.profiles).all();
        (live, hist, profs)
    } else {
        Default::default()
    };
    blocking(move || {
        let now = Utc::now();
        let home = dirs::home_dir().unwrap_or_else(nook_core::paths::support_directory);
        let home_str = home.to_string_lossy().into_owned();
        let providers = [
            RunProvider::Claude,
            RunProvider::Codex,
            RunProvider::Gemini,
            RunProvider::Opencode,
            RunProvider::Cursor,
            RunProvider::Grok,
            RunProvider::Antigravity,
        ];
        let mut states = Vec::with_capacity(providers.len());
        let mut agents = Vec::with_capacity(providers.len());
        for provider in providers {
            let kind = provider.kind();
            let installed = nook_core::agents::find_executable(kind).is_some();
            let signed_in = history_accounts.contains_key(kind.id())
                || profiles.iter().any(|p| p.kind == kind && (p.home.as_deref().is_some_and(|h| !h.is_empty()) || p.uses_api_key()))
                || runs.iter().any(|r| r.provider == provider)
                || live_names.contains(&provider.display_name().to_lowercase())
                || live_names.contains(kind.id());
            let st = nook_core::workspace::readiness::classify(true, installed, signed_in, false);
            let action = nook_core::workspace::readiness::action_for(st);
            states.push(st);
            agents.push(AgentReadinessItem { provider, state: st, action });
        }
        let any_ready = nook_core::workspace::readiness::any_ready(&states);
        let sessions: Vec<(String, DateTime<Utc>)> = runs.iter().map(|r| (r.project_path.clone(), r.updated_at)).collect();
        let mut known = recent_projects;
        known.extend(favorite_projects);
        let projects = nook_core::workspace::readiness::project_candidates(&sessions, &known, &home_str, now, 12, |folder| {
            nook_core::workspace::readiness::git_root(folder, |p| std::path::Path::new(p).exists())
        });
        ReadinessSnapshot { agents, any_ready, projects }
    })
    .await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunAdviceSnapshot {
    pub options: Vec<nook_core::workspace::advice::LimitSuggestion>,
    pub fallbacks: Vec<nook_core::workspace::advice::LimitSuggestion>,
    pub stuck: Option<nook_core::workspace::advice::StuckSuggestion>,
}

/// Computes limit-switching suggestions and stuck-session advice for a run (`AgentAdvice`, AG-32).
#[tauri::command]
pub fn workspace_limit_advice(app: AppHandle, state: State<'_, WorkspaceState>, run: String) -> Res<RunAdviceSnapshot> {
    let run_id = id(&run)?;
    let Some(session) = state.manager.run(run_id) else {
        return Ok(RunAdviceSnapshot { options: Vec::new(), fallbacks: Vec::new(), stuck: None });
    };
    let events = state.manager.timeline(run_id);
    let now = Utc::now();

    let mut limit_states = Vec::new();
    let mut seen_current = false;
    if let Some(agents) = app.try_state::<crate::agents::AgentsState>() {
        let profiles = lock(&agents.profiles).all();
        let (default_plan, plans) = agents.hub.plan_usage();
        let codex_map = app.try_state::<crate::agents::usage::UsageState>().map(|u| u.codex_snapshot()).unwrap_or_default();
        for profile in profiles {
            let provider = RunProvider::from_kind(profile.kind);
            let is_current = provider == session.provider && profile.id == session.profile_id;
            if is_current {
                seen_current = true;
            }
            let (used_fraction, reset_at) = match provider {
                RunProvider::Claude => {
                    let reading = plans.get(&profile.id).or(if profile.id == "claude" { default_plan.as_ref() } else { None });
                    let frac = reading.and_then(|u| {
                        [u.five_hour.as_ref(), u.seven_day.as_ref()].into_iter().flatten().map(|w| w.used_percent / 100.0).reduce(f64::max)
                    });
                    let reset = reading.and_then(|u| u.five_hour.as_ref().map(|w| w.resets_at)).or_else(|| {
                        if is_current {
                            session.limit_reset_at
                        } else {
                            None
                        }
                    });
                    (frac, reset)
                }
                RunProvider::Codex => {
                    let reading = codex_map.get(&profile.id);
                    let frac = reading.and_then(|u| {
                        [u.five_hour.as_ref(), u.weekly.as_ref()].into_iter().flatten().map(|w| w.used_percent / 100.0).reduce(f64::max)
                    });
                    let reset = reading.and_then(|u| u.five_hour.as_ref().and_then(|w| w.resets_at)).or_else(|| {
                        if is_current {
                            session.limit_reset_at
                        } else {
                            None
                        }
                    });
                    (frac, reset)
                }
                _ => (None, if is_current { session.limit_reset_at } else { None }),
            };
            limit_states.push(nook_core::workspace::advice::LimitState {
                provider,
                profile_id: profile.id.clone(),
                used_fraction,
                reset_at,
            });
        }
    }
    if !seen_current {
        limit_states.push(nook_core::workspace::advice::LimitState {
            provider: session.provider,
            profile_id: session.profile_id.clone(),
            used_fraction: None,
            reset_at: session.limit_reset_at,
        });
    }

    let current = (session.provider, session.profile_id.as_str());
    let options = nook_core::workspace::advice::LimitAdvisor::options(&limit_states, current, now);
    let fallbacks = nook_core::workspace::advice::LimitAdvisor::fallbacks(&limit_states, current, now);

    let last_event_at = events.last().map(|e| e.date);
    let pending_request_since = events
        .iter()
        .rev()
        .find(|e| e.kind == EventKind::Approval && e.state == Some(nook_core::workspace::models::EventState::Pending))
        .map(|e| e.date);
    let stuck = nook_core::workspace::advice::StuckDetector::detect(&nook_core::workspace::advice::StuckInput {
        status: session.status,
        last_activity: last_event_at.or(session.turn_started_at),
        pending_request_since,
        user_idle_seconds: 0.0,
        limited_since: session.limited_at,
        now,
    });

    Ok(RunAdviceSnapshot { options, fallbacks, stuck })
}

/// Reports whether a completed long session whose cache expired should offer a "Compact first" chip (`ReturnCompaction`, AG-32).
#[tauri::command]
pub fn workspace_offers_compact_first(state: State<'_, WorkspaceState>, run: String) -> Res<bool> {
    Ok(state.manager.offers_compact_first(id(&run)?))
}
