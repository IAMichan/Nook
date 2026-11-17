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
    let bad: Vec<String> = uses()
        .into_iter()
        .filter(|(_, nl, en)| placeholders(nl) != placeholders(en))
        .map(|(f, nl, en)| format!("{f}: {nl} | {en}"))
        .collect();
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

// MARK: Dutch text outside tr/trf (FD-04 in docs/WINDOWS-PARITY.md)

/// Files whose Dutch string literals are data, not text Nook shows: keyword patterns that read what the user typed,
/// and the Dutch documents and questions of the local quality check.
const DUTCH_ON_PURPOSE: &[&str] =
    &["core/src/brain/intent.rs", "core/src/brain/local_intent.rs", "core/src/brain/message_trust.rs", "core/src/brain/quality.rs"];

/// Dutch string literals each file still has outside `tr`/`trf`, from before the Rust side spoke five languages.
/// The numbers only go down: wrap the text in `tr("Nederlands", "English")` with a catalog row and lower the number
/// (or drop the row at zero). New code writes `tr`/`trf` from the start, so a file that is not listed here has none.
const DUTCH_LEFT: &[(&str, usize)] = &[
    ("core/src/agents/hub.rs", 12),
    ("core/src/agents/installer.rs", 6),
    ("core/src/agents/ipc.rs", 1),
    ("core/src/agents/models.rs", 2),
    ("core/src/agents/risk.rs", 27),
    ("core/src/attachments.rs", 6),
    ("core/src/brain/action_gate.rs", 10),
    ("core/src/brain/claude_code.rs", 4),
    ("core/src/brain/conversations.rs", 4),
    ("core/src/brain/follow_ups.rs", 1),
    ("core/src/brain/http.rs", 7),
    ("core/src/brain/memory.rs", 3),
    ("core/src/brain/model_download.rs", 4),
    ("core/src/brain/network_guard.rs", 2),
    ("core/src/brain/profile.rs", 3),
    ("core/src/brain/research.rs", 4),
    ("core/src/brain/retrieval.rs", 4),
    ("core/src/brain/service.rs", 9),
    ("core/src/brain/sources.rs", 5),
    ("core/src/brain/suggestions.rs", 28),
    ("core/src/brain/undo.rs", 1),
    ("core/src/brain/weather.rs", 2),
    ("core/src/brain/web.rs", 3),
    ("core/src/companion/client.rs", 19),
    ("core/src/companion/remote_digest.rs", 1),
    ("core/src/companion/seal.rs", 1),
    ("core/src/companion/server.rs", 3),
    ("core/src/companion/transport.rs", 1),
    ("core/src/connectors/actions.rs", 1),
    ("core/src/connectors/brand.rs", 1),
    ("core/src/connectors/cloud.rs", 19),
    ("core/src/connectors/custom.rs", 3),
    ("core/src/connectors/feeds.rs", 4),
    ("core/src/connectors/github.rs", 12),
    ("core/src/connectors/gitlab.rs", 4),
    ("core/src/connectors/mcp/connector.rs", 3),
    ("core/src/connectors/mcp/mod.rs", 3),
    ("core/src/connectors/mcp/transport.rs", 6),
    ("core/src/connectors/mod.rs", 7),
    ("core/src/connectors/oauth.rs", 14),
    ("core/src/connectors/pulls.rs", 9),
    ("core/src/connectors/whatsapp/link.rs", 12),
    ("core/src/platform.rs", 10),
    ("core/src/services/autocomplete/engine.rs", 3),
    ("core/src/services/files.rs", 2),
    ("core/src/services/quiet.rs", 3),
    ("core/src/services/rewrite.rs", 4),
    ("core/src/services/screen.rs", 1),
    ("core/src/services/think_along.rs", 1),
    ("core/src/services/transcribe.rs", 1),
    ("core/src/workspace/git.rs", 8),
    ("core/src/workspace/limits.rs", 1),
    ("core/src/workspace/models.rs", 5),
    ("core/src/workspace/parsers.rs", 4),
    ("core/src/workspace/paths.rs", 3),
    ("core/src/workspace/source_control.rs", 8),
    ("src-tauri/src/agents/mod.rs", 3),
    ("src-tauri/src/agents/terminal.rs", 8),
    ("src-tauri/src/commands/agents.rs", 5),
    ("src-tauri/src/commands/brain.rs", 6),
    ("src-tauri/src/commands/chat.rs", 24),
    ("src-tauri/src/commands/companion.rs", 2),
    ("src-tauri/src/commands/connectors.rs", 22),
    ("src-tauri/src/commands/mod.rs", 1),
    ("src-tauri/src/commands/plans.rs", 3),
    ("src-tauri/src/commands/services.rs", 2),
    ("src-tauri/src/commands/whatsapp.rs", 9),
    ("src-tauri/src/commands/workspace_tools.rs", 2),
    ("src-tauri/src/companion/backend.rs", 6),
    ("src-tauri/src/companion/poll.rs", 1),
    ("src-tauri/src/lib.rs", 1),
    ("src-tauri/src/platform/android.rs", 8),
    ("src-tauri/src/platform/audio.rs", 8),
    ("src-tauri/src/platform/desktop.rs", 3),
    ("src-tauri/src/platform/linux/apps.rs", 1),
    ("src-tauri/src/platform/linux/atspi.rs", 1),
    ("src-tauri/src/platform/linux/mod.rs", 14),
    ("src-tauri/src/platform/linux/mpris.rs", 2),
    ("src-tauri/src/platform/linux/speech.rs", 1),
    ("src-tauri/src/platform/linux/x11.rs", 4),
    ("src-tauri/src/platform/mod.rs", 12),
    ("src-tauri/src/platform/process.rs", 2),
    ("src-tauri/src/platform/secrets.rs", 1),
    ("src-tauri/src/platform/windows/autocomplete.rs", 1),
    ("src-tauri/src/platform/windows/screen.rs", 3),
    ("src-tauri/src/platform/windows/speech.rs", 5),
    ("src-tauri/src/platform/windows/system.rs", 7),
    ("src-tauri/src/services/autocomplete.rs", 2),
    ("src-tauri/src/services/flow.rs", 2),
    ("src-tauri/src/services/mod.rs", 1),
    ("src-tauri/src/services/notes.rs", 5),
    ("src-tauri/src/services/part.rs", 1),
    ("src-tauri/src/services/screen.rs", 2),
    ("src-tauri/src/services/think.rs", 4),
    ("src-tauri/src/services/voice.rs", 9),
    ("src-tauri/src/tools/clipboard.rs", 2),
    ("src-tauri/src/tools/connectors.rs", 2),
    ("src-tauri/src/tools/files.rs", 1),
    ("src-tauri/src/tools/loops.rs", 1),
    ("src-tauri/src/tools/mail.rs", 2),
    ("src-tauri/src/tools/memory.rs", 4),
    ("src-tauri/src/tools/mod.rs", 1),
    ("src-tauri/src/tools/screen.rs", 2),
    ("src-tauri/src/workspace/bridge.rs", 5),
    ("src-tauri/src/workspace/browser.rs", 3),
    ("src-tauri/src/workspace/mod.rs", 2),
    ("src-tauri/src/workspace/terminals.rs", 3),
];

