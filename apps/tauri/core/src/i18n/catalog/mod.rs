//! German, French, and Spanish for every `tr`/`trf` on the Rust side, keyed by the English text. Each area keeps its
//! own file; add a new one to `ALL`. Rows are `(English, German, French, Spanish)`.

use super::Row;

mod automation;
mod base;
mod maintenance;
mod nook_tools;
mod workspace_agents;

pub const ALL: &[&[Row]] = &[automation::ROWS, base::ROWS, maintenance::ROWS, nook_tools::ROWS, workspace_agents::ROWS];
