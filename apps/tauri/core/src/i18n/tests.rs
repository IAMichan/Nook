//! The Rust counterpart of `src/lib/i18n.test.ts`: every `tr`/`trf` in the Rust sources has German, French, and
//! Spanish, and every translation keeps the English text's `{placeholders}`.

use super::*;
use std::path::{Path, PathBuf};

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().is_some_and(|n| n == "i18n" || n == "target" || n == "gen") {
                continue;
            }
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// `(file, dutch, english)` for every `tr("…", "…")` and `trf("…", "…"` in the core and the app.
fn uses() -> Vec<(String, String, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let mut files = Vec::new();
    rust_files(&root.join("core/src"), &mut files);
    rust_files(&root.join("src-tauri/src"), &mut files);
    let lit = r#""((?:[^"\\]|\\.)*)""#;
    let call = regex::Regex::new(&format!(r#"\btrf?\(\s*{lit}\s*,\s*{lit}"#)).unwrap();
    let mut out = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        for c in call.captures_iter(&text) {
            out.push((file.display().to_string(), unescape(&c[1]), unescape(&c[2])));
        }
    }
    out
}

fn unescape(s: &str) -> String {
    s.replace("\\\"", "\"").replace("\\n", "\n").replace("\\\\", "\\")
}

fn placeholders(s: &str) -> Vec<String> {
    let re = regex::Regex::new(r"\{(\w+)\}").unwrap();
    let mut v: Vec<String> = re.captures_iter(s).map(|c| c[1].to_string()).collect();
    v.sort();
    v
}

#[test]
fn every_english_text_has_german_french_and_spanish() {
    let missing: Vec<String> =
        uses().into_iter().filter(|(_, _, en)| !table().contains_key(en.as_str())).map(|(f, _, en)| format!("{f}: {en}")).collect();
    assert!(missing.is_empty(), "missing translations:\n{}", missing.join("\n"));
}

#[test]
fn dutch_and_english_share_placeholders() {
    let bad: Vec<String> =
        uses().into_iter().filter(|(_, nl, en)| placeholders(nl) != placeholders(en)).map(|(f, nl, en)| format!("{f}: {nl} | {en}")).collect();
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

#[test]
fn translations_keep_placeholders() {
    let mut bad = Vec::new();
    for rows in catalog::ALL {
        for (en, de, fr, es) in rows.iter() {
            for t in [de, fr, es] {
                if placeholders(t) != placeholders(en) {
                    bad.push(format!("{en} → {t}"));
                }
            }
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

#[test]
fn picks_the_language_and_fills_values() {
    assert_eq!(translate("nl", "Open Nook", "Open Nook"), "Open Nook");
    assert_eq!(translate("de", "Open Nook", "Open Nook"), "Nook öffnen");
    assert_eq!(translate("fr", "x", "Nobody translated this"), "Nobody translated this");
    assert_eq!(fill("{n} files in {dir}", &[("n", &3), ("dir", &"src")]), "3 files in src");
    assert_eq!(fill("keep {unknown} and {", &[]), "keep {unknown} and {");
}
