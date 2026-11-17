//! German, French, and Spanish for every `tr`/`trf` on the Rust side, keyed by the English text. Each area keeps its
//! own file; add a new one to `ALL`. Rows are `(English, German, French, Spanish)`.

use super::Row;

mod automation;
mod base;
mod companion_home;
mod maintenance;
mod nook_tools;
mod openrouter;
mod workspace_agents;
mod workspace_sessions;

pub const ALL: &[&[Row]] = &[
    automation::ROWS,
    base::ROWS,
    companion_home::ROWS,
    maintenance::ROWS,
    nook_tools::ROWS,
    openrouter::ROWS,
    workspace_agents::ROWS,
    workspace_sessions::ROWS,
];
