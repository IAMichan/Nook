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
) -> Res<TerminalView> {
    #[cfg(desktop)]
    {
        let dir =
            directory.filter(|d| !d.trim().is_empty()).unwrap_or_else(|| nook_core::agents::home_dir().to_string_lossy().into_owned());
        let info = state.terminals.open(&app, &dir, command.as_deref(), title.as_deref(), None)?;
        Ok(TerminalView { info })
    }
    #[cfg(not(desktop))]
    {
        let _ = (app, state, directory, command, title);
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
pub async fn workspace_dev_servers(state: State<'_, WorkspaceState>, folder: String) -> Res<Vec<nook_core::workspace::dev_stop::DevServerView>> {
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
#[tauri::command]
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
