//! Windows: UI Automation en OCR voor het scherm, de mediabediening van het systeem (GSMTC), Core Audio voor het
//! volume, het Startmenu voor apps, Windows Search voor bestanden, en de spraak van Windows.

mod autocomplete;
mod media;
mod quiet;
mod screen;
mod speech;
mod system;

pub use autocomplete::WindowsTextInput;
pub use media::WindowsMedia;
pub use quiet::{WindowsPower, WindowsQuiet};
pub use screen::WindowsScreen;
pub use speech::{WindowsDictation, WindowsSpeech, WindowsWake};
pub use system::WindowsSystem;
