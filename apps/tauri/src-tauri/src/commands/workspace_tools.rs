//! Commando's voor de gereedschappen van de werkruimte: terminals, de browser, de scripts van een project en
//! dev-servers. Op Android bestaan ze ook, maar zeggen ze netjes dat dit alleen op een computer kan.

#[cfg(desktop)]
use nook_core::workspace::terminal::{self, DevServer, ProjectScript};
use serde::Serialize;
#[cfg(desktop)]
use tauri::Manager as _;
use tauri::{AppHandle, State};

use crate::workspace::WorkspaceState;

type Res<T> = Result<T, String>;

#[cfg(not(desktop))]
const DESKTOP_ONLY: &str = "Terminals, de browser en dev-servers draaien op je computer, niet op je telefoon.";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalView {
    #[cfg(desktop)]
    #[serde(flatten)]
    info: crate::workspace::terminals::TerminalInfo,
}

#[tauri::command]
pub fn terminal_list(state: State<'_, WorkspaceState>) -> Vec<TerminalView> {
    #[cfg(desktop)]
    return state.terminals.list().into_iter().map(|info| TerminalView { info }).collect();
    #[cfg(not(desktop))]
    {
        let _ = state;
        vec![]
    }
}

/// Een nieuwe terminal in `directory` (standaard je thuismap), eventueel met een commando dat je zelf intikte.
#[tauri::command]
pub fn terminal_open(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    directory: Option<String>,
    command: Option<String>,
    title: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> Res<TerminalView> {
    #[cfg(desktop)]
    {
        let dir =
            directory.filter(|d| !d.trim().is_empty()).unwrap_or_else(|| nook_core::agents::home_dir().to_string_lossy().into_owned());
        let size = cols.zip(rows);
        let info = state.terminals.open_with_size(&app, &dir, command.as_deref(), title.as_deref(), None, size)?;
        Ok(TerminalView { info })
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, directory, command, title, cols, rows);
        Err(DESKTOP_ONLY.into())
    }
}

#[tauri::command]
pub fn terminal_write(state: State<'_, WorkspaceState>, id: String, data: String) -> Res<()> {
    #[cfg(desktop)]
    return state.terminals.write(&id, &data);
    #[cfg(not(desktop))]
    {
        let _ = (state, id, data);
        Err(DESKTOP_ONLY.into())
    }
}

#[tauri::command]
pub fn terminal_resize(state: State<'_, WorkspaceState>, id: String, cols: u16, rows: u16) {
    #[cfg(desktop)]
    state.terminals.resize(&id, cols, rows);
    #[cfg(not(desktop))]
    let _ = (state, id, cols, rows);
}

#[tauri::command]
pub fn terminal_replay(state: State<'_, WorkspaceState>, id: String) -> String {
    #[cfg(desktop)]
    return state.terminals.replay(&id);
    #[cfg(not(desktop))]
    {
        let _ = (state, id);
        String::new()
    }
}

#[tauri::command]
pub fn terminal_interrupt(state: State<'_, WorkspaceState>, id: String) -> Res<()> {
    #[cfg(desktop)]
    return state.terminals.interrupt(&id);
    #[cfg(not(desktop))]
    {
        let _ = (state, id);
        Err(DESKTOP_ONLY.into())
    }
}

