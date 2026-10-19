//! Wat er speelt, voor de Muziek-tab: elke twee seconden kijken, en de interface alleen iets laten weten als er echt
//! iets veranderde (een ander nummer, pauze, shuffle, volume). De positie loopt in de interface zelf door.

use std::time::Duration;

use nook_core::platform::NowPlaying;
use tauri::{AppHandle, Manager};

use super::Services;

/// Gelijk genoeg: alles behalve een positie die gewoon doorloopt.
fn same(a: &Option<NowPlaying>, b: &Option<NowPlaying>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => {
            let jumped = match (a.position, b.position) {
                (Some(x), Some(y)) => (y - x).abs() > 4.0,
                _ => false,
            };
            !jumped
                && a.title == b.title
                && a.artist == b.artist
                && a.playing == b.playing
                && a.shuffle == b.shuffle
                && a.repeat == b.repeat
                && a.volume == b.volume
                && a.artwork == b.artwork
                && a.duration == b.duration
        }
        _ => false,
    }
}

#[cfg(desktop)]
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::Builder::new()
        .name("nook-muziek".into())
        .spawn(move || {
            let services = app.state::<Services>();
            let mut last: Option<NowPlaying> = None;
            loop {
                let now = services.platform.media.now_playing();
                if !same(&last, &now) {
                    super::emit(&app, "now-playing", now.clone());
                }
                last = now;
                std::thread::sleep(Duration::from_secs(2));
            }
        })
        .ok();
}

/// Een snelle nieuwe blik na een bediening, zodat de knop meteen klopt.
pub fn refresh_soon(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(350));
        let now = app.state::<Services>().platform.media.now_playing();
        super::emit(&app, "now-playing", now);
    });
}
