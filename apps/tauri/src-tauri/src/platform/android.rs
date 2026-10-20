//! Android (en elk platform zonder eigen laag): Nook ziet hier geen andere apps, bedient geen muziek en neemt niets
//! op. Alles zegt dat duidelijk; de interface verbergt het via `Capabilities`.

use std::sync::Arc;

use nook_core::platform::{MediaCommand, MediaControl, NowPlaying, ScreenReader, SystemControl, WindowText};
use tauri::AppHandle;

use super::{Platform, Unavailable};

const SCREEN: &str = "Op Android kan Nook niet meekijken: apps mogen elkaars scherm niet lezen.";
const MEDIA: &str = "Muziek bedienen kan Nook op Android (nog) niet.";
const APPS: &str = "Apps openen kan Nook op Android niet.";

pub struct NoScreen;

impl ScreenReader for NoScreen {
    fn available(&self) -> bool {
        false
    }
    fn status(&self) -> String {
        SCREEN.into()
    }
    fn frontmost(&self) -> Option<WindowText> {
        None
    }
    fn all_windows(&self) -> Vec<WindowText> {
        vec![]
    }
    fn read_app(&self, _query: &str, _limit: usize) -> Result<Vec<(String, String)>, String> {
        Err(SCREEN.into())
    }
}

pub struct NoMedia;

impl MediaControl for NoMedia {
    fn now_playing(&self) -> Option<NowPlaying> {
        None
    }
    fn send(&self, _command: MediaCommand) -> Result<(), String> {
        Err(MEDIA.into())
    }
    fn set_volume(&self, _percent: u8) -> Result<(), String> {
        Err("Het volume zetten kan Nook op Android niet.".into())
    }
}

pub struct MobileSystem {
    app: AppHandle,
}

impl SystemControl for MobileSystem {
    fn open_app(&self, _name: &str) -> Result<(), String> {
        Err(APPS.into())
    }

    fn open_url(&self, url: &str) -> Result<(), String> {
        use tauri_plugin_opener::OpenerExt;
        self.app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
    }

    fn notify(&self, title: &str, body: &str) {
        super::notify(&self.app, title, body);
    }
}

pub fn services(app: &AppHandle) -> Platform {
    Platform {
        screen: Arc::new(NoScreen),
        media: Arc::new(NoMedia),
        system: Arc::new(MobileSystem { app: app.clone() }),
        speech: Arc::new(Unavailable("Voorlezen kan Nook op Android (nog) niet.")),
        dictation: Arc::new(Unavailable("Spraakherkenning kan Nook op Android (nog) niet.")),
        wake: Arc::new(Unavailable("\"Hé Nook\" kan op Android niet.")),
        quiet: Arc::new(Unavailable("Meetings en scherm delen herkent Nook op Android niet.")),
        power: Arc::new(Unavailable("De accu leest Nook op Android niet.")),
        text_input: Arc::new(Unavailable("Aanvullen in elke app kan op Android niet.")),
    }
}