#[tauri::command]
pub fn terminal_close(app: AppHandle, state: State<'_, WorkspaceState>, id: String) {
    #[cfg(desktop)]
    state.terminals.close(&app, &id);
    #[cfg(not(desktop))]
    let _ = (app, state, id);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderTools {
    #[cfg(desktop)]
    scripts: Vec<ProjectScript>,
    #[cfg(desktop)]
    servers: Vec<DevServer>,
}

/// De scripts van het project (`nook.json`) en de dev-servers die in deze map draaien.
#[tauri::command]
pub async fn workspace_folder_tools(folder: String) -> Res<FolderTools> {
    #[cfg(desktop)]
    {
        let (scripts, servers) =
            tauri::async_runtime::spawn_blocking(move || (terminal::load_scripts(&folder), terminal::scan_dev_servers(&folder)))
                .await
                .map_err(|e| e.to_string())?;
        Ok(FolderTools { scripts, servers })
    }
    #[cfg(not(desktop))]
    {
        let _ = folder;
        Err(DESKTOP_ONLY.into())
    }
}

/// The dev servers in a folder, each marked with whether Nook started it (AG-134): only those get a working Stop.
#[tauri::command]
pub async fn workspace_dev_servers(
    state: State<'_, WorkspaceState>,
    folder: String,
) -> Res<Vec<nook_core::workspace::dev_stop::DevServerView>> {
    #[cfg(desktop)]
    {
        let (shells, agents) = roots_of(&state);
        tauri::async_runtime::spawn_blocking(move || {
            nook_core::workspace::dev_stop::mark(terminal::scan_dev_servers(&folder), &shells, &agents)
        })
        .await
        .map_err(|e| e.to_string())
    }
    #[cfg(not(desktop))]
    {
        let _ = (state, folder);
        Err(DESKTOP_ONLY.into())
    }
}

/// Stops a dev server Nook started; false for one it did not (or that is gone), which is yours to stop where you started it.
#[tauri::command]
pub async fn workspace_stop_dev_server(state: State<'_, WorkspaceState>, folder: String, pid: u32, port: u16) -> Res<bool> {
    #[cfg(desktop)]
    {
        let (shells, agents) = roots_of(&state);
        tauri::async_runtime::spawn_blocking(move || nook_core::workspace::dev_stop::stop(&folder, pid, port, &shells, &agents))
            .await
            .map_err(|e| e.to_string())
    }
    #[cfg(not(desktop))]
    {
        let _ = (state, folder, pid, port);
        Err(DESKTOP_ONLY.into())
    }
}

#[cfg(desktop)]
fn roots_of(state: &WorkspaceState) -> (Vec<u32>, Vec<u32>) {
    let agents = state.manager.runs().iter().filter_map(|r| state.manager.agent_pid(r.id)).collect();
    (state.terminals.shell_pids(), agents)
}

/// Koppelt de werkruimte-brug aan een agent die je zelf in een terminal start: het commando draait zichtbaar in een
/// terminal van Nook, zodat je precies ziet wat er gebeurt. Sessies die Nook start, krijgen de brug vanzelf.
#[tauri::command]
pub fn workspace_link_bridge(app: AppHandle, state: State<'_, WorkspaceState>, provider: String) -> Res<TerminalView> {
    #[cfg(desktop)]
    {
        crate::agents::install_helpers();
        let script = crate::workspace::bridge_script().to_string_lossy().into_owned();
        let quoted = if cfg!(windows) { format!("'{script}'") } else { nook_core::agents::profiles::shell_quote(&script) };
        let command = match provider.as_str() {
            "claude" => format!("claude mcp add --scope user nook -- {quoted} --agent claude-code"),
            "codex" => format!("codex mcp add nook -- {quoted} --agent codex"),
            "gemini" => format!("gemini mcp add --scope user nook {quoted} --agent gemini"),
            _ => return Err("Deze agent krijgt de werkruimte niet via een eigen koppeling.".into()),
        };
        let home = nook_core::agents::home_dir().to_string_lossy().into_owned();
        let title = format!("Werkruimte koppelen aan {provider}");
        let info = state.terminals.open(&app, &home, Some(&command), Some(&title), None)?;
        Ok(TerminalView { info })
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, provider);
        Err(DESKTOP_ONLY.into())
    }
}

// MARK: Browser

#[tauri::command]
pub fn browser_state(state: State<'_, WorkspaceState>) -> serde_json::Value {
    #[cfg(desktop)]
    return serde_json::to_value(state.browser.state()).unwrap_or_default();
    #[cfg(not(desktop))]
    {
        let _ = state;
        serde_json::json!({"open": false, "unavailable": DESKTOP_ONLY})
    }
}

/// Wat je in de adresbalk typt: een adres of een zoekopdracht. Jij klikte, dus het gaat meteen.
#[tauri::command(async)]
pub fn browser_go(app: AppHandle, input: String) -> Res<()> {
    #[cfg(desktop)]
    {
        let url = crate::workspace::browser::address(&input).ok_or("Typ een adres of zoekterm.")?;
        app.state::<WorkspaceState>().browser.go(&app, &url, None)
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, input);
        Err(DESKTOP_ONLY.into())
    }
}

/// Terug, vooruit of opnieuw laden.
#[tauri::command]
pub fn browser_step(app: AppHandle, action: String) -> Res<()> {
    #[cfg(desktop)]
    {
        let js = match action.as_str() {
            "back" => "history.back()",
            "forward" => "history.forward()",
            "reload" => "location.reload()",
            _ => return Err("Onbekende actie.".into()),
        };
        app.state::<WorkspaceState>().browser.eval(&app, js)
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, action);
        Err(DESKTOP_ONLY.into())
    }
}

