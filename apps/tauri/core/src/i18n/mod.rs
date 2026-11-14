//! The language of text Nook writes on the Rust side (error messages, notifications, menus), the same five as the
//! interface and as `AppLanguage` on the Mac: English, Dutch, German, French, and Spanish.
//!
//! Write each visible string as `tr("Nederlands", "English")`. With values, use `{name}` placeholders and `trf`:
//! `trf("{n} bestanden", "{n} files", &[("n", &count)])`. German, French, and Spanish come from the tables in
//! `catalog/*.rs`, keyed by the English text; `i18n::tests` fails when an English text in the sources has no entry.
//! The language follows `Settings::app_language` (set when settings are loaded or saved), so no caller passes it.

mod catalog;

use std::collections::HashMap;
use std::fmt::Display;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::OnceLock;

/// One row of a catalog: English, German, French, Spanish.
pub type Row = (&'static str, &'static str, &'static str, &'static str);

const CODES: [&str; 5] = ["en", "nl", "de", "fr", "es"];
static LANGUAGE: AtomicU8 = AtomicU8::new(0);

/// Sets the language for everything Nook writes from now on. Unknown codes mean English.
pub fn set_language(code: &str) {
    let index = CODES.iter().position(|c| *c == code).unwrap_or(0);
    LANGUAGE.store(index as u8, Ordering::Relaxed);
}

/// The current language code.
pub fn language() -> &'static str {
    CODES[LANGUAGE.load(Ordering::Relaxed) as usize % CODES.len()]
}

fn table() -> &'static HashMap<&'static str, (&'static str, &'static str, &'static str)> {
    static TABLE: OnceLock<HashMap<&'static str, (&'static str, &'static str, &'static str)>> = OnceLock::new();
    TABLE.get_or_init(|| catalog::ALL.iter().flat_map(|t| t.iter()).map(|&(en, de, fr, es)| (en, (de, fr, es))).collect())
}

/// The text for `code` from its Dutch and English source; German, French, and Spanish from the catalog, else English.
pub fn translate(code: &str, nl: &'static str, en: &'static str) -> &'static str {
    match code {
        "nl" => nl,
        "de" | "fr" | "es" => match table().get(en) {
            Some(&(de, fr, es)) => match code {
                "de" => de,
                "fr" => fr,
                _ => es,
            },
            None => en,
        },
        _ => en,
    }
}

/// A fixed text in the current language.
pub fn tr(nl: &'static str, en: &'static str) -> &'static str {
    translate(language(), nl, en)
}

/// A text with `{name}` placeholders in the current language.
pub fn trf(nl: &'static str, en: &'static str, vars: &[(&str, &dyn Display)]) -> String {
    fill(tr(nl, en), vars)
}

/// Fills `{name}` placeholders; unknown names stay as they are.
pub fn fill(text: &str, vars: &[(&str, &dyn Display)]) -> String {
    let mut out = String::with_capacity(text.len() + 16);
    let mut rest = text;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('}') {
            Some(close) if after[..close].chars().all(|c| c.is_alphanumeric() || c == '_') && close > 0 => {
                let name = &after[..close];
                match vars.iter().find(|(k, _)| *k == name) {
                    Some((_, v)) => out.push_str(&v.to_string()),
                    None => out.push_str(&rest[open..open + close + 2]),
                }
                rest = &after[close + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests;
