//! De kleine vensters van de diensten: de zin naast de balk (meedenken, Flow), het opnamebadge van de Notetaker
//! rechtsonder, en het kader voor een schermdeel. Ze nemen de focus niet, zodat plakken in je eigen app blijft gaan.

use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::state::AppState;

pub const ASIDE: &str = "aside";
pub const BADGE: &str = "recbadge";
pub const PART: &str = "screenpart";

pub const ASIDE_SMALL: (f64, f64) = (340.0, 46.0);
pub const ASIDE_LARGE: (f64, f64) = (380.0, 300.0);
const BADGE_SIZE: (f64, f64) = (240.0, 46.0);

#[cfg(desktop)]
fn small_window(app: &AppHandle, label: &str, hash: &str, size: (f64, f64)) -> tauri::Result<()> {
    if app.get_webview_window(label).is_some() {
        return Ok(());
    }
    WebviewWindowBuilder::new(app, label, WebviewUrl::App(format!("index.html#{hash}").into()))
        .title("Nook")
        .inner_size(size.0, size.1)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()?;
    Ok(())
}

#[cfg(desktop)]
pub fn create(app: &AppHandle) {
    if let Err(e) = small_window(app, ASIDE, "aside", ASIDE_SMALL) {
        log::warn!("Venster naast de balk: {e}");
    }
    if let Err(e) = small_window(app, BADGE, "recbadge", BADGE_SIZE) {
        log::warn!("Opnamebadge: {e}");
    }
}

/// Rechts naast de balk bovenaan (of naast de zwevende Nook).
#[cfg(desktop)]
pub fn place_aside(app: &AppHandle, large: bool) {
    let Some(window) = app.get_webview_window(ASIDE) else { return };
    let (w, h) = if large { ASIDE_LARGE } else { ASIDE_SMALL };
    let Some(monitor) = window.primary_monitor().ok().flatten() else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let (left, top, width) = (area.position.x as f64 / scale, area.position.y as f64 / scale, area.size.width as f64 / scale);
    let settings = app.state::<AppState>().settings();
    let bar = crate::platform::desktop::COLLAPSED;
    let (x, y) = match (settings.placement.as_str(), settings.float_x, settings.float_y) {
        ("floating", Some(fx), Some(fy)) => (left + width / 2.0 + fx + bar.0 / 2.0 + 10.0, top + fy),
        _ => (left + width / 2.0 + bar.0 / 2.0 + 10.0, top + 2.0),
    };
    let _ = window.set_size(LogicalSize::new(w, h));
    let _ = window.set_position(LogicalPosition::new(x.min(left + width - w - 8.0), y));
}

#[cfg(desktop)]
pub fn show_aside(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(ASIDE) {
        place_aside(app, false);
        let _ = window.show();
    }
}

#[cfg(desktop)]
pub fn hide_aside(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(ASIDE) {
        let _ = window.hide();
    }
}

#[cfg(desktop)]
pub fn aside_open(app: &AppHandle) -> bool {
    app.get_webview_window(ASIDE).and_then(|w| w.is_visible().ok()).unwrap_or(false)
}

/// Het badge rechtsonder terwijl de Notetaker opneemt.
#[cfg(desktop)]
pub fn show_badge(app: &AppHandle, show: bool) {
    let Some(window) = app.get_webview_window(BADGE) else { return };
    if !show {
        let _ = window.hide();
        return;
    }
    if let Some(monitor) = window.primary_monitor().ok().flatten() {
        let scale = monitor.scale_factor();
        let area = monitor.work_area();
        let x = (area.position.x as f64 + area.size.width as f64) / scale - BADGE_SIZE.0 - 16.0;
        let y = (area.position.y as f64 + area.size.height as f64) / scale - BADGE_SIZE.1 - 16.0;
        let _ = window.set_size(LogicalSize::new(BADGE_SIZE.0, BADGE_SIZE.1));
        let _ = window.set_position(LogicalPosition::new(x, y));
    }
    let _ = window.show();
}

/// Het venster over het hele scherm waarin je een kader trekt.
#[cfg(desktop)]
pub fn open_part(app: &AppHandle, width: f64, height: f64) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(PART) {
        let _ = window.close();
    }
    let window = WebviewWindowBuilder::new(app, PART, WebviewUrl::App("index.html#screenpart".into()))
        .title("Schermdeel")
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .position(0.0, 0.0)
        .inner_size(width, height)
        .visible(false)
        .build()?;
    let _ = window.set_fullscreen(true);
    let _ = window.show();
    let _ = window.set_focus();
    Ok(())
}

#[cfg(desktop)]
pub fn close_part(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(PART) {
        let _ = window.close();
    }
}
