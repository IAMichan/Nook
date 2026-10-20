//! Wat per besturingssysteem verschilt, als traits. De app (`src-tauri`) vult ze in voor Windows, Linux en Android;
//! een platform dat iets niet kan, geeft `None`/een lege lijst terug of een duidelijke fout, nooit stilte.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub use crate::services::screen::SeenWindow;

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

/// Een app die draait (of het voorste venster ervan).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RunningApp {
    /// De naam zoals de gebruiker hem kent ("Firefox", "Kladblok").
    pub name: String,
    /// Exe-naam op Windows, WM_CLASS op Linux: stabiel, voor "niet in deze app" en Flow-stijlen.
    pub id: String,
    pub pid: u32,
    pub frontmost: bool,
    /// Titel van het voorste venster van de app.
    pub title: String,
}

/// Een plaatje van het scherm, als PNG.
#[derive(Debug, Clone, PartialEq)]
pub struct Capture {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Leest wat er op het scherm staat: UI Automation/OCR op Windows, AT-SPI op Linux. Op Android kan dat niet.
pub trait ScreenReader: Send + Sync {
    fn available(&self) -> bool;
    /// Waarom scherm lezen niet (helemaal) werkt, in een zin voor de gebruiker; leeg als alles werkt.
    fn status(&self) -> String {
        String::new()
    }
    /// Het voorste venster.
    fn frontmost(&self) -> Option<WindowText>;
    /// Alle zichtbare vensters op alle schermen.
    fn all_windows(&self) -> Vec<WindowText>;
    /// De vensters nu, het voorste eerst, nog zonder tekst (voor het live bijhouden).
    fn windows(&self) -> Vec<SeenWindow> {
        vec![]
    }
    /// De tekst van één venster uit [`windows`](Self::windows), met een vingerafdruk van zijn inhoud.
    fn read_window(&self, _id: &str) -> Option<(String, u64)> {
        None
    }
    /// Alleen de vingerafdruk (een klein plaatje), zodat een onveranderd venster niet opnieuw gelezen wordt.
    fn fingerprint(&self, _id: &str) -> Option<u64> {
        None
    }
    /// Leest één app, ook als hij achter andere vensters staat: stukken per venster (titel, tekst).
    fn read_app(&self, query: &str, _limit: usize) -> Result<Vec<(String, String)>, String> {
        Err(format!("Ik kan {query} op dit platform niet lezen."))
    }
    fn active_app(&self) -> Option<RunningApp> {
        None
    }
    fn running_apps(&self) -> Vec<RunningApp> {
        vec![]
    }
    /// Of [`capture_screen`](Self::capture_screen) kan, zonder hem te maken.
    fn can_capture(&self) -> bool {
        false
    }
    /// Een schermafbeelding van het scherm waar de muis is (voor een schermdeel).
    fn capture_screen(&self) -> Result<Capture, String> {
        Err("Een schermafbeelding maken kan op dit platform niet.".into())
    }
    /// Seconden sinds de laatste muis- of toetsenbordinvoer.
    fn idle_seconds(&self) -> f64 {
        0.0
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    /// Hoes als data-URL of https-adres, als die er is.
    pub artwork: Option<String>,
    /// Seconden.
    pub position: Option<f64>,
    pub duration: Option<f64>,
    pub shuffle: Option<bool>,
    pub repeat: Option<bool>,
    /// Volume van de speler, 0–100, als hij dat meldt.
    pub volume: Option<u8>,
    pub can_seek: bool,
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
    /// Het volume van het systeem, 0–100.
    fn set_volume(&self, percent: u8) -> Result<(), String>;
    fn volume(&self) -> Option<u8> {
        None
    }
    fn seek(&self, _seconds: f64) -> Result<(), String> {
        Err("Doorspoelen kan bij deze speler niet.".into())
    }
    fn set_shuffle(&self, _on: bool) -> Result<(), String> {
        Err("Willekeurig afspelen kan bij deze speler niet.".into())
    }
    fn set_repeat(&self, _on: bool) -> Result<(), String> {
        Err("Herhalen kan bij deze speler niet.".into())
    }
    /// Het volume van de speler zelf, 0–100.
    fn set_player_volume(&self, percent: u8) -> Result<(), String> {
        self.set_volume(percent)
    }
}

/// Een app die geïnstalleerd is en geopend kan worden.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InstalledApp {
    pub name: String,
    /// Wat het platform nodig heeft om hem te starten (een .desktop-bestand, AppID of snelkoppeling).
    pub launch: String,
}

/// Kleine systeemacties die het brein mag voorstellen (na "Uitvoeren").
pub trait SystemControl: Send + Sync {
    fn open_app(&self, name: &str) -> Result<(), String>;
    fn open_url(&self, url: &str) -> Result<(), String>;
    fn notify(&self, title: &str, body: &str);
    fn installed_apps(&self) -> Vec<InstalledApp> {
        vec![]
    }
    /// De tekst op het klembord; `None` als er geen tekst op staat of het als geheim gemarkeerd is.
    fn clipboard_text(&self) -> Result<Option<String>, String> {
        Err("Het klembord lezen kan op dit platform niet.".into())
    }
    /// Zet tekst op het klembord en plakt hem waar de gebruiker typt (Flow). Zegt of het plakken lukte; anders
    /// staat de tekst nog op het klembord.
    fn paste_text(&self, _text: &str) -> Result<bool, String> {
        Err("Plakken waar je typt kan op dit platform niet.".into())
    }
    /// Zet een PNG op het klembord (schermdeel kopiëren).
    fn copy_image(&self, _png: &[u8]) -> Result<(), String> {
        Err("Een afbeelding kopiëren kan op dit platform niet.".into())
    }
    /// Zoekt bestanden met de index van het systeem; `None` als die er niet is (dan zoekt de kern zelf).
    fn search_index(&self, _query: &str, _limit: usize) -> Option<Vec<PathBuf>> {
        None
    }
    fn recent_files(&self, _limit: usize) -> Vec<PathBuf> {
        vec![]
    }
    /// De tekst van een PDF, als het platform dat kan.
    fn pdf_text(&self, _path: &std::path::Path) -> Result<String, String> {
        Err("PDF's lezen kan op deze computer niet: installeer pdftotext (poppler-utils).".into())
    }
}

/// Voorlezen: `SpeechSynthesizer` op Windows, speech-dispatcher of espeak op Linux.
pub trait SpeechOutput: Send + Sync {
    fn available(&self) -> bool;
    /// Spreekt `text` uit en stopt wat er al gezegd werd. `language` is bv. "nl-NL".
    fn speak(&self, text: &str, language: &str) -> Result<(), String>;
    /// Zet een zin achter wat er nu gezegd wordt.
    fn enqueue(&self, text: &str, language: &str) -> Result<(), String>;
    fn stop(&self);
    fn speaking(&self) -> bool;
}

/// Dicteren met de herkenning van het systeem zelf, die de microfoon zelf opent (Windows-spraakherkenning).
pub trait Dictation: Send + Sync {
    fn available(&self) -> bool;
    fn start(&self, language: &str) -> Result<(), String>;
    /// Wat er tot nu toe gehoord is.
    fn partial(&self) -> String;
    fn stop(&self) -> Result<String, String>;
    fn cancel(&self);
}

/// "Hé Nook": alleen waar de herkenning lokaal en zuinig kan.
pub trait WakeWord: Send + Sync {
    fn available(&self) -> bool;
    fn start(&self, on_wake: Box<dyn Fn() + Send + Sync>) -> Result<(), String>;
    fn stop(&self);
}

/// A rectangle on screen in physical pixels (as UI Automation reports it).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScreenRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// The text field that has the keyboard focus, for autocomplete. Read on demand, never stored or logged.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FocusedField {
    /// Stable app id (exe name on Windows), for the per-app rules.
    pub app_id: String,
    /// The name the user knows ("Outlook").
    pub app_name: String,
    pub window_title: String,
    /// Text before the cursor (the end of it, a few thousand characters at most).
    pub before: String,
    /// The rest of the line after the cursor.
    pub after: String,
    pub has_selection: bool,
    /// The cursor, when the app reports where it is.
    pub caret: Option<ScreenRect>,
    /// The whole field.
    pub field: Option<ScreenRect>,
}

