//! Sessions without a project (`ScratchProjects` on the Mac): "or start without a project" in the new-session screen
//! starts the agent in an empty folder of its own under ~/.nook/scratch, named after the day and the prompt
//! ("2026-11-04-fix-the-login-a1b2c3"). "Turn into project" later keeps it as a regular project.

use std::path::{Path, PathBuf};

use uuid::Uuid;

use super::bridge_sessions::scratch_folder_name;

/// Where the folders of sessions without a project live.
pub fn root() -> PathBuf {
    crate::paths::dot_nook().join("scratch")
}

/// True for a folder Nook made for a session without a project (directly in `root`).
pub fn is_scratch_in(path: &str, root: &Path) -> bool {
    let trimmed = path.trim_end_matches(['/', '\\']);
    if trimmed.is_empty() {
        return false;
    }
    Path::new(trimmed).parent().is_some_and(|p| p == root)
}

pub fn is_scratch(path: &str) -> bool {
    is_scratch_in(path, &root())
}

/// Makes a new, empty folder for a session without a project and returns its path.
pub fn create_in(root: &Path, prompt: &str, day: &str, id: Uuid) -> std::io::Result<String> {
    let dir = root.join(scratch_folder_name(day, prompt, id));
    std::fs::create_dir_all(&dir)?;
    Ok(dir.to_string_lossy().into_owned())
}

pub fn create(prompt: &str) -> std::io::Result<String> {
    let day = chrono::Local::now().format("%Y-%m-%d").to_string();
    create_in(&root(), prompt, &day, Uuid::new_v4())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn makes_and_recognizes_a_scratch_folder() {
        let root = std::env::temp_dir().join(format!("nook-scratch-{}", Uuid::new_v4()));
        let id = Uuid::parse_str("a1b2c3d4-0000-0000-0000-000000000000").unwrap();
        let dir = create_in(&root, "Fix the login bug", "2026-11-04", id).unwrap();
        assert!(Path::new(&dir).is_dir());
        assert!(dir.ends_with("2026-11-04-fix-the-login-bug-a1b2c3"));
        assert!(is_scratch_in(&dir, &root));
        assert!(is_scratch_in(&format!("{dir}/"), &root));
        assert!(!is_scratch_in(&root.to_string_lossy(), &root));
        assert!(!is_scratch_in(&format!("{dir}/src"), &root));
        assert!(!is_scratch_in("", &root));
        let _ = std::fs::remove_dir_all(&root);
    }
}
