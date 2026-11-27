//! Coding agent readiness and recent repository discovery (`AgentReadiness` on macOS).
//!
//! Pure logic without processes or UI: classifies whether each coding agent is ready to start a session, what action a
//! row offers (install / sign in / none), and which git repositories you worked in during the last 30 days.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// Where an agent stands, in the order the onboarding/readiness step sorts them: what needs you first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReadinessState {
    /// Nook has not looked for the agent yet.
    Checking,
    /// Installing or signing in right now.
    Connecting,
    /// Installed, not signed in.
    SignIn,
    /// The program is not installed on this machine.
    Missing,
    /// Installed and signed in.
    Ready,
}

/// What the row offers for a state. Nothing installs without an explicit click.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReadinessAction {
    None,
    Install,
    SignIn,
}

/// Classifies an agent's readiness from scan, executable, sign-in, and in-progress flags.
pub fn classify(scanned: bool, installed: bool, signed_in: bool, connecting: bool) -> ReadinessState {
    if connecting {
        return ReadinessState::Connecting;
    }
    if installed {
        return if signed_in { ReadinessState::Ready } else { ReadinessState::SignIn };
    }
    // A sign-in without the program (the program was removed) still needs the program first.
    if scanned {
        ReadinessState::Missing
    } else {
        ReadinessState::Checking
    }
}

/// Action button offered for a given readiness state.
pub fn action_for(state: ReadinessState) -> ReadinessAction {
    match state {
        ReadinessState::Missing => ReadinessAction::Install,
        ReadinessState::SignIn => ReadinessAction::SignIn,
        ReadinessState::Checking | ReadinessState::Connecting | ReadinessState::Ready => ReadinessAction::None,
    }
}

/// Ready when at least one agent can start a session.
pub fn any_ready(states: &[ReadinessState]) -> bool {
    states.contains(&ReadinessState::Ready)
}

// MARK: Projects

/// A folder you worked in recently, as a project you could add.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCandidate {
    /// The repository's root folder.
    pub path: String,
    pub name: String,
    /// The folder it is in, for the line under the name (`~/Developer/`).
    pub parent: String,
    /// How many sessions worked in it within the window.
    pub sessions: usize,
    pub last_active: DateTime<Utc>,
    /// Already one of Nook's projects (favorites or recent projects).
    pub added: bool,
}

/// 30-day recency window for project discovery (`AgentReadiness.recentWindow` on macOS).
pub const RECENT_WINDOW_SECS: i64 = 30 * 24 * 3600;

/// Normalizes a filesystem path for comparison (trims whitespace and trailing slashes, preserving roots).
pub fn normalize_path(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if trimmed == "/" || trimmed == "\\" {
        return trimmed.to_string();
    }
    // Preserve Windows drive roots such as `C:\` or `C:/`.
    let bytes = trimmed.as_bytes();
    if bytes.len() == 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
        return trimmed.to_string();
    }
    let stripped = trimmed.trim_end_matches(['/', '\\']);
    if stripped.is_empty() {
        "/".to_string()
    } else if stripped.len() == 2 && stripped.as_bytes()[0].is_ascii_alphabetic() && stripped.as_bytes()[1] == b':' {
        // `C:\` trimmed down to `C:` -> restore trailing separator from original.
        trimmed[..3].to_string()
    } else {
        stripped.to_string()
    }
}

fn is_absolute_path(path: &str) -> bool {
    if path.starts_with('/') || path.starts_with("\\\\") {
        return true;
    }
    let bytes = path.as_bytes();
    bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/')
}

fn is_root_path(path: &str) -> bool {
    if path == "/" || path == "\\" {
        return true;
    }
    let bytes = path.as_bytes();
    bytes.len() == 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/')
}

fn join_git(dir: &str) -> String {
    if dir.ends_with('/') || dir.ends_with('\\') {
        format!("{dir}.git")
    } else if dir.contains('\\') && !dir.contains('/') {
        format!("{dir}\\.git")
    } else {
        format!("{dir}/.git")
    }
}

fn parent_dir(path: &str) -> Option<String> {
    if is_root_path(path) {
        return None;
    }
    let idx = path.rfind(['/', '\\'])?;
    if idx == 0 {
        return Some(path[..1].to_string());
    }
    // Windows drive root: `C:\foo` -> `C:\`.
    let bytes = path.as_bytes();
    if idx == 2 && bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return Some(path[..3].to_string());
    }
    Some(path[..idx].to_string())
}

