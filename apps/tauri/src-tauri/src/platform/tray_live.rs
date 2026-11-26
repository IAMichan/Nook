//! The tray menu as the Mac's menu bar menu (`AppDelegate.rebuild`): on top, one line each for what is going on right
//! now (the next meeting, the agents at work and how many wait, the one thing that needs you, the music with play and
//! next behind it, an update), then the usual actions. The tooltip says what waits and, when autocomplete counts them,
//! the words it typed today. The taskbar button carries an amber badge with what waits on you (the Mac's Dock badge):
//! an overlay icon on Windows, the launcher's count on Linux.
//!
//! The interface sends what it knows (`tray_live`, from the main window); the bar's counts of waiting and working
//! Nooks come in through `tray_status` as before. Both end in one rebuild here.

use std::sync::Mutex;

use nook_core::i18n::{tr, trf};
use serde::Deserialize;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Manager};

/// What the interface knows right now, for the tray's status lines.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TrayLive {
    /// The next meeting today: its title, and its start as the interface shows it ("14:30"), or `now` while it runs.
    pub next_event: Option<String>,
    pub next_event_at: Option<String>,
    pub next_event_now: bool,
    /// Coding agent sessions at work, and how many of them wait for you.
    pub agents_running: usize,
    pub agents_waiting: usize,
    /// The one thing that waits on you most (`topAttention`), by name, and the route that opens it.
    pub needs_you: Option<String>,
    pub needs_you_route: Option<String>,
    /// The track on one line ("Title – Artist") and whether it plays.
    pub track: Option<String>,
    pub playing: bool,
    /// The updater's phase for the footer (`available`, `installing`, `ready`, `failed`) and the version on offer.
    pub update: Option<String>,
    pub update_version: Option<String>,
    /// Words autocomplete typed today, when Settings › Autocomplete shows the count.
    pub words_today: Option<u64>,
}

#[derive(Default)]
struct Live {
    info: TrayLive,
    waiting: usize,
    working: usize,
    /// The badge last drawn on the taskbar, so an unchanged count draws nothing.
    badge: Option<usize>,
}

static LIVE: Mutex<Option<Live>> = Mutex::new(None);

fn with_live<T>(f: impl FnOnce(&mut Live) -> T) -> T {
    let mut guard = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    f(guard.get_or_insert_with(Live::default))
}

/// A status line of the menu: its id (what a click opens) and its text.
#[derive(Debug, Clone, PartialEq)]
pub struct StatusLine {
    pub id: &'static str,
    pub title: String,
}

/// The status lines in the Mac's order: meeting, agents, needs you, music, update. Empty when all is quiet.
pub fn status_lines(info: &TrayLive) -> Vec<StatusLine> {
    let mut lines = vec![];
    if let Some(event) = info.next_event.as_deref().filter(|t| !t.trim().is_empty()) {
        let when = if info.next_event_now { tr("nu", "now").to_string() } else { info.next_event_at.clone().unwrap_or_default() };
        let title = if when.is_empty() { event.to_string() } else { format!("{event} · {when}") };
        lines.push(StatusLine { id: "status-event", title });
    }
    if info.agents_running > 0 {
        let title = if info.agents_waiting > 0 {
            trf(
                "{n} agents bezig, {w} wachten op jou",
                "{n} agents running, {w} waiting for you",
                &[("n", &info.agents_running), ("w", &info.agents_waiting)],
            )
        } else {
            trf("{n} agents bezig", "{n} agents running", &[("n", &info.agents_running)])
        };
        lines.push(StatusLine { id: "status-agents", title });
    }
    if let Some(top) = info.needs_you.as_deref().filter(|t| !t.trim().is_empty()) {
        lines.push(StatusLine { id: "status-needs", title: trf("Wacht op jou: {title}", "Needs you: {title}", &[("title", &top)]) });
    }
    if let Some(track) = info.track.as_deref().filter(|t| !t.trim().is_empty()) {
        lines.push(StatusLine { id: "status-music", title: track.to_string() });
    }
    let update = match info.update.as_deref() {
        Some("available") => Some(trf(
            "Bijwerken naar Nook {version}…",
            "Update to Nook {version}…",
            &[("version", &info.update_version.clone().unwrap_or_default())],
        )),
        Some("installing") => Some(tr("Nook wordt bijgewerkt…", "Updating Nook…").to_string()),
        Some("ready") => Some(tr("Herstart Nook om de update af te ronden", "Restart Nook to finish the update").to_string()),
        Some("failed") => Some(tr("De update is niet afgerond", "The update did not finish").to_string()),
        _ => None,
    };
    if let Some(title) = update {
        lines.push(StatusLine { id: "status-update", title });
    }
    lines
}

