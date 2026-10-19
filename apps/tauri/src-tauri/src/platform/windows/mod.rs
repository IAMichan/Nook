//! Windows: UI Automation en OCR voor het scherm, de mediabediening van het systeem (GSMTC), Core Audio voor het
//! volume, het Startmenu voor apps, Windows Search voor bestanden, en de spraak van Windows.

mod media;
mod screen;
mod speech;
mod system;

pub use media::WindowsMedia;
pub use screen::WindowsScreen;
pub use speech::{WindowsDictation, WindowsSpeech, WindowsWake};
pub use system::WindowsSystem;
