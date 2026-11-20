//! A tab of the main window in a window of its own (the Mac's `TabWindowController`): the Nook chat, Agents, Chats or
//! Music beside the main window or on another screen. The interface keeps which ones are open and opens them again
//! after a restart (`lib/tab-windows.svelte.ts`); closing one by hand tells it with `tab-window-closed`.

use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

/// The tabs that can have a window of their own, as `SPLIT_CHOICES` in `lib/panel-split.ts`.
pub const TABS: [&str; 4] = ["chat", "agents", "chats", "music"];

/// The window label of a tab's window.
pub fn label(tab: &str) -> String {
    format!("tab-{tab}")
}

/// The tab of a window label, for a tab window.
pub fn tab_of(label: &str) -> Option<&'static str> {
    let tab = label.strip_prefix("tab-")?;
    TABS.iter().copied().find(|t| *t == tab)
}

fn title(tab: &str, language: &str) -> String {
    let name = match (tab, language) {
        ("chat", _) => "Nook",
        ("agents", _) => "Agents",
        ("chats", "fr") => "Discussions",
        ("chats", _) => "Chats",
        ("music", "nl") => "Muziek",
        ("music", "de") => "Musik",
        ("music", "fr") => "Musique",
        ("music", "es") => "Música",
        _ => "Nook",
    };
    if tab == "chat" { name.to_string() } else { format!("{name} · Nook") }
}

/// Opens `tab` in a window of its own, or brings its window forward. `focus: false` (reopening after a restart) leaves
/// the focus where it is.
#[tauri::command]
pub fn open_tab_window(app: AppHandle, tab: String, focus: Option<bool>) -> Result<(), String> {
    let Some(tab) = TABS.iter().copied().find(|t| *t == tab) else {
        return Err(format!("unknown tab {tab}"));
    };
    let focus = focus.unwrap_or(true);
    if let Some(window) = app.get_webview_window(&label(tab)) {
        let _ = window.show();
        let _ = window.unminimize();
        if focus {
            let _ = window.set_focus();
        }
        return Ok(());
    }
    let language = app.state::<crate::state::AppState>().settings().app_language;
    let url = WebviewUrl::App(format!("index.html?tab={tab}#tab").into());
    WebviewWindowBuilder::new(&app, label(tab), url)
        .title(title(tab, &language))
        .inner_size(if tab == "music" { 420.0 } else { 560.0 }, 760.0)
        .min_inner_size(360.0, 420.0)
        .focused(focus)
        .disable_drag_drop_handler()
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Closes `tab`'s window. With `dock`, its tab goes back beside the main tab (the interface already chose it), so the
/// main window comes forward.
#[tauri::command]
pub fn close_tab_window(app: AppHandle, tab: String, dock: Option<bool>) {
    if let Some(window) = app.get_webview_window(&label(&tab)) {
        let _ = app.emit("tab-window-closed", tab.as_str());
        let _ = window.destroy();
    }
    if dock.unwrap_or(false) {
        if let Some(main) = app.get_webview_window("main") {
            let _ = main.show();
            let _ = main.unminimize();
            let _ = main.set_focus();
        }
    }
}

/// A tab window closed by hand: the interface forgets it, so it does not open again at the next start.
pub fn closed(app: &AppHandle, window_label: &str) {
    if let Some(tab) = tab_of(window_label) {
        let _ = app.emit("tab-window-closed", tab);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_name_their_tab() {
        assert_eq!(label("chats"), "tab-chats");
        assert_eq!(tab_of("tab-music"), Some("music"));
        assert_eq!(tab_of("tab-settings"), None);
        assert_eq!(tab_of("main"), None);
    }

    #[test]
    fn titles_say_the_tab() {
        assert_eq!(title("chat", "en"), "Nook");
        assert_eq!(title("music", "nl"), "Muziek · Nook");
        assert_eq!(title("chats", "fr"), "Discussions · Nook");
    }
}
