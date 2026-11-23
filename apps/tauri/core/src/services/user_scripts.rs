//! The user's own scripts Nook may run, after an OK, as the Mac runs a shortcut from the Shortcuts app (`run_shortcut`).
//! Windows has no Shortcuts app, so they live in one folder of their own, `Scripts` in Nook's data folder: a PowerShell
//! script (`.ps1`), a batch file (`.bat`, `.cmd`), a Windows shortcut (`.lnk`, which starts what it points at) or, on
//! Linux and macOS, a shell script (`.sh`). Only files directly in that folder are found, by their name without the
//! extension, so a name from the model can never reach anywhere else.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::paths;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ScriptKind {
    PowerShell,
    Batch,
    Link,
    Shell,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserScript {
    pub name: String,
    pub path: PathBuf,
    pub kind: ScriptKind,
}

/// How long a script may run before Nook stops waiting for it.
pub const TIMEOUT_SECS: u64 = 120;
/// How much of a script's output goes back to the model.
pub const OUTPUT_LIMIT: usize = 4000;

pub fn folder() -> PathBuf {
    paths::support_directory().join("Scripts")
}

fn kind_of(path: &Path) -> Option<ScriptKind> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "ps1" => Some(ScriptKind::PowerShell),
        "bat" | "cmd" => Some(ScriptKind::Batch),
        "lnk" => Some(ScriptKind::Link),
        "sh" => Some(ScriptKind::Shell),
        _ => None,
    }
}

/// The scripts in `dir`, by name.
pub fn list_in(dir: &Path) -> Vec<UserScript> {
    let mut found: Vec<UserScript> = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.is_file())
                .filter_map(|path| {
                    let kind = kind_of(&path)?;
                    let name = path.file_stem()?.to_string_lossy().into_owned();
                    Some(UserScript { name, path, kind })
                })
                .collect()
        })
        .unwrap_or_default();
    found.sort_by_key(|s| s.name.to_lowercase());
    found
}

pub fn list() -> Vec<UserScript> {
    list_in(&folder())
}

/// The script called `name` (without its extension, case does not matter).
pub fn find_in(dir: &Path, name: &str) -> Option<UserScript> {
    let wanted = name.trim().to_lowercase();
    let wanted = wanted
        .rsplit_once('.')
        .filter(|(_, ext)| ["ps1", "bat", "cmd", "lnk", "sh"].contains(ext))
        .map(|(stem, _)| stem.to_string())
        .unwrap_or(wanted);
    list_in(dir).into_iter().find(|s| s.name.to_lowercase() == wanted)
}

/// The program and its arguments that run a script; None for a shortcut, which the system opens.
pub fn command(script: &UserScript) -> Option<(String, Vec<String>)> {
    let path = script.path.to_string_lossy().into_owned();
    match script.kind {
        ScriptKind::PowerShell => Some((
            "powershell.exe".into(),
            vec!["-NoProfile".into(), "-NonInteractive".into(), "-ExecutionPolicy".into(), "Bypass".into(), "-File".into(), path],
        )),
        ScriptKind::Batch => Some(("cmd.exe".into(), vec!["/C".into(), path])),
        ScriptKind::Shell => Some(("sh".into(), vec![path])),
        ScriptKind::Link => None,
    }
}

/// What the model hears back: how it ended and the end of what it printed.
pub fn report(name: &str, code: Option<i32>, stdout: &str, stderr: &str) -> String {
    let mut out = match code {
        Some(0) => format!("Script {name} ran."),
        Some(code) => format!("Script {name} ended with exit code {code}."),
        None => format!("Script {name} was stopped."),
    };
    for (label, text) in [("Output", stdout), ("Errors", stderr)] {
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let start = text.char_indices().rev().nth(OUTPUT_LIMIT.saturating_sub(1)).map(|(i, _)| i).unwrap_or(0);
        out.push_str(&format!("\n{label}:\n{}", &text[start..]));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_scripts_by_name_only_in_the_folder() {
        let dir = std::env::temp_dir().join(format!("nook-scripts-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        for f in ["Backup.ps1", "lights.cmd", "Spotify.lnk", "notes.txt", "sub/hidden.ps1"] {
            std::fs::write(dir.join(f), b"").unwrap();
        }
        let names: Vec<_> = list_in(&dir).into_iter().map(|s| s.name).collect();
        assert_eq!(names, vec!["Backup", "lights", "Spotify"]);
        assert_eq!(find_in(&dir, "backup").map(|s| s.kind), Some(ScriptKind::PowerShell));
        assert_eq!(find_in(&dir, "Backup.ps1").map(|s| s.name), Some("Backup".into()));
        assert!(find_in(&dir, "../Backup").is_none());
        assert!(find_in(&dir, "hidden").is_none());
        assert!(find_in(&dir, "notes").is_none());
        let script = find_in(&dir, "lights").unwrap();
        assert_eq!(command(&script).unwrap().0, "cmd.exe");
        assert!(command(&find_in(&dir, "spotify").unwrap()).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reports_the_exit_and_the_end_of_the_output() {
        assert_eq!(report("x", Some(0), "", ""), "Script x ran.");
        let long = "a".repeat(OUTPUT_LIMIT + 50);
        let r = report("x", Some(2), &long, "boom");
        assert!(r.starts_with("Script x ended with exit code 2."));
        assert!(r.contains("Errors:\nboom"));
        assert!(r.len() < OUTPUT_LIMIT + 120);
    }
}
