//! Desktop: de balk bovenaan het scherm (de "notch" van Windows en Linux), het systeemvak en de globale sneltoetsen.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, WebviewUrl, WebviewWindowBuilder};

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use crate::state::AppState;

pub const BAR: &str = "bar";

/// Bar sizes: closed (a small round Nook) and open (the panel with tabs).
pub const COLLAPSED: (f64, f64) = (44.0, 44.0);
/// A compact agent notice: the bar keeps its height and grows wider, with the message and its buttons in the row.
pub const NOTICE: (f64, f64) = (560.0, 38.0);
/// The open panel's default size is this share of the screen's work area, in both directions.
pub const EXPANDED_SCREEN_FRACTION: f64 = 0.75;
/// The smallest the open panel can be dragged to.
pub const EXPANDED_MIN: (f64, f64) = (480.0, 320.0);
pub const EXPANDED_LARGE: (f64, f64) = (960.0, 680.0);

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    create_bar(app)?;
    create_tray(app)?;
    register_shortcuts(app);
    watch_fullscreen(app);
    let settings = app.state::<AppState>().settings();
    if settings.start_local_brain {
        start_local_brain(app, settings.provider);
    }
    restore_main(app);
    Ok(())
}

/// While a game or another app runs full screen, clicks pass through the closed bar to that app, so a click near the
/// top of the screen never lands on Nook by accident. The open panel (from a shortcut, the tray or a message that opens
/// it) and a focused bar always take clicks.
#[cfg(windows)]
fn watch_fullscreen(app: &AppHandle) {
    let app = app.clone();
    let _ = std::thread::Builder::new().name("nook-fullscreen".into()).spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_millis(750));
        let fullscreen = fullscreen_app_in_front();
        let handle = app.clone();
        // Decided and applied on the main thread, in order with the panel opening (`bar_expand` runs there), so a
        // click-through queued from here can never land after the open panel turned it off.
        let _ = app.run_on_main_thread(move || {
            let Some(bar) = handle.get_webview_window(BAR) else { return };
            let pass = fullscreen && !PANEL_OPEN.load(Ordering::Relaxed) && !bar.is_focused().unwrap_or(false);
            if pass != CLICKS_PASS.load(Ordering::Relaxed) {
                set_clicks_pass(&bar, pass);
            }
        });
    });
}

#[cfg(not(windows))]
fn watch_fullscreen(_app: &AppHandle) {}

/// Whether the bar lets clicks through right now.
static CLICKS_PASS: AtomicBool = AtomicBool::new(false);

/// Whether the bar shows its open panel, even without focus.
static PANEL_OPEN: AtomicBool = AtomicBool::new(false);

fn set_clicks_pass(bar: &tauri::WebviewWindow, pass: bool) {
    if bar.set_ignore_cursor_events(pass).is_ok() {
        CLICKS_PASS.store(pass, Ordering::Relaxed);
    }
}

/// Windows' own answer to "is a full-screen app in front?": a Direct3D game in exclusive full screen, a borderless
/// full-screen window (most games, a video, a slideshow) or presentation mode.
#[cfg(windows)]
fn fullscreen_app_in_front() -> bool {
    use windows::Win32::UI::Shell::{SHQueryUserNotificationState, QUNS_BUSY, QUNS_PRESENTATION_MODE, QUNS_RUNNING_D3D_FULL_SCREEN};
    unsafe { SHQueryUserNotificationState() }
        .is_ok_and(|state| state == QUNS_BUSY || state == QUNS_RUNNING_D3D_FULL_SCREEN || state == QUNS_PRESENTATION_MODE)
}

/// A local brain that is installed but not running is started in the background, so the first question just works.
pub fn start_local_brain(_app: &AppHandle, provider: nook_core::provider::AIProvider) {
    use super::local_brain::{ensure_running, Server};
    use nook_core::provider::AIProvider;
    let server = match provider {
        AIProvider::Ollama => Server::Ollama,
        AIProvider::Lmstudio => Server::LmStudio,
        _ => return,
    };
    tauri::async_runtime::spawn(async move {
        let outcome = ensure_running(server).await;
        log::info!("Local brain at launch: {outcome:?}");
    });
}

