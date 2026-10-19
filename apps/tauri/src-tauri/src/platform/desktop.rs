//! Desktop: de balk bovenaan het scherm (de "notch" van Windows en Linux), het systeemvak en de globale sneltoetsen.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::state::AppState;

pub const BAR: &str = "bar";

/// Maten van de balk: dicht (een pil met Nook en een stipje per agent) en open (het paneel met tabs).
pub const COLLAPSED: (f64, f64) = (240.0, 38.0);
pub const EXPANDED: (f64, f64) = (760.0, 540.0);
pub const EXPANDED_LARGE: (f64, f64) = (960.0, 680.0);

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    create_bar(app)?;
    create_tray(app)?;
    register_shortcuts(app);
    Ok(())
}

fn create_bar(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, BAR, WebviewUrl::App("index.html#bar".into()))
        .title("Nook")
        .inner_size(COLLAPSED.0, COLLAPSED.1)
        .decorations(false)
        .transparent(true)
        .shadow(false)
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
    let Some(window) = app.get_webview_window(BAR) else { return };
    let settings = app.state::<AppState>().settings();
    let (w, h) = if !expanded {
        COLLAPSED
    } else if settings.panel_large {
        EXPANDED_LARGE
    } else {
        EXPANDED
    };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let left = area.position.x as f64 / scale;
    let top = area.position.y as f64 / scale;
    let width = area.size.width as f64 / scale;
    let (x, y) = match (settings.placement.as_str(), settings.float_x, settings.float_y) {
        ("floating", Some(fx), Some(fy)) => (left + width / 2.0 + fx - w / 2.0, top + fy),
        _ => (left + (width - w) / 2.0, top),
    };
    let _ = window.set_size(LogicalSize::new(w, h));
    let _ = window.set_position(LogicalPosition::new(x, y));
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
            "quit" => app.exit(0),
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
}
