//! Wat per besturingssysteem verschilt, als traits. De app (`src-tauri`) vult ze in voor Windows, Linux en Android;
//! een platform dat iets niet kan, geeft `None`/een lege lijst terug of een duidelijke fout, nooit stilte.

use serde::{Deserialize, Serialize};

/// De tekst van een venster dat nu op het scherm staat (op de Mac: OCR van ScreenCaptureKit).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WindowText {
    pub app: String,
    pub title: String,
    pub text: String,
    /// Het venster dat voor staat.
    pub frontmost: bool,
}

/// Leest wat er op het scherm staat: UI Automation/OCR op Windows, AT-SPI op Linux. Op Android kan dat niet.
pub trait ScreenReader: Send + Sync {
    fn available(&self) -> bool;
    /// Het voorste venster.
    fn frontmost(&self) -> Option<WindowText>;
    /// Alle zichtbare vensters op alle schermen.
    fn all_windows(&self) -> Vec<WindowText>;
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    /// Hoes als data-URL, als die er is.
    pub artwork: Option<String>,
    pub position: Option<f64>,
    pub duration: Option<f64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum MediaCommand {
    PlayPause,
    Next,
    Previous,
}

/// Muziek: Windows Media Controls (GSMTC) op Windows, MPRIS op Linux, MediaSession op Android.
pub trait MediaControl: Send + Sync {
    fn now_playing(&self) -> Option<NowPlaying>;
    fn send(&self, command: MediaCommand) -> Result<(), String>;
    fn set_volume(&self, percent: u8) -> Result<(), String>;
}

/// Kleine systeemacties die het brein mag voorstellen (na "Uitvoeren").
pub trait SystemControl: Send + Sync {
    fn open_app(&self, name: &str) -> Result<(), String>;
    fn open_url(&self, url: &str) -> Result<(), String>;
    fn notify(&self, title: &str, body: &str);
}

/// Welke mogelijkheden dit platform heeft; de interface verbergt wat er niet is.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub os: String,
    pub desktop: bool,
    pub screen_reading: bool,
    pub global_shortcuts: bool,
    pub tray: bool,
    pub terminals: bool,
    pub local_agents: bool,
    pub media: bool,
}