/// De tekst van de open pagina. Pas als jij (of een agent na goedkeuring) erom vraagt.
#[tauri::command]
pub async fn browser_read(app: AppHandle) -> Res<serde_json::Value> {
    #[cfg(desktop)]
    {
        let page = app.state::<WorkspaceState>().browser.page_text(&app).await?;
        Ok(serde_json::to_value(page).unwrap_or_default())
    }
    #[cfg(not(desktop))]
    {
        let _ = app;
        Err(DESKTOP_ONLY.into())
    }
}

#[tauri::command]
pub fn browser_close(app: AppHandle) {
    #[cfg(desktop)]
    app.state::<WorkspaceState>().browser.close(&app);
    #[cfg(not(desktop))]
    let _ = app;
}

/// The editors on this computer, for Settings › Sessions › Editor & browser.
#[tauri::command]
pub async fn workspace_editors() -> Vec<nook_core::workspace::open_in::Editor> {
    tauri::async_runtime::spawn_blocking(nook_core::workspace::open_in::installed).await.unwrap_or_default()
}

/// Opens `folder` where you chose (Settings › Sessions › Editor & browser): the editor, or the file manager. The session
/// view's "Open in" button calls this.
#[tauri::command]
pub fn workspace_open_in(app: AppHandle, state: State<'_, WorkspaceState>, folder: String) -> Res<()> {
    let editor = state.settings.lock().unwrap_or_else(|e| e.into_inner()).editor.clone();
    let path_var = std::env::var("PATH").unwrap_or_default();
    if let Some(program) = (!editor.is_empty()).then(|| nook_core::workspace::open_in::find(&editor, &path_var)).flatten() {
        let mut cmd = std::process::Command::new(program);
        cmd.arg(&folder);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000);
        }
        return cmd.spawn().map(|_| ()).map_err(|e| e.to_string());
    }
    use tauri_plugin_opener::OpenerExt;
    app.opener().open_path(folder, None::<&str>).map_err(|e| e.to_string())
}

/// The terminals on this computer (Nook's own first), for Settings › Sessions › Editor & browser.
#[tauri::command]
pub async fn workspace_terminals() -> Vec<nook_core::workspace::open_in::Editor> {
    tauri::async_runtime::spawn_blocking(nook_core::workspace::open_in::installed_terminals).await.unwrap_or_default()
}

/// Opens `folder` in the terminal you chose (`openTerminal` on the Mac). Nook's own terminal: opens one there and
/// returns its id, so the view can show it (Agents › All terminals); another terminal: starts it and returns `None`.
#[tauri::command]
pub fn workspace_open_terminal(app: AppHandle, state: State<'_, WorkspaceState>, folder: String) -> Res<Option<String>> {
    use nook_core::workspace::open_in::{find, terminal_command, OpenInPrefs};
    let chosen = OpenInPrefs::current().terminal;
    let path_var = std::env::var("PATH").unwrap_or_default();
    if let Some((program, args)) = terminal_command(&chosen, &folder).filter(|_| find(&chosen, &path_var).is_some()) {
        let mut cmd = std::process::Command::new(program);
        cmd.args(args).current_dir(&folder);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000);
        }
        return cmd.spawn().map(|_| None).map_err(|e| e.to_string());
    }
    #[cfg(desktop)]
    {
        let info = state.terminals.open(&app, &folder, None, None, None)?;
        Ok(Some(info.id))
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state);
        Err(DESKTOP_ONLY.into())
    }
}

/// The rest of Settings › Sessions › Editor & browser: terminal, search engine, where links open, remembering pages.
#[tauri::command]
pub fn open_in_prefs() -> nook_core::workspace::open_in::OpenInPrefs {
    nook_core::workspace::open_in::OpenInPrefs::current()
}

/// Saves those choices; turning "Remember visited pages" off clears the pages kept so far, as on the Mac.
#[tauri::command]
pub async fn open_in_set_prefs(prefs: nook_core::workspace::open_in::OpenInPrefs) -> nook_core::workspace::open_in::OpenInPrefs {
    tauri::async_runtime::spawn_blocking(move || {
        let saved = prefs.save();
        if !saved.remember_history {
            nook_core::workspace::browser_history::clear();
        }
        saved
    })
    .await
    .unwrap_or_default()
}

