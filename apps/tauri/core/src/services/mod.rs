//! Platformdiensten zonder platform: wat scherm lezen, muziek, stem, Flow, de Notetaker, meedenken en het
//! weekoverzicht op elk besturingssysteem hetzelfde doen. De platformlaag (`src-tauri/src/platform`) levert de
//! ruwe gegevens (vensters, audio, spelers); hier zitten de regels, met tests.

pub mod app_catalog;
pub mod audio;
pub mod autocomplete;
pub mod double_tap_suggest;
pub mod energy;
pub mod files;
pub mod flow;
pub mod fuzzy;
pub mod notes;
pub mod notice_rules;
pub mod prefs;
pub mod quiet;
pub mod recap;
pub mod rewrite;
pub mod screen;
pub mod sounds;
pub mod spoken;
pub mod lyrics;
pub mod nudge_filter;
pub mod think_along;
pub mod toast;
pub mod transcribe;
pub mod vad;
