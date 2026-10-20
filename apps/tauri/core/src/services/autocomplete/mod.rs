//! Autocomplete Anywhere: while you type in any app, a local model suggests how your sentence goes on, as gray ghost
//! text at the cursor. This is the platform-free part, ported from the Foundation-only Swift in
//! `apps/macos/Services/Autocomplete` (see `docs/AUTOCOMPLETE.md`):
//!
//! - [`suggestion`]: making a suggestion from the model's answer, accepting words, typing through.
//! - [`prompt`]: what the model reads (context fixed per field, sliding window, chat templates, control-token scrub).
//! - [`privacy`]: secrets taken out before text goes to a model.
//! - [`prefs`]: settings, per-app and per-site rules, and the apps that are off by default.
//! - [`stats`]: aggregate counts only, never text.
//! - [`session`]: the suggestion on screen and what keys and reads do to it.
//! - [`emoji`]: the emoji picker (names in Dutch and English, emoji that fit the text, usage counts).
//! - [`engine`]: the local server (Ollama, LM Studio) or, when explicitly chosen, the external brain.
//!
//! The platform layer (`src-tauri/src/platform`) watches keys, reads the focused field, draws the ghost text and types
//! accepted words. Nothing here writes typed text to disk or logs.

pub mod emoji;
pub mod engine;
pub mod prefs;
pub mod privacy;
pub mod prompt;
pub mod session;
pub mod stats;
pub mod suggestion;

pub use prefs::AutocompleteSettings;