/// Words that only Dutch uses among Nook's languages; two of them make a literal Dutch.
const DUTCH_WORDS: &str = r"(?i)\b(niet|geen|een|het|je|jouw|kon|kan|naar|wordt|zijn|deze|dit|bestaat|gevonden|mislukt|ongeldig|opnieuw|probeer|staat|sleutel|bestand|gesprek|sessie|antwoord|fout|nog|ook|alleen|wil|moet|bij|uit|er|van|met|dat|wat|hier|lukt|lukte|werkt|wacht|kies|klik)\b";

/// How many Dutch literals each Rust file has outside `tr`/`trf`, comments and its `mod tests`.
fn dutch_literals() -> std::collections::BTreeMap<String, Vec<String>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let mut files = Vec::new();
    rust_files(&root.join("core/src"), &mut files);
    rust_files(&root.join("src-tauri/src"), &mut files);
    let lit = r#""((?:[^"\\]|\\.)*)""#;
    let translated = regex::Regex::new(&format!(r#"\btrf?\(\s*{lit}"#)).unwrap();
    let literal = regex::Regex::new(lit).unwrap();
    let tests = regex::Regex::new(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{").unwrap();
    let dutch = regex::Regex::new(DUTCH_WORDS).unwrap();
    let mut out = std::collections::BTreeMap::new();
    for file in files {
        let name = file.strip_prefix(&root).unwrap().to_string_lossy().replace('\\', "/");
        if DUTCH_ON_PURPOSE.contains(&name.as_str()) {
            continue;
        }
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        let text = &text[..tests.find(&text).map_or(text.len(), |m| m.start())];
        // The Dutch half of every tr/trf is meant to be there.
        let text = translated.replace_all(text, "tr(\"\"");
        let mut found = Vec::new();
        for line in text.lines() {
            let line = line.trim_start();
            if line.starts_with("//") {
                continue;
            }
            for c in literal.captures_iter(&line.replace("'\"'", "")) {
                if dutch.find_iter(&c[1]).count() >= 2 {
                    found.push(c[1].to_string());
                }
            }
        }
        if !found.is_empty() {
            out.insert(name, found);
        }
    }
    out
}

#[test]
fn no_new_dutch_text_outside_tr() {
    let found = dutch_literals();
    let left: std::collections::BTreeMap<&str, usize> = DUTCH_LEFT.iter().copied().collect();
    let mut problems = Vec::new();
    for (file, texts) in &found {
        let allowed = left.get(file.as_str()).copied().unwrap_or(0);
        if texts.len() > allowed {
            problems.push(format!(
                "{file}: {} Dutch texts outside tr/trf, {allowed} allowed. Write them as tr(\"Nederlands\", \"English\"):\n  {}",
                texts.len(),
                texts.join("\n  ")
            ));
        }
    }
    for (file, allowed) in &left {
        let now = found.get(*file).map_or(0, Vec::len);
        if now < *allowed {
            problems.push(format!("{file}: {now} Dutch texts left, the list says {allowed}. Lower it in DUTCH_LEFT."));
        }
    }
    let table: Vec<String> = found.iter().map(|(f, t)| format!("    (\"{f}\", {}),", t.len())).collect();
    assert!(problems.is_empty(), "{}\n\nDUTCH_LEFT as it is now:\n{}", problems.join("\n"), table.join("\n"));
}

#[test]
fn spots_dutch_but_not_english() {
    let dutch = regex::Regex::new(DUTCH_WORDS).unwrap();
    assert!(dutch.find_iter("Deze sessie bestaat niet meer.").count() >= 2);
    assert!(dutch.find_iter("Git is niet gevonden.").count() >= 2);
    assert!(dutch.find_iter("This session no longer exists.").count() < 2);
    assert!(dutch.find_iter("Pick a model with tools, or switch to another brain.").count() < 2);
}

#[test]
fn picks_the_language_and_fills_values() {
    assert_eq!(translate("nl", "Open Nook", "Open Nook"), "Open Nook");
    assert_eq!(translate("de", "Open Nook", "Open Nook"), "Nook öffnen");
    assert_eq!(translate("fr", "x", "Nobody translated this"), "Nobody translated this");
    assert_eq!(fill("{n} files in {dir}", &[("n", &3), ("dir", &"src")]), "3 files in src");
    assert_eq!(fill("keep {unknown} and {", &[]), "keep {unknown} and {");
}