/// How many pages Nook's browser remembers.
#[tauri::command]
pub async fn browser_history_count() -> usize {
    tauri::async_runtime::spawn_blocking(nook_core::workspace::browser_history::count).await.unwrap_or(0)
}

/// Forgets every page you visited in Nook's browser.
#[tauri::command]
pub async fn browser_history_clear() {
    let _ = tauri::async_runtime::spawn_blocking(nook_core::workspace::browser_history::clear).await;
}

/// Pages you visited before that match what you typed in the address bar (newest first, at most 8).
#[tauri::command]
pub async fn browser_history_suggest(text: String) -> Vec<nook_core::workspace::browser_history::Visit> {
    tauri::async_runtime::spawn_blocking(move || {
        let visits = nook_core::workspace::browser_history::load(&nook_core::workspace::browser_history::file());
        nook_core::workspace::browser_history::suggestions(&visits, &text, 8)
    })
    .await
    .unwrap_or_default()
}

// MARK: Browser element picker into the composer (AG-105)

/// Starts interactive element picking in Nook's browser window and returns the picked element snippet (`BrowserPicker.swift`, AG-105).
#[tauri::command]
pub async fn browser_pick_element(app: AppHandle) -> Res<Option<serde_json::Value>> {
    #[cfg(desktop)]
    {
        let picked = app.state::<WorkspaceState>().browser.pick_element(&app).await?;
        Ok(picked.and_then(|p| serde_json::to_value(p).ok()))
    }
    #[cfg(not(desktop))]
    {
        let _ = app;
        Err(DESKTOP_ONLY.into())
    }
}

/// Cancels an active interactive element pick in Nook's browser window (AG-105).
#[tauri::command]
pub fn browser_cancel_pick(app: AppHandle) -> Res<()> {
    #[cfg(desktop)]
    {
        app.state::<WorkspaceState>().browser.cancel_pick(&app)
    }
    #[cfg(not(desktop))]
    {
        let _ = app;
        Err(DESKTOP_ONLY.into())
    }
}

/// Clears picked element outlines in Nook's browser window (AG-105).
#[tauri::command]
pub fn browser_clear_picks(app: AppHandle) -> Res<()> {
    #[cfg(desktop)]
    {
        app.state::<WorkspaceState>().browser.clear_picks(&app)
    }
    #[cfg(not(desktop))]
    {
        let _ = app;
        Err(DESKTOP_ONLY.into())
    }
}

/// Lists interactive & structural elements on the open browser page so the user can pick an element snippet directly (AG-105).
#[tauri::command]
pub async fn browser_elements(app: AppHandle) -> Res<Vec<serde_json::Value>> {
    #[cfg(desktop)]
    {
        let items = app.state::<WorkspaceState>().browser.page_elements(&app).await?;
        Ok(items.into_iter().filter_map(|i| serde_json::to_value(i).ok()).collect())
    }
    #[cfg(not(desktop))]
    {
        let _ = app;
        Err(DESKTOP_ONLY.into())
    }
}

// MARK: Pull Request Checkout ("Work on this PR", AG-125)

#[cfg(desktop)]
fn resolve_pr_local_folder(app: &AppHandle, ws: &WorkspaceState, repo: &str, preferred: Option<String>) -> Option<String> {
    let git = nook_core::workspace::git::Git::locate()?;
    let ws_settings = ws.settings.lock().unwrap_or_else(|e| e.into_inner());
    let mut folders = Vec::new();
    if let Some(p) = preferred.filter(|p| !p.trim().is_empty()) {
        folders.push(p);
    }
    folders.extend(ws_settings.favorite_projects.clone());
    folders.extend(ws_settings.recent_projects.clone());
    drop(ws_settings);
    let _ = app;
    for r in ws.manager.runs() {
        folders.push(r.working_directory.clone());
        if let Some(wt) = r.worktree_path {
            folders.push(wt);
        }
    }
    nook_core::workspace::pr_checkout::local_folder(&git, repo, &folders)
}