/// Why there is no field to complete in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldSkip {
    /// Nothing editable has the focus (or the app does not expose it).
    NoField,
    /// A password field: never read.
    Password,
    /// The app runs with more rights than Nook (Windows refuses reading it and typing into it).
    Elevated,
    /// A secure desktop (UAC prompt, lock screen).
    SecureDesktop,
    /// Nook's own windows.
    OwnApp,
}

/// What the keyboard hook reports. Never which character was typed: only what autocomplete needs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputEvent {
    /// The accept-word key, swallowed because a suggestion was on screen.
    AcceptWord,
    /// The accept-all key, swallowed because a suggestion was on screen.
    AcceptAll,
    /// Escape while a suggestion was on screen (swallowed).
    Escape,
    /// Any other key: the field changed or the cursor moved. Passed on to the app untouched.
    Key,
    /// A mouse click: the cursor may have moved.
    Click,
    /// While the emoji picker is open: a letter typed on in the name (it still goes to the app), so the picker filters
    /// without reading the field. Only reported while the picker is open.
    PickerLetter(char),
    /// While the emoji picker is open: Backspace (goes to the app).
    PickerBackspace,
    /// While the emoji picker is open: an arrow key (swallowed).
    PickerMove { dx: i8, dy: i8 },
    /// While the emoji picker is open: 1–9 (swallowed).
    PickerNumber(u8),
    /// While the emoji picker is open and two letters are typed: Return (swallowed).
    PickerReturn,
    /// A click on the picker card (swallowed), in physical pixels from its top left.
    PickerClick { x: f64, y: f64 },
}