/// The first time the main window is closed: a note that Nook keeps running, so it does not look like it quit (or
/// like it is still open by mistake).
pub fn closed_main(app: &AppHandle) {
    let state = app.state::<AppState>();
    if state.settings().tray_hint_shown {
        return;
    }
    state.update_settings(|s| s.tray_hint_shown = true);
    super::notify(
        app,
        "Nook draait verder",
        "Nook blijft bovenaan je scherm en in het systeemvak. Alt+Ctrl+W opent het venster weer; stoppen doe je via het systeemvak.",
    );
}

/// Puts the main window back where it was (size, place, maximized), if that place is still on a screen.
fn restore_main(app: &AppHandle) {
    let Some(main) = app.get_webview_window("main") else { return };
    let Some(placement) = app.state::<AppState>().settings().main_window else { return };
    let screens: Vec<(i32, i32, u32, u32)> = main
        .available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| (m.position().x, m.position().y, m.size().width, m.size().height))
        .collect();
    if !placement.visible_on(&screens) {
        return;
    }
    let _ = main.set_size(tauri::PhysicalSize::new(placement.width, placement.height));
    let _ = main.set_position(tauri::PhysicalPosition::new(placement.x, placement.y));
    if placement.maximized {
        let _ = main.maximize();
    }
}

/// Remembers where the main window is, before it hides or Nook stops.
pub fn remember_main(app: &AppHandle) {
    let Some(main) = app.get_webview_window("main") else { return };
    if !main.is_visible().unwrap_or(false) || main.is_minimized().unwrap_or(false) {
        return;
    }
    let maximized = main.is_maximized().unwrap_or(false);
    let state = app.state::<AppState>();
    // A maximized window keeps the size it had before, so un-maximizing after a restart still gives a normal window.
    let previous = state.settings().main_window;
    let (Ok(pos), Ok(size)) = (main.outer_position(), main.inner_size()) else { return };
    let placement = match (maximized, previous) {
        (true, Some(before)) => nook_core::settings::WindowPlacement { maximized: true, ..before },
        _ => nook_core::settings::WindowPlacement { x: pos.x, y: pos.y, width: size.width, height: size.height, maximized },
    };
    if previous != Some(placement) {
        state.update_settings(|s| s.main_window = Some(placement));
    }
}

/// The tray tooltip says what waits on you, so a glance at the taskbar is enough.
pub fn tray_status(app: &AppHandle, waiting: usize, working: usize) {
    let Some(tray) = app.tray_by_id("nook") else { return };
    let _ = tray.set_tooltip(Some(tray_tooltip(waiting, working)));
}

pub fn tray_tooltip(waiting: usize, working: usize) -> String {
    match (waiting, working) {
        (0, 0) => "Nook".into(),
        (0, n) => format!("Nook · bezig met {n}"),
        (1, _) => "Nook · 1 Nook wacht op je".into(),
        (n, _) => format!("Nook · {n} Nooks wachten op je"),
    }
}

fn create_bar(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, BAR, WebviewUrl::App("index.html#bar".into()))
        .title("Nook")
        .inner_size(COLLAPSED.0, COLLAPSED.1)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        // Files dragged onto the closed bar arrive as web drop events; the native handler would swallow them on Windows.
        .disable_drag_drop_handler()
        // Op Linux negeert GTK `set_size` bij een vast formaat; zonder rand kan de gebruiker hem toch niet slepen.
        .resizable(true)
        .min_inner_size(COLLAPSED.0, COLLAPSED.1)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    place_bar(app, false);
    window.show()?;
    Ok(())
}