/// Finds the local repository folder matching `repo` (`owner/name`) on this computer (AG-125).
#[tauri::command]
pub async fn workspace_pr_local_folder(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    repo: String,
    preferred: Option<String>,
) -> Res<Option<String>> {
    #[cfg(desktop)]
    {
        let _ = app;
        let ws = state.inner();
        let git = nook_core::workspace::git::Git::locate();
        let mut folders = Vec::new();
        if let Some(p) = preferred.filter(|p| !p.trim().is_empty()) {
            folders.push(p);
        }
        {
            let ws_settings = ws.settings.lock().unwrap_or_else(|e| e.into_inner());
            folders.extend(ws_settings.favorite_projects.clone());
            folders.extend(ws_settings.recent_projects.clone());
        }
        for r in ws.manager.runs() {
            folders.push(r.working_directory.clone());
            if let Some(wt) = r.worktree_path {
                folders.push(wt);
            }
        }
        tauri::async_runtime::spawn_blocking(move || {
            let git = git?;
            nook_core::workspace::pr_checkout::local_folder(&git, &repo, &folders)
        })
        .await
        .map_err(|e| e.to_string())
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, repo, preferred);
        Ok(None)
    }
}

/// Checks out a pull request branch in a new worktree (`mode: "worktree"`) or in the local folder itself (`mode: "here"`)
/// and returns the folder path so a session can be opened in it (`AppModel+PullRequestCheckout.swift`, AG-125).
#[tauri::command]
pub async fn workspace_pr_checkout(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    repo: String,
    number: u64,
    head_branch: String,
    is_fork: Option<bool>,
    mode: nook_core::workspace::pr_checkout::CheckoutMode,
    preferred_folder: Option<String>,
) -> Res<String> {
    #[cfg(desktop)]
    {
        use nook_core::i18n::{tr, trf};
        use nook_core::workspace::pr_checkout::{checkout, CheckoutPlan};
        let folder = resolve_pr_local_folder(&app, state.inner(), &repo, preferred_folder).ok_or_else(|| {
            trf(
                "Geen lokale kloon van {repo} gevonden op deze computer.",
                "No local clone of {repo} was found on this computer.",
                &[("repo", &repo)],
            )
        })?;
        let worktree_root = state.settings.lock().unwrap_or_else(|e| e.into_inner()).worktree_root();
        let mut reserved: Vec<String> = state.manager.worktree_rows().into_iter().map(|r| r.worktree.path).collect();
        for r in state.manager.runs() {
            if let Some(wt) = r.worktree_path {
                reserved.push(wt);
            }
        }
        let dirty_msg = tr(
            "Deze map heeft nog niet-gecommitte wijzigingen. Commit of stash ze eerst, of open de PR in een eigen worktree.",
            "This folder has uncommitted changes. Commit or stash them first, or check out the PR in a new worktree.",
        )
        .to_string();
        let manager = state.manager.clone();
        let path = tauri::async_runtime::spawn_blocking(move || {
            let git = nook_core::workspace::git::Git::locate()
                .ok_or_else(|| tr("Git is niet gevonden op deze computer.", "Git was not found on this computer.").to_string())?;
            let plan = CheckoutPlan::new(&repo, number, &head_branch, is_fork.unwrap_or(false));
            let out = checkout(&git, &plan, mode, &folder, &worktree_root, &reserved, &dirty_msg).map_err(|e| e.0)?;
            manager.refresh_worktrees();
            Ok::<String, String>(out)
        })
        .await
        .map_err(|e| e.to_string())??;
        let _ = tauri::Emitter::emit(&app, "workspace-changed", ());
        Ok(path)
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, repo, number, head_branch, is_fork, mode, preferred_folder);
        Err(DESKTOP_ONLY.into())
    }
}

// MARK: Worktree Build Leftovers, Disk Usage Warning, Archive & Move (AG-121)

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeDiskStatus {
    pub available_bytes: Option<u64>,
    pub low_disk_space: bool,
    pub low_threshold_bytes: u64,
    pub worktrees_bytes: u64,
    pub build_leftovers_bytes: u64,
    pub build_leftovers_count: usize,
    pub archive_bytes: u64,
    pub archive_count: usize,
}

