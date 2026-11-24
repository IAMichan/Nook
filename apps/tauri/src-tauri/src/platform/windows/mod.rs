//! Windows: UI Automation en OCR voor het scherm, de mediabediening van het systeem (GSMTC), Core Audio voor het
//! volume, het Startmenu voor apps, Windows Search voor bestanden, en de spraak van Windows.

mod autocomplete;
mod browser;
pub mod hold_key;
mod media;
mod menu;
mod quiet;
mod screen;
mod speech;
mod system;
pub mod toast;
mod ui_control;

pub use autocomplete::WindowsTextInput;
pub use media::WindowsMedia;
pub use quiet::{WindowsPower, WindowsQuiet};
pub use speech::{WindowsDictation, WindowsSpeech, WindowsWake};
pub use system::WindowsSystem;
pub use ui_control::WindowsUiScreen;