/// The git repositories you worked in during the last 30 days, most recently used first: every session's folder is
/// taken up to its repository's root (`git_root`), so two subfolders of one checkout count once. Folders that are not
/// in a repository, the home folder, and sessions outside the window are left out.
pub fn project_candidates<F>(
    sessions: &[(String, DateTime<Utc>)],
    known: &[String],
    home: &str,
    now: DateTime<Utc>,
    limit: usize,
    git_root: F,
) -> Vec<ProjectCandidate>
where
    F: Fn(&str) -> Option<String>,
{
    let cutoff = now - Duration::seconds(RECENT_WINDOW_SECS);
    let home_norm = normalize_path(home);
    let known_set: HashSet<String> = known.iter().map(|p| normalize_path(p)).collect();
    let mut by_root: HashMap<String, (usize, DateTime<Utc>)> = HashMap::new();
    let mut root_cache: HashMap<String, Option<String>> = HashMap::new();

    for (raw_folder, date) in sessions {
        if *date < cutoff || *date > now {
            continue;
        }
        let folder = normalize_path(raw_folder);
        if folder.is_empty() || folder == home_norm || is_root_path(&folder) {
            continue;
        }
        let root = if let Some(cached) = root_cache.get(&folder) {
            cached.clone()
        } else {
            let found = git_root(&folder).map(|r| normalize_path(&r));
            root_cache.insert(folder.clone(), found.clone());
            found
        };
        let Some(root) = root else { continue };
        if root.is_empty() || root == home_norm {
            continue;
        }
        let entry = by_root.entry(root).or_insert((0, DateTime::<Utc>::MIN_UTC));
        entry.0 += 1;
        if *date > entry.1 {
            entry.1 = *date;
        }
    }

    let mut candidates: Vec<ProjectCandidate> = by_root
        .into_iter()
        .map(|(root, (sessions, last_active))| {
            let (name, parent) = split_path(&root);
            let added = known_set.contains(&root);
            ProjectCandidate { path: root, name, parent, sessions, last_active, added }
        })
        .collect();

    candidates.sort_by(|a, b| b.last_active.cmp(&a.last_active).then_with(|| a.path.cmp(&b.path)));
    candidates.truncate(limit);
    candidates
}

/// The repository a folder belongs to: the nearest folder upward that holds `.git` (a directory, or a file in a
/// worktree).
pub fn git_root<F>(folder: &str, file_exists: F) -> Option<String>
where
    F: Fn(&str) -> bool,
{
    let mut current = normalize_path(folder);
    if !is_absolute_path(&current) {
        return None;
    }
    loop {
        if file_exists(&join_git(&current)) {
            return Some(current);
        }
        match parent_dir(&current) {
            Some(parent) if parent != current => current = parent,
            _ => return None,
        }
    }
}