/// The tray's tooltip: what waits and what works (`tray_tooltip`), and the words autocomplete typed today.
pub fn tooltip(waiting: usize, working: usize, words: Option<u64>) -> String {
    let base = super::desktop::tray_tooltip(waiting, working);
    match words {
        Some(n) => format!("{base}\n{}", trf("{n} woorden vandaag aangevuld", "{n} words completed today", &[("n", &n)])),
        None => base,
    }
}

/// The count on the taskbar button: the Nooks and agents that wait on you.
pub fn badge_count(waiting: usize, info: &TrayLive) -> usize {
    waiting + info.agents_waiting
}

/// The menu's status part, then the actions the tray always had (`desktop::tray_menu`).
pub fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let info = with_live(|l| l.info.clone());
    let menu = super::desktop::tray_menu(app)?;
    let lines = status_lines(&info);
    if lines.is_empty() {
        return Ok(menu);
    }
    let mut position = 0;
    for line in &lines {
        if line.id == "status-music" {
            let play = MenuItem::with_id(
                app,
                "music-play",
                if info.playing { tr("Pauzeer", "Pause") } else { tr("Speel af", "Play") },
                true,
                None::<&str>,
            )?;
            let next = MenuItem::with_id(app, "music-next", tr("Volgend nummer", "Next track"), true, None::<&str>)?;
            let music = Submenu::with_id_and_items(app, line.id, &line.title, true, &[&play, &next])?;
            menu.insert(&music, position)?;
        } else {
            menu.insert(&MenuItem::with_id(app, line.id, &line.title, true, None::<&str>)?, position)?;
        }
        position += 1;
    }
    menu.insert(&PredefinedMenuItem::separator(app)?, position)?;
    Ok(menu)
}

/// Label for the tray's Pause / Resume autocomplete item (`AppDelegate.rebuild` on the Mac).
pub fn autocomplete_menu_label(paused: bool) -> &'static str {
    if paused {
        tr("Aanvullen hervatten", "Resume autocomplete")
    } else {
        tr("Aanvullen pauzeren", "Pause autocomplete")
    }
}

/// Today's completed word count for the tray tooltip: an explicit value from the interface wins, otherwise the live
/// autocomplete counter when both autocomplete and its tray-count switch are on.
pub fn words_today_for(enabled: bool, show_count: bool, live_words: u64, override_words: Option<u64>) -> Option<u64> {
    override_words.or_else(|| (enabled && show_count).then_some(live_words))
}

fn effective_words_today(app: &AppHandle, override_words: Option<u64>) -> Option<u64> {
    let settings = app.try_state::<crate::state::AppState>().map(|s| s.settings());
    let enabled = settings.as_ref().is_some_and(|s| s.autocomplete.enabled);
    let show_count = settings.as_ref().is_some_and(|s| s.autocomplete.menu_bar_count);
    let live_words = app.try_state::<crate::services::autocomplete::Autocomplete>().map(|ac| ac.words_today()).unwrap_or(0);
    words_today_for(enabled, show_count, live_words, override_words)
}

/// Rebuilds the tray's menu and tooltip and the taskbar badge from what is known now.
pub fn refresh(app: &AppHandle) {
    let (waiting, working, words_override, badge, changed) = with_live(|l| {
        let badge = badge_count(l.waiting, &l.info);
        let changed = l.badge != Some(badge);
        l.badge = Some(badge);
        (l.waiting, l.working, l.info.words_today, badge, changed)
    });
    let words = effective_words_today(app, words_override);
    if let Some(tray) = app.tray_by_id("nook") {
        let _ = tray.set_tooltip(Some(tooltip(waiting, working, words)));
        if let Ok(menu) = build_menu(app) {
            let _ = tray.set_menu(Some(menu));
        }
    }
    if changed {
        set_badge(app, badge);
    }
}