#[cfg(desktop)]
fn build_leftover_roots(state: &WorkspaceState) -> nook_core::workspace::pr_checkout::build_leftovers::Roots {
    use nook_core::workspace::pr_checkout::build_leftovers::{held_folders, is_idle_with_held, Roots};
    use std::path::PathBuf;

    let rows = state.manager.worktree_rows();
    let runs = state.manager.runs();
    let running: std::collections::HashSet<uuid::Uuid> = runs.iter().filter(|r| state.manager.is_running(r.id)).map(|r| r.id).collect();

    let mut busy_dirs = Vec::new();
    for r in &runs {
        if running.contains(&r.id) || r.status.is_active() {
            busy_dirs.push(r.working_directory.clone());
            if let Some(ref wt) = r.worktree_path {
                busy_dirs.push(wt.clone());
            }
        }
    }
    let held = held_folders(&busy_dirs);
    let main_checkouts: Vec<String> = rows.iter().filter(|r| r.worktree.is_main).map(|r| r.worktree.path.clone()).collect();

    let mut worktrees = Vec::new();
    let mut settled_worktrees = std::collections::HashSet::new();
    let mut idle_worktrees = std::collections::HashSet::new();

    for row in &rows {
        if row.worktree.is_main {
            continue;
        }
        let pb = PathBuf::from(&row.worktree.path);
        worktrees.push(pb.clone());
        let linked: Vec<_> = runs.iter().filter(|r| row.run_ids.contains(&r.id)).collect();
        if !linked.is_empty() && linked.iter().all(|r| r.archived) {
            settled_worktrees.insert(pb.clone());
        }
        if is_idle_with_held(&row.worktree.path, &held, &main_checkouts) {
            idle_worktrees.insert(pb);
        }
    }

    let home = nook_core::agents::home_dir();
    let mut temporary = vec![std::env::temp_dir()];
    let var_tmp = PathBuf::from("/private/tmp");
    if var_tmp.is_dir() && !temporary.contains(&var_tmp) {
        temporary.push(var_tmp);
    }
    let mut scratchpad_parents = Vec::new();
    for p in [std::env::temp_dir().join("claude"), PathBuf::from("/private/tmp/claude")] {
        if p.is_dir() && !scratchpad_parents.contains(&p) {
            scratchpad_parents.push(p);
        }
    }
    let derived_data = {
        let dd = home.join("Library/Developer/Xcode/DerivedData");
        dd.is_dir().then_some(dd)
    };

    Roots { temporary, scratchpad_parents, derived_data, worktrees, settled_worktrees, idle_worktrees }
}

/// Scans worktrees, build leftovers, archive size, and available disk space (`BuildLeftovers.swift`, AG-121).
#[tauri::command]
pub async fn workspace_worktree_disk_status(state: State<'_, WorkspaceState>) -> Res<WorktreeDiskStatus> {
    #[cfg(desktop)]
    {
        use nook_core::workspace::pr_checkout::{build_leftovers, disk_space, worktree_archive};
        let worktree_root = state.settings.lock().unwrap_or_else(|e| e.into_inner()).worktree_root();
        let roots = build_leftover_roots(state.inner());
        let worktree_paths: Vec<std::path::PathBuf> = state
            .manager
            .worktree_rows()
            .into_iter()
            .filter(|r| !r.worktree.is_main)
            .map(|r| std::path::PathBuf::from(r.worktree.path))
            .collect();
        tauri::async_runtime::spawn_blocking(move || {
            let available_bytes = disk_space::available_bytes(std::path::Path::new(&worktree_root));
            let low_disk_space = available_bytes.is_some_and(|b| disk_space::is_low(b, false));
            let worktrees_bytes: u64 = worktree_paths.iter().map(|p| build_leftovers::folder_size(p)).sum();
            let leftovers = build_leftovers::find(&roots, std::time::SystemTime::now());
            let build_leftovers_bytes: u64 = leftovers.iter().map(|l| l.size_bytes).sum();
            let build_leftovers_count = leftovers.len();
            let archive_root = worktree_archive::default_root();
            let mut archive_bytes = 0u64;
            let mut archive_count = 0usize;
            if let Ok(entries) = std::fs::read_dir(&archive_root) {
                for entry in entries.flatten() {
                    if entry.file_type().is_ok_and(|ft| ft.is_dir()) {
                        archive_count += 1;
                        archive_bytes = archive_bytes.saturating_add(build_leftovers::folder_size(&entry.path()));
                    }
                }
            }
            WorktreeDiskStatus {
                available_bytes,
                low_disk_space,
                low_threshold_bytes: disk_space::LOW_BYTES,
                worktrees_bytes,
                build_leftovers_bytes,
                build_leftovers_count,
                archive_bytes,
                archive_count,
            }
        })
        .await
        .map_err(|e| e.to_string())
    }
    #[cfg(not(desktop))]
    {
        let _ = state;
        Err(DESKTOP_ONLY.into())
    }
}