/// `"/Users/me/Developer/app"` -> `("app", "/Users/me/Developer/")`.
pub fn split_path(path: &str) -> (String, String) {
    let trimmed = normalize_path(path);
    if is_root_path(&trimmed) {
        return (trimmed, String::new());
    }
    let Some(sep) = trimmed.rfind(['/', '\\']) else {
        return (trimmed, String::new());
    };
    let name = trimmed[sep + 1..].to_string();
    let parent = trimmed[..=sep].to_string();
    (name, parent)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classification_matches_macos() {
        assert_eq!(classify(false, false, false, false), ReadinessState::Checking);
        assert_eq!(classify(true, false, false, false), ReadinessState::Missing);
        assert_eq!(classify(true, false, true, false), ReadinessState::Missing);
        assert_eq!(classify(true, true, false, false), ReadinessState::SignIn);
        assert_eq!(classify(true, true, true, false), ReadinessState::Ready);
        assert_eq!(classify(true, false, false, true), ReadinessState::Connecting);
        // Found before the full scan finished: what is there counts.
        assert_eq!(classify(false, true, true, false), ReadinessState::Ready);
    }

    #[test]
    fn actions_and_any_ready() {
        assert_eq!(action_for(ReadinessState::Missing), ReadinessAction::Install);
        assert_eq!(action_for(ReadinessState::SignIn), ReadinessAction::SignIn);
        for state in [ReadinessState::Checking, ReadinessState::Connecting, ReadinessState::Ready] {
            assert_eq!(action_for(state), ReadinessAction::None);
        }
        assert!(any_ready(&[ReadinessState::Missing, ReadinessState::Ready]));
        assert!(!any_ready(&[ReadinessState::Missing, ReadinessState::SignIn]));
    }

    #[test]
    fn git_root_walks_up_unix_and_windows() {
        let repos: HashSet<&str> = ["/Users/me/app/.git", "/Users/me/app/vendor/lib/.git", "C:\\dev\\nook\\.git"].into_iter().collect();
        let exists = |p: &str| repos.contains(p);
        assert_eq!(git_root("/Users/me/app/src/ui", exists).as_deref(), Some("/Users/me/app"));
        assert_eq!(git_root("/Users/me/app/", exists).as_deref(), Some("/Users/me/app"));
        assert_eq!(git_root("/Users/me/app/vendor/lib/x", exists).as_deref(), Some("/Users/me/app/vendor/lib"));
        assert_eq!(git_root("C:\\dev\\nook\\apps\\tauri", exists).as_deref(), Some("C:\\dev\\nook"));
        assert_eq!(git_root("/Users/me/notes", exists), None);
        assert_eq!(git_root("relative/path", |_| true), None);
    }

    #[test]
    fn project_candidates_group_by_repository_and_skip_old_or_plain_folders() {
        let now = DateTime::from_timestamp(10_000_000, 0).unwrap();
        let day = |n: i64| now - Duration::days(n);
        let roots: HashMap<&str, &str> = [
            ("/Users/me/app", "/Users/me/app"),
            ("/Users/me/app/web", "/Users/me/app"),
            ("/Users/me/api", "/Users/me/api"),
            ("/Users/me/old", "/Users/me/old"),
            ("/Users/me", "/Users/me"),
        ]
        .into_iter()
        .collect();
        let sessions = vec![
            ("/Users/me/app/web".into(), day(2)),
            ("/Users/me/app".into(), day(5)),
            ("/Users/me/api/".into(), day(1)),
            ("/Users/me/old".into(), day(40)),
            ("/Users/me/notes".into(), day(1)),
            ("/Users/me".into(), day(1)),
            (String::new(), now),
        ];
        let result =
            project_candidates(&sessions, &["/Users/me/api/".into()], "/Users/me", now, 8, |p| roots.get(p).map(|s| (*s).to_string()));
        let paths: Vec<&str> = result.iter().map(|c| c.path.as_str()).collect();
        let counts: Vec<usize> = result.iter().map(|c| c.sessions).collect();
        let added: Vec<bool> = result.iter().map(|c| c.added).collect();
        assert_eq!(paths, vec!["/Users/me/api", "/Users/me/app"]);
        assert_eq!(counts, vec![1, 2]);
        assert_eq!(added, vec![true, false]);
        assert_eq!(result[1].name, "app");
        assert_eq!(result[1].parent, "/Users/me/");
        assert_eq!(result[1].last_active, day(2));
    }

    #[test]
    fn project_candidates_respect_limit() {
        let now = DateTime::from_timestamp(10_000_000, 0).unwrap();
        let sessions: Vec<(String, DateTime<Utc>)> = (0..20).map(|i| (format!("/r/p{i}"), now - Duration::minutes(i))).collect();
        let result = project_candidates(&sessions, &[], "/Users/me", now, 3, |p| Some(p.to_string()));
        let paths: Vec<&str> = result.iter().map(|c| c.path.as_str()).collect();
        assert_eq!(paths, vec!["/r/p0", "/r/p1", "/r/p2"]);
    }

    #[test]
    fn split_path_handles_unix_windows_and_bare() {
        assert_eq!(split_path("/Users/me/Developer/app/"), ("app".into(), "/Users/me/Developer/".into()));
        assert_eq!(split_path("/Users/me/Developer/app"), ("app".into(), "/Users/me/Developer/".into()));
        assert_eq!(split_path("C:\\Users\\me\\app\\"), ("app".into(), "C:\\Users\\me\\".into()));
        assert_eq!(split_path("app"), ("app".into(), String::new()));
    }
}
