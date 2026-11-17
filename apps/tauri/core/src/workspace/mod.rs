//! De werkruimte: sessies die Nook zelf draait (Claude Code, Codex, …), git, terminals en de brug waarmee agents
//! Nooks terminal, browser en pull requests gebruiken. Zoals `Services/Workspace` op de Mac.

pub mod acp;
pub mod antigravity;
pub mod arrivals;
pub mod attention;
pub mod autonomy;
pub mod bridge;
pub mod bridge_nook;
pub mod bridge_sessions;
pub mod browser;
pub mod browser_script;
pub mod codex_app_server;
pub mod command;
pub mod delegation;
pub mod driver;
#[cfg(all(test, unix))]
mod e2e_automation_tests;
pub mod git;
pub mod handoff;
pub mod limits;
pub mod manager;
pub mod models;
pub mod nook_schedule;
pub mod parsers;
pub mod paths;
pub mod queue;
pub mod schedule;
pub mod scheduler;
pub mod settings;
pub mod source_control;
pub mod store;
pub mod terminal;
pub mod titles;
pub mod webhook;