/// Bovenaan in het midden van het gekozen scherm, of op de plek waar de gebruiker hem neerzette (zwevend).
pub fn place_bar(app: &AppHandle, expanded: bool) {
    place_bar_sized(app, expanded, false);
}

/// The size you dragged the open panel to, and the "large" setting it was made under. Kept so closing the panel and
/// opening it again brings it back at that size instead of the default; a changed "large" setting starts over.
static DRAGGED_SIZE: Mutex<Option<(f64, f64, bool)>> = Mutex::new(None);

/// Like [`place_bar`]; `notice` widens the closed bar for a compact agent notice.
pub fn place_bar_sized(app: &AppHandle, expanded: bool, notice: bool) {
    let was_open = PANEL_OPEN.swap(expanded, Ordering::Relaxed);
    let Some(window) = app.get_webview_window(BAR) else { return };
    let settings = app.state::<AppState>().settings();
    if was_open {
        // The panel is about to close or be placed again: what you dragged it to is kept first.
        if let Ok(inner) = window.inner_size() {
            let window_scale = window.scale_factor().unwrap_or(1.0);
            let (w, h) = (inner.width as f64 / window_scale, inner.height as f64 / window_scale);
            if w >= EXPANDED_MIN.0 && h >= EXPANDED_MIN.1 {
                *DRAGGED_SIZE.lock().unwrap_or_else(|e| e.into_inner()) = Some((w, h, settings.panel_large));
            }
        }
    }
    if expanded {
        // Over a full-screen game the closed bar lets clicks through; the open panel must take them right away.
        set_clicks_pass(&window, false);
    }
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let left = area.position.x as f64 / scale;
    let top = area.position.y as f64 / scale;
    let width = area.size.width as f64 / scale;
    let height = area.size.height as f64 / scale;
    // By default the open panel fills 75% of the screen; the large setting never goes below its fixed size.
    let default_open = (
        (width * EXPANDED_SCREEN_FRACTION).max(EXPANDED_MIN.0).min(width),
        (height * EXPANDED_SCREEN_FRACTION).max(EXPANDED_MIN.1).min(height),
    );
    let dragged = (*DRAGGED_SIZE.lock().unwrap_or_else(|e| e.into_inner()))
        .filter(|&(_, _, large)| large == settings.panel_large)
        .map(|(w, h, _)| (w, h));
    let (w, h) = if !expanded && notice {
        NOTICE
    } else if !expanded {
        COLLAPSED
    } else if let Some((w, h)) = dragged {
        // A size dragged on a larger screen still fits this one.
        (w.min(width).max(EXPANDED_MIN.0.min(width)), h.min(height).max(EXPANDED_MIN.1.min(height)))
    } else if settings.panel_large {
        (EXPANDED_LARGE.0.max(default_open.0).min(width), EXPANDED_LARGE.1.max(default_open.1).min(height))
    } else {
        default_open
    };
    let (x, y) = match (settings.placement.as_str(), settings.float_x, settings.float_y) {
        ("floating", Some(fx), Some(fy)) => (left + width / 2.0 + fx - w / 2.0, top + fy),
        _ => (left + (width - w) / 2.0, top),
    };
    // The closed bar is a fixed round Nook: stretching it would only blow the circle up, so its size is pinned by min
    // and max. (Toggling `resizable` instead changes the window frame, which throws the first open off.)
    let _ = window.set_max_size(None::<LogicalSize<f64>>);
    let _ = window.set_min_size(Some(if expanded { LogicalSize::new(EXPANDED_MIN.0, EXPANDED_MIN.1) } else { LogicalSize::new(w, h) }));
    let _ = window.set_size(LogicalSize::new(w, h));
    let _ = window.set_position(LogicalPosition::new(x, y));
    if !expanded {
        let _ = window.set_max_size(Some(LogicalSize::new(w, h)));
    }
}

/// `--window` opent het hoofdvenster, `--settings` meteen de instellingen.
pub fn route_from_args(args: &[String]) -> Option<&'static str> {
    if args.iter().any(|a| a == "--settings") {
        Some("settings")
    } else if args.iter().any(|a| a == "--window") {
        Some("chat")
    } else {
        None
    }
}