/// The bar's counts of waiting and working Nooks (`tray_status`).
pub fn set_counts(app: &AppHandle, waiting: usize, working: usize) {
    let same = with_live(|l| {
        let same = l.waiting == waiting && l.working == working;
        l.waiting = waiting;
        l.working = working;
        same
    });
    if !same {
        refresh(app);
    }
}

#[tauri::command]
pub fn tray_live(app: AppHandle, live: TrayLive) {
    let same = with_live(|l| {
        let same = l.info == live;
        l.info = live;
        same
    });
    if !same {
        refresh(&app);
    }
}

/// A click on a status line, the music controls or the autocomplete pause toggle; false for an id that is not one of them.
pub fn handle_menu(app: &AppHandle, id: &str) -> bool {
    match id {
        "status-event" => super::desktop::show_main(app, "chat"),
        "status-agents" => super::desktop::show_main(app, "agents"),
        "status-needs" => {
            let route = with_live(|l| l.info.needs_you_route.clone()).unwrap_or_else(|| "chat".into());
            super::desktop::show_main(app, &route);
        }
        "status-update" => super::desktop::show_main(app, "settings:maintenance"),
        "autocomplete-toggle" => {
            if let Some(ac) = app.try_state::<crate::services::autocomplete::Autocomplete>() {
                if ac.is_paused() {
                    ac.resume();
                } else {
                    ac.pause(None);
                }
                refresh(app);
            }
        }
        "music-play" | "music-next" => {
            let command =
                if id == "music-next" { nook_core::platform::MediaCommand::Next } else { nook_core::platform::MediaCommand::PlayPause };
            let app = app.clone();
            std::thread::spawn(move || {
                let _ = app.state::<crate::services::Services>().platform.media.send(command);
                crate::services::media::refresh_soon(&app);
            });
        }
        _ => return false,
    }
    true
}

/// The taskbar's badge: on Windows an overlay icon with the count on the button, on Linux the launcher's count. The
/// main window is the one in the taskbar. Nothing when no window is there yet.
fn set_badge(app: &AppHandle, count: usize) {
    let Some(main) = app.get_webview_window("main") else { return };
    #[cfg(target_os = "windows")]
    {
        let icon = (count > 0).then(|| tauri::image::Image::new_owned(badge_pixels(count), BADGE, BADGE));
        let _ = main.set_overlay_icon(icon);
    }
    #[cfg(target_os = "linux")]
    {
        let _ = main.set_badge_count(if count == 0 { None } else { Some(count as i64) });
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = (main, count);
    }
}

/// The overlay icon's size in pixels (Windows draws it at 16 by 16 on the taskbar button).
#[cfg_attr(not(windows), allow(dead_code))]
pub const BADGE: u32 = 16;
/// The theme's amber (`--amber`, waiting on you) and the dark text on it.
#[cfg_attr(not(windows), allow(dead_code))]
const AMBER: [u8; 3] = [0xf0, 0xb6, 0x5a];
#[cfg_attr(not(windows), allow(dead_code))]
const ON_AMBER: [u8; 3] = [0x1a, 0x14, 0x08];

/// Digits of a 3×5 pixel font, row by row (three bits each, high bit on the left).
#[cfg_attr(not(windows), allow(dead_code))]
const DIGITS: [[u8; 5]; 10] = [
    [7, 5, 5, 5, 7],
    [2, 6, 2, 2, 7],
    [7, 1, 7, 4, 7],
    [7, 1, 7, 1, 7],
    [5, 5, 7, 1, 1],
    [7, 4, 7, 1, 7],
    [7, 4, 7, 5, 7],
    [7, 1, 1, 2, 2],
    [7, 5, 7, 5, 7],
    [7, 5, 7, 1, 7],
];
#[cfg_attr(not(windows), allow(dead_code))]
const PLUS: [u8; 5] = [0, 2, 7, 2, 0];

