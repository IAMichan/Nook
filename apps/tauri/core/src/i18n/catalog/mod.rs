//! German, French, and Spanish for every `tr`/`trf` on the Rust side, keyed by the English text. Rows are
//! `(English, German, French, Spanish)` in a `pub const ROWS: &[Row]` per file.
//!
//! Every `*.rs` file in this folder is picked up by `build.rs`; there is no list to edit. Give a new feature its own
//! file instead of appending to an existing one, so parallel pull requests don't collide at the end of the same file.

use super::Row;

include!(concat!(env!("OUT_DIR"), "/i18n_catalogs.rs"));