pub fn toggle_main(app: &AppHandle) {
    if let Some(main) = app.get_webview_window("main") {
        if main.is_visible().unwrap_or(false) && main.is_focused().unwrap_or(false) {
            let _ = main.hide();
        } else {
            let _ = main.show();
            let _ = main.set_focus();
        }
    }
}

pub fn show_main(app: &AppHandle, route: &str) {
    // Bewaard voor het geval de interface nog laadt en het event mist.
    *app.state::<AppState>().pending_route.lock().unwrap_or_else(|e| e.into_inner()) = Some(route.to_string());
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show();
        let _ = main.unminimize();
        let _ = main.set_focus();
        let _ = main.emit("navigate", route);
    }
}

/// Opent de balk en zet de cursor in het invoerveld.
pub fn open_bar(app: &AppHandle, focus: &str) {
    // While Nook hides for a share or meeting, agent prompts wait in the bar; a shortcut or the tray still opens it.
    if focus == "agents" && crate::services::quiet::holds_cards(app) {
        return;
    }
    if let Some(bar) = app.get_webview_window(BAR) {
        place_bar(app, true);
        let _ = bar.show();
        let _ = bar.set_focus();
        let _ = bar.emit("bar-open", focus);
    }
}

fn create_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Nook", true, None::<&str>)?;
    let window = MenuItem::with_id(app, "window", "Open in venster", true, Some("Alt+CommandOrControl+W"))?;
    let new_nook = MenuItem::with_id(app, "new", "Nieuwe Nook", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Instellingen…", true, Some("CommandOrControl+,"))?;
    let quit = MenuItem::with_id(app, "quit", "Stop Nook", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[&open, &window, &new_nook, &PredefinedMenuItem::separator(app)?, &settings, &PredefinedMenuItem::separator(app)?, &quit],
    )?;
    let mut builder = TrayIconBuilder::with_id("nook").tooltip("Nook").menu(&menu).show_menu_on_left_click(false);
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => open_bar(app, "chat"),
            "window" => show_main(app, "chat"),
            "new" => {
                show_main(app, "chat");
                let _ = app.emit("new-nook", ());
            }
            "settings" => show_main(app, "settings"),
            "quit" => {
                remember_main(app);
                app.exit(0)
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                open_bar(tray.app_handle(), "chat");
            }
        })
        .build(app)?;
    Ok(())
}

/// Globale sneltoetsen uit de instellingen. Een toets die al door een andere app bezet is, wordt overgeslagen
/// (en gemeld in het logboek), nooit een crash.
pub fn register_shortcuts(app: &AppHandle) {
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
    let shortcuts = app.state::<AppState>().settings().shortcuts;
    let manager = app.global_shortcut();
    let _ = manager.unregister_all();
    for (action, accelerator) in shortcuts {
        let action = action.clone();
        let result = manager.on_shortcut(accelerator.as_str(), move |app, _shortcut, event| {
            if event.state() != ShortcutState::Pressed {
                return;
            }
            match action.as_str() {
                "chat" => open_bar(app, "chat"),
                "talk" => open_bar(app, "voice"),
                "window" => toggle_main(app),
                "lookAlong" => open_bar(app, "lookAlong"),
                _ => {}
            }
        });
        if let Err(e) = result {
            log::warn!("Sneltoets {accelerator} kon niet worden vastgelegd: {e}");
        }
    }
    crate::services::register_shortcuts(app);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tray_says_what_waits() {
        assert_eq!(tray_tooltip(0, 0), "Nook");
        assert_eq!(tray_tooltip(0, 2), "Nook · bezig met 2");
        assert_eq!(tray_tooltip(1, 3), "Nook · 1 Nook wacht op je");
        assert_eq!(tray_tooltip(4, 0), "Nook · 4 Nooks wachten op je");
    }
}
