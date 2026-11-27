//! The projects half of the first-run flow's "Coding agents" step (`AgentReadiness.projectCandidates` on the Mac): which
//! folders you worked in recently that could become projects. Whether each agent is ready is decided in the view
//! (`src/lib/agent-readiness.ts`), from what it already reads. The folder check comes in as a closure, so tests use it
//! without a disk.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

// Projects

/// A folder you worked in recently, as a project you could add.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCandidate {
    /// The repository's root folder.
    pub path: String,
    pub name: String,
    /// The folder it is in, for the line under the name.
    pub parent: String,
    /// How many sessions worked in it within the window.
    pub sessions: usize,
    pub last_active: DateTime<Utc>,
    /// Already one of Nook's projects (favorite or recent).
    pub added: bool,
}

/// One session's folder and when it was last active.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionFolder {
    pub folder: String,
    pub date: DateTime<Utc>,
}

pub const RECENT_DAYS: i64 = 30;
pub const LIMIT: usize = 8;

/// A folder without trailing separators; the root of a drive or `/` stays as it is.
pub fn normalize(path: &str) -> String {
    let trimmed = path.trim();
    let cut = trimmed.trim_end_matches(['/', '\\']);
    if cut.is_empty() || cut.ends_with(':') {
        trimmed.to_string()
    } else {
        cut.to_string()
    }
}

/// Folders compare the way the platform does: Windows paths ignore case and separator style.
fn key(path: &str) -> String {
    let p = normalize(path);
    if p.contains('\\') || p.as_bytes().get(1) == Some(&b':') {
        p.replace('/', "\\").to_lowercase()
    } else {
        p
    }
}

/// The git repositories you worked in during the last 30 days, most recently used first: every session's folder is
/// taken up to its repository's root (`git_root`), so two subfolders of one checkout count once. Folders that are not
/// in a repository, the home folder and sessions outside the window are left out.
pub fn project_candidates(
    sessions: &[SessionFolder],
    known: &[String],
    home: &str,
    now: DateTime<Utc>,
    limit: usize,
    mut git_root: impl FnMut(&str) -> Option<String>,
) -> Vec<ProjectCandidate> {
    let cutoff = now - Duration::days(RECENT_DAYS);
    let known: HashSet<String> = known.iter().map(|k| key(k)).collect();
    let home_key = key(home);
    let mut by_root: HashMap<String, (String, usize, DateTime<Utc>)> = HashMap::new();
    let mut root_of: HashMap<String, Option<String>> = HashMap::new();
    for session in sessions {
        if session.date < cutoff || session.date > now {
            continue;
        }
        let folder = normalize(&session.folder);
        let folder_key = key(&folder);
        if folder.is_empty() || folder_key == home_key || folder == "/" {
            continue;
        }
        let root = root_of.entry(folder_key).or_insert_with(|| git_root(&folder).map(|r| normalize(&r))).clone();
        let Some(root) = root else { continue };
        let root_key = key(&root);
        if root_key == home_key {
            continue;
        }
        let entry = by_root.entry(root_key).or_insert((root, 0, session.date));
        entry.1 += 1;
        entry.2 = entry.2.max(session.date);
    }
    let mut out: Vec<ProjectCandidate> = by_root
        .into_iter()
        .map(|(root_key, (root, sessions, last))| {
            let (name, parent) = split_path(&root);
            ProjectCandidate { added: known.contains(&root_key), path: root, name, parent, sessions, last_active: last }
        })
        .collect();
    out.sort_by(|a, b| b.last_active.cmp(&a.last_active).then_with(|| a.path.cmp(&b.path)));
    out.truncate(limit);
    out
}

/// The repository a folder belongs to: the nearest folder upward that holds `.git` (a folder, or a file in a worktree).
pub fn git_root(folder: &str, exists: impl Fn(&Path) -> bool) -> Option<String> {
    let mut current = Some(Path::new(folder));
    while let Some(dir) = current {
        if dir.as_os_str().is_empty() {
            return None;
        }
        if exists(&dir.join(".git")) {
            return Some(dir.to_string_lossy().into_owned());
        }
        current = dir.parent();
    }
    None
}

/// `C:\Users\me\Developer\app` → (`app`, `C:\Users\me\Developer\`).
pub fn split_path(path: &str) -> (String, String) {
    let trimmed = normalize(path);
    match trimmed.rfind(['/', '\\']) {
        Some(at) if trimmed.len() > 1 => (trimmed[at + 1..].to_string(), trimmed[..=at].to_string()),
        _ => (trimmed, String::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(days_ago: i64) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-11-27T12:00:00Z").unwrap().with_timezone(&Utc) - Duration::days(days_ago)
    }

    fn s(folder: &str, days_ago: i64) -> SessionFolder {
        SessionFolder { folder: folder.into(), date: at(days_ago) }
    }

    #[test]
    fn candidates_take_folders_up_to_their_repository() {
        let roots = |f: &str| -> Option<String> {
            if f.starts_with("/dev/app") {
                Some("/dev/app".into())
            } else if f.starts_with("/dev/site") {
                Some("/dev/site/".into())
            } else {
                None
            }
        };
        let sessions = [s("/dev/app/src", 3), s("/dev/app", 1), s("/dev/site", 5), s("/tmp/loose", 1), s("/home/me", 1), s("/dev/old", 40)];
        let list = project_candidates(&sessions, &["/dev/site".into()], "/home/me", at(0), LIMIT, roots);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].path, "/dev/app");
        assert_eq!(list[0].sessions, 2);
        assert_eq!(list[0].name, "app");
        assert_eq!(list[0].parent, "/dev/");
        assert!(!list[0].added);
        assert_eq!(list[1].path, "/dev/site");
        assert!(list[1].added);
    }

    #[test]
    fn windows_paths_ignore_case_and_separators() {
        let sessions = [s(r"C:\Dev\App\", 1), s("c:/dev/app", 2)];
        let list = project_candidates(&sessions, &[r"C:\DEV\APP".into()], r"C:\Users\me", at(0), LIMIT, |f| Some(f.to_string()));
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].sessions, 2);
        assert!(list[0].added);
        assert_eq!(split_path(r"C:\Dev\App"), ("App".into(), r"C:\Dev\".into()));
    }

    #[test]
    fn finds_the_git_root_upward() {
        let root = std::env::temp_dir().join(format!("nook-readiness-{}", std::process::id()));
        let deep = root.join("a").join("b");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        let found = git_root(&deep.to_string_lossy(), |p| p.exists());
        assert_eq!(found.as_deref(), Some(root.to_string_lossy().as_ref()));
        let _ = std::fs::remove_dir_all(&root);
    }
}
