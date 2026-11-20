//! De werkruimte: sessies die Nook zelf draait (Claude Code, Codex, …), git, terminals en de brug waarmee agents
//! Nooks terminal, browser en pull requests gebruiken. Zoals `Services/Workspace` op de Mac.

pub mod acp;
pub mod antigravity;
pub mod antigravity_install;
pub mod arrivals;
pub mod attention;
pub mod autonomy;
pub mod bridge;
pub mod bridge_nook;
pub mod bridge_sessions;
pub mod browser;
pub mod browser_script;
pub mod clone_progress;
pub mod codex_app_server;
pub mod command;
pub mod delegation;
pub mod driver;
pub mod favicon;
#[cfg(all(test, unix))]
mod e2e_automation_tests;
pub mod git;
pub mod handoff;
pub mod limits;
pub mod manager;
pub mod model_manifest;
pub mod models;
pub mod nook_schedule;
pub mod open_in;
pub mod parsers;
pub mod paths;
pub mod project_files;
pub mod queue;
pub mod resources;
pub mod rollback;
pub mod schedule;
pub mod scratch;
pub mod scheduler;
pub mod settings;
pub mod skills;
pub mod source_control;
pub mod store;
pub mod terminal;
pub mod titles;
pub mod traffic;
pub mod webhook;