/// Autocomplete's platform layer: a keyboard hook, reading the focused field, typing accepted text and the ghost-text
/// window's style. Windows has it; elsewhere [`available`](Self::available) is false and every call says why.
pub trait TextInput: Send + Sync {
    fn available(&self) -> bool;
    /// Why autocomplete does not work here, in a sentence for the user; empty when it does.
    fn status(&self) -> String;
    /// Starts watching keys; `on_event` is called on the hook's thread and must return at once.
    fn start(&self, on_event: std::sync::Arc<dyn Fn(InputEvent) + Send + Sync>) -> Result<(), String>;
    fn stop(&self);
    /// The keys that accept, swallowed only while armed. `None` turns one off (or leaves Tab to the app).
    fn set_keys(
        &self,
        word: Option<crate::services::autocomplete::prefs::KeyChord>,
        all: Option<crate::services::autocomplete::prefs::KeyChord>,
    );
    /// Armed while a suggestion is on screen: only then are the accept keys and Escape swallowed.
    fn arm(&self, armed: bool);
    fn focused_field(&self) -> Result<FocusedField, FieldSkip>;
    /// Types `text` where the cursor is, as key events (never through the clipboard).
    fn type_text(&self, text: &str) -> Result<(), String>;
    /// Deletes `delete` characters before the cursor (Backspace) and types `text`: the emoji picker's `:name`.
    fn replace_text(&self, _delete: usize, _text: &str) -> Result<(), String> {
        Err("Tekst vervangen kan op dit platform niet.".into())
    }
    /// The emoji picker's card (physical pixels) while it is open: clicks on it are taken, and the picker's keys are
    /// reported. `return_takes`: Return picks (two letters typed).
    fn set_picker(&self, _card: Option<ScreenRect>, _return_takes: bool) {}
    /// Makes a window a click-through, never-focused overlay (the ghost text). `handle` is the native window handle.
    fn prepare_overlay(&self, _handle: isize) {}
    /// Shows the overlay at a place in physical pixels without taking the focus, or hides it.
    fn place_overlay(&self, _handle: isize, _rect: Option<ScreenRect>) {}
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
    /// Een kader trekken en dat stuk van het scherm aan de chat geven.
    #[serde(default)]
    pub screen_part: bool,
    /// Opnemen met de microfoon.
    #[serde(default)]
    pub microphone: bool,
    /// Spraakherkenning op dit apparaat zelf (zonder externe dienst).
    #[serde(default)]
    pub local_speech: bool,
    #[serde(default)]
    pub speech_output: bool,
    #[serde(default)]
    pub wake_word: bool,
    /// Dicteren overal (Flow): plakken waar je typt.
    #[serde(default)]
    pub flow: bool,
    /// Het geluid van de computer opnemen voor de Notetaker.
    #[serde(default)]
    pub system_audio: bool,
    #[serde(default)]
    pub open_apps: bool,
    #[serde(default)]
    pub volume: bool,
    #[serde(default)]
    pub clipboard: bool,
    #[serde(default)]
    pub notifications: bool,
    #[serde(default)]
    pub files: bool,
    /// Autocomplete Anywhere: suggestions while typing in any app.
    #[serde(default)]
    pub autocomplete: bool,
    /// Uitleg per mogelijkheid die er niet (helemaal) is, voor de instellingen.
    #[serde(default)]
    pub notes: std::collections::BTreeMap<String, String>,
}
