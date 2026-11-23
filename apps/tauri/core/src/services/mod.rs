//! Platformdiensten zonder platform: wat scherm lezen, muziek, stem, Flow, de Notetaker, meedenken en het
//! weekoverzicht op elk besturingssysteem hetzelfde doen. De platformlaag (`src-tauri/src/platform`) levert de
//! ruwe gegevens (vensters, audio, spelers); hier zitten de regels, met tests.

pub mod app_catalog;
pub mod attention;
pub mod audio;
pub mod autocomplete;
pub mod buddy;
pub mod deep_link;
pub mod dictation_context;
pub mod dictation_lang;
pub mod double_tap_suggest;
pub mod energy;
pub mod files;
pub mod flow;
pub mod flow_hold;
pub mod fuzzy;
pub mod lyrics;
pub mod music;
pub mod music_history;
pub mod user_scripts;
pub mod nook_telemetry;
pub mod notes;
pub mod notice_log;
pub mod notice_pacer;
pub mod notice_rules;
pub mod nudge_filter;
pub mod prefs;
pub mod quiet;
pub mod recap;
pub mod rewrite;
pub mod screen;
pub mod sounds;
pub mod spoken;
pub mod spotify;
pub mod telemetry;

pub mod think_along;
pub mod toast;
pub mod transcribe;
pub mod vad;
pub mod wake_gate;
