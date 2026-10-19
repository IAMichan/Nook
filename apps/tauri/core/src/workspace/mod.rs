//! De werkruimte: sessies die Nook zelf draait (Claude Code, Codex, …), git, terminals en de brug waarmee agents
//! Nooks terminal, browser en pull requests gebruiken. Zoals `Services/Workspace` op de Mac.

pub mod attention;
pub mod bridge;
pub mod command;
pub mod git;
pub mod limits;
pub mod manager;
pub mod models;
pub mod parsers;
pub mod paths;
pub mod queue;
pub mod settings;
pub mod source_control;
pub mod store;
pub mod terminal;
