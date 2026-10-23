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
