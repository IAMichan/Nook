//! Platformdiensten zonder platform: wat scherm lezen, muziek, stem, Flow, de Notetaker, meedenken en het
//! weekoverzicht op elk besturingssysteem hetzelfde doen. De platformlaag (`src-tauri/src/platform`) levert de
//! ruwe gegevens (vensters, audio, spelers); hier zitten de regels, met tests.

pub mod audio;
pub mod energy;
pub mod files;
pub mod flow;
pub mod fuzzy;
pub mod notes;
pub mod prefs;
pub mod quiet;
pub mod recap;
pub mod rewrite;
pub mod screen;
pub mod sounds;
pub mod spoken;
pub mod think_along;
pub mod transcribe;
pub mod vad;