/// Scans all stale build leftovers (`target`, `node_modules`, `.next`, `dist`, `.turbo`, `.build`, `.scratch`) (AG-121).
#[tauri::command]
pub async fn workspace_build_leftovers_scan(
    state: State<'_, WorkspaceState>,
) -> Res<Vec<nook_core::workspace::pr_checkout::build_leftovers::Leftover>> {
    #[cfg(desktop)]
    {
        let roots = build_leftover_roots(state.inner());
        tauri::async_runtime::spawn_blocking(move || {
            nook_core::workspace::pr_checkout::build_leftovers::find(&roots, std::time::SystemTime::now())
        })
        .await
        .map_err(|e| e.to_string())
    }
    #[cfg(not(desktop))]
    {
        let _ = state;
        Err(DESKTOP_ONLY.into())
    }
}

/// Sweeps (removes) stale build leftovers and returns the removed entries with freed bytes (AG-121).
#[tauri::command]
pub async fn workspace_build_leftovers_sweep(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
) -> Res<Vec<nook_core::workspace::pr_checkout::build_leftovers::RemovedLeftover>> {
    #[cfg(desktop)]
    {
        let roots = build_leftover_roots(state.inner());
        let removed = tauri::async_runtime::spawn_blocking(move || {
            nook_core::workspace::pr_checkout::build_leftovers::sweep(&roots, std::time::SystemTime::now())
        })
        .await
        .map_err(|e| e.to_string())?;
        let _ = tauri::Emitter::emit(&app, "workspace-changed", ());
        Ok(removed)
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state);
        Err(DESKTOP_ONLY.into())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeArchiveResult {
    pub archived: bool,
    pub archive_path: String,
    pub removed: bool,
}

/// Archives a worktree's `.scratch` files (and optionally removes the worktree) (`WorktreeArchive.swift`, AG-121).
#[tauri::command]
pub async fn workspace_worktree_archive(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    repo: String,
    path: String,
    remove: Option<bool>,
    force: Option<bool>,
) -> Res<WorktreeArchiveResult> {
    #[cfg(desktop)]
    {
        use nook_core::workspace::pr_checkout::worktree_archive;
        let manager = state.manager.clone();
        let should_remove = remove.unwrap_or(false);
        let force_remove = force.unwrap_or(false);
        let res = tauri::async_runtime::spawn_blocking(move || {
            let root = worktree_archive::default_root();
            let loc = worktree_archive::location(&path, &root);
            let archived = worktree_archive::save(&path, &root);
            let mut removed = false;
            if should_remove {
                manager.remove_worktree_at(&repo, &path, force_remove)?;
                removed = true;
            }
            Ok::<WorktreeArchiveResult, String>(WorktreeArchiveResult {
                archived,
                archive_path: loc.to_string_lossy().into_owned(),
                removed,
            })
        })
        .await
        .map_err(|e| e.to_string())??;
        let _ = tauri::Emitter::emit(&app, "workspace-changed", ());
        Ok(res)
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, repo, path, remove, force);
        Err(DESKTOP_ONLY.into())
    }
}

/// Moves a git worktree to a new folder path (`git worktree move`) and refreshes worktrees (AG-121).
#[tauri::command]
pub async fn workspace_worktree_move(
    app: AppHandle,
    state: State<'_, WorkspaceState>,
    repo: String,
    from: String,
    to: String,
) -> Res<String> {
    #[cfg(desktop)]
    {
        use nook_core::i18n::tr;
        let manager = state.manager.clone();
        let dest = tauri::async_runtime::spawn_blocking(move || {
            let git = nook_core::workspace::git::Git::locate()
                .ok_or_else(|| tr("Git is niet gevonden op deze computer.", "Git was not found on this computer.").to_string())?;
            let clean_to = to.trim().to_string();
            if clean_to.is_empty() {
                return Err(tr("Kies een doelmap voor de worktree.", "Choose a destination folder for the worktree.").to_string());
            }
            if let Some(parent) = std::path::Path::new(&clean_to).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            git.run(&["worktree", "move", "--", &from, &clean_to], &repo).map_err(|e| e.0)?;
            manager.refresh_worktrees();
            Ok::<String, String>(clean_to)
        })
        .await
        .map_err(|e| e.to_string())??;
        let _ = tauri::Emitter::emit(&app, "workspace-changed", ());
        Ok(dest)
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, repo, from, to);
        Err(DESKTOP_ONLY.into())
    }
}
