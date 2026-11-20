//! Where a session's folder opens (Settings › Sessions › Editor & browser, `editorBundleID` on the Mac): the file
//! manager, or an editor found on this computer. Editors are found by their command on the PATH.

use serde::Serialize;

/// An editor Nook can open a folder in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Editor {
    /// The command, also what is stored ("code").
    pub id: &'static str,
    pub name: &'static str,
}

/// The editors Nook knows, in the Mac's order where it has them.
pub const CANDIDATES: [Editor; 6] = [
    Editor { id: "code", name: "Visual Studio Code" },
    Editor { id: "cursor", name: "Cursor" },
    Editor { id: "windsurf", name: "Windsurf" },
    Editor { id: "zed", name: "Zed" },
    Editor { id: "idea", name: "IntelliJ IDEA" },
    Editor { id: "subl", name: "Sublime Text" },
];

/// The full path of `command` on the PATH (with Windows' `.cmd`/`.exe`), if it is there.
pub fn find(command: &str, path_var: &str) -> Option<std::path::PathBuf> {
    let exts: &[&str] = if cfg!(windows) { &[".cmd", ".exe", ".bat"] } else { &[""] };
    std::env::split_paths(path_var).find_map(|dir| exts.iter().map(|e| dir.join(format!("{command}{e}"))).find(|p| p.is_file()))
}

/// The editors on this computer.
pub fn installed() -> Vec<Editor> {
    let path = std::env::var("PATH").unwrap_or_default();
    CANDIDATES.iter().filter(|e| find(e.id, &path).is_some()).cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_nothing_on_an_empty_path() {
        assert!(find("code", "").is_none());
        assert_eq!(CANDIDATES[0].id, "code");
    }
}
