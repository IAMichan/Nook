//! German, French, and Spanish for every `tr`/`trf` on the Rust side, keyed by the English text. Each area keeps its
//! own file; add a new one to `ALL`. Rows are `(English, German, French, Spanish)`.

use super::Row;

mod base;
mod maintenance;
mod nook_tools;

pub const ALL: &[&[Row]] = &[base::ROWS, maintenance::ROWS, nook_tools::ROWS];