/// An amber disc with the count in it (1 to 9, then "9+"), as RGBA pixels of `BADGE` by `BADGE`.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn badge_pixels(count: usize) -> Vec<u8> {
    let size = BADGE as i32;
    let mut px = vec![0u8; (size * size * 4) as usize];
    let centre = (size as f32 - 1.0) / 2.0;
    let radius = size as f32 / 2.0;
    for y in 0..size {
        for x in 0..size {
            let d = ((x as f32 - centre).powi(2) + (y as f32 - centre).powi(2)).sqrt();
            // A soft edge: one pixel of falloff.
            let alpha = (radius - d).clamp(0.0, 1.0);
            if alpha > 0.0 {
                let i = ((y * size + x) * 4) as usize;
                px[i..i + 3].copy_from_slice(&AMBER);
                px[i + 3] = (alpha * 255.0) as u8;
            }
        }
    }
    let glyphs: Vec<[u8; 5]> = if count <= 9 { vec![DIGITS[count]] } else { vec![DIGITS[9], PLUS] };
    // One digit at twice the size; "9+" at the font's own size.
    let scale = if glyphs.len() == 1 { 2 } else { 1 };
    let width = glyphs.len() as i32 * 3 * scale + (glyphs.len() as i32 - 1) * scale;
    let (left, top) = ((size - width) / 2, (size - 5 * scale) / 2);
    for (g, glyph) in glyphs.iter().enumerate() {
        for (row, bits) in glyph.iter().enumerate() {
            for col in 0..3 {
                if bits & (4 >> col) == 0 {
                    continue;
                }
                for dy in 0..scale {
                    for dx in 0..scale {
                        let x = left + g as i32 * 4 * scale + col * scale + dx;
                        let y = top + row as i32 * scale + dy;
                        let i = ((y * size + x) * 4) as usize;
                        px[i..i + 3].copy_from_slice(&ON_AMBER);
                        px[i + 3] = 255;
                    }
                }
            }
        }
    }
    px
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quiet_means_no_status_lines() {
        assert!(status_lines(&TrayLive::default()).is_empty());
    }

    #[test]
    fn status_lines_follow_the_macs_order() {
        nook_core::i18n::set_language("en");
        let info = TrayLive {
            next_event: Some("Standup".into()),
            next_event_at: Some("14:30".into()),
            agents_running: 3,
            agents_waiting: 1,
            needs_you: Some("Anna".into()),
            track: Some("Song – Band".into()),
            update: Some("available".into()),
            update_version: Some("1.2.0".into()),
            ..Default::default()
        };
        let lines = status_lines(&info);
        let ids: Vec<_> = lines.iter().map(|l| l.id).collect();
        assert_eq!(ids, ["status-event", "status-agents", "status-needs", "status-music", "status-update"]);
        assert_eq!(lines[0].title, "Standup · 14:30");
        assert_eq!(lines[1].title, "3 agents running, 1 waiting for you");
        assert_eq!(lines[2].title, "Needs you: Anna");
        assert_eq!(lines[4].title, "Update to Nook 1.2.0…");
        let now = TrayLive { next_event: Some("Standup".into()), next_event_now: true, ..Default::default() };
        assert_eq!(status_lines(&now)[0].title, "Standup · now");
    }

    #[test]
    fn the_tooltip_adds_the_words_of_today() {
        nook_core::i18n::set_language("en");
        assert_eq!(tooltip(0, 0, None), "Nook");
        assert!(tooltip(0, 0, Some(42)).ends_with("42 words completed today"));
        assert_eq!(words_today_for(false, true, 12, None), None);
        assert_eq!(words_today_for(true, false, 12, None), None);
        assert_eq!(words_today_for(true, true, 12, None), Some(12));
        assert_eq!(words_today_for(false, false, 0, Some(7)), Some(7));
        assert_eq!(autocomplete_menu_label(false), "Pause autocomplete");
        assert_eq!(autocomplete_menu_label(true), "Resume autocomplete");
    }

    #[test]
    fn the_badge_counts_what_waits() {
        let info = TrayLive { agents_waiting: 2, ..Default::default() };
        assert_eq!(badge_count(1, &info), 3);
        let px = badge_pixels(3);
        assert_eq!(px.len(), (BADGE * BADGE * 4) as usize);
        // The corner is clear, the middle is drawn.
        assert_eq!(px[3], 0);
        let mid = ((8 * BADGE + 8) * 4) as usize;
        assert!(px[mid + 3] > 0);
        assert_eq!(badge_pixels(12).len(), px.len());
    }
}
