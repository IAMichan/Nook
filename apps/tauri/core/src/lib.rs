//! De kern van Nook voor Windows, Linux en Android (en later macOS/iOS via Tauri).
//!
//! Alles hier is platformonafhankelijk. Wat per platform verschilt (geheimen, scherm lezen, muziek, sneltoetsen)
//! staat achter een trait in [`platform`] en wordt in `src-tauri/src/platform` per besturingssysteem ingevuld.
//! De Swift-code in `apps/macos` is de specificatie: namen en gedrag volgen die zo veel mogelijk.

pub mod attachments;
pub mod brain;
pub mod companion;
pub mod connectors;
pub mod error;
pub mod nooks;
pub mod paths;
pub mod platform;
pub mod provider;
pub mod secrets;
pub mod services;
pub mod settings;
pub mod store;

pub use error::{NookError, Result};
