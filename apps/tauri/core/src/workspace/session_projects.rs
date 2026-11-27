//! Multi-project tracking for sessions (`SessionProjects`, #1549) and project creation / GitHub source parsing
//! (`AddProjectSource`, #1482) — part of AG-113.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use super::git::Git;
use super::source_control_rules::CloneLayout;
use crate::i18n::{tr, trf};

/// Where a folder lies in git: the top of the working tree it is in (`checkout`, a main checkout or a linked
/// worktree) and the repository's main checkout (`root`, the project).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoLocation {
    pub checkout: String,
    pub root: String,
}

static LOCATION_CACHE: LazyLock<Mutex<HashMap<String, Option<RepoLocation>>>> = LazyLock::new(Default::default);

/// Tracks additional git repositories a session edits besides its own (`SessionProjects` on macOS, #1549).
pub struct SessionProjects;

impl SessionProjects {
    /// At most this many other projects are remembered for one session.
    pub const LIMIT: usize = 6;

    /// Returns `projects` with the checkout of `file` appended when `file` lies inside another git repository
    /// than `own`; `None` when nothing changes (inside `own`, outside any git repo, same repo root, or already listed).
    pub fn adding(file: &str, own: &str, projects: &[String]) -> Option<Vec<String>> {
        if file.is_empty() || own.is_empty() || projects.len() >= Self::LIMIT {
            return None;
        }
        let abs = Self::absolute(file, own);
        if !Path::new(&abs).is_absolute() {
            return None;
        }
        // Inside the session's own folder: nothing to look up.
        let norm_file = super::paths::normalize(&abs);
        let norm_own = super::paths::normalize(own);
        let own_prefix = format!("{}/", norm_own.trim_end_matches('/'));
        if norm_file == norm_own || norm_file.starts_with(&own_prefix) {
            return None;
        }
        let parent = Path::new(&abs).parent()?;
        let found = Self::locate(parent)?;
        if Self::root_of(Path::new(own)).as_deref() == Some(found.root.as_str()) {
            return None;
        }
        let found_norm = super::paths::normalize(&found.checkout);
        if projects.iter().any(|p| super::paths::normalize(p) == found_norm) {
            return None;
        }
        let mut next = projects.to_vec();
        next.push(found.checkout);
        Some(next)
    }

    /// Resolves `path` against `cwd` when relative.
    pub fn absolute(path: &str, cwd: &str) -> String {
        let p = Path::new(path);
        if p.is_absolute() || cwd.is_empty() {
            return path.to_string();
        }
        Path::new(cwd).join(p).to_string_lossy().into_owned()
    }

    /// The main checkout of the repository `folder` lies in (walking `.git` without spawning git).
    pub fn root_of(folder: &Path) -> Option<String> {
        Self::locate(folder).map(|l| l.root)
    }

    /// Walks up to 24 ancestors looking for `.git` (directory or worktree pointer file), cached per folder.
    pub fn locate(folder: &Path) -> Option<RepoLocation> {
        let key = super::paths::normalize(&folder.to_string_lossy());
        if key.is_empty() {
            return None;
        }
        if let Ok(guard) = LOCATION_CACHE.lock() {
            if let Some(hit) = guard.get(&key) {
                return hit.clone();
            }
        }
        let found = Self::read(folder);
        if let Ok(mut guard) = LOCATION_CACHE.lock() {
            if guard.len() > 2_000 {
                guard.clear();
            }
            guard.insert(key, found.clone());
        }
        found
    }

    fn read(folder: &Path) -> Option<RepoLocation> {
        let home = dirs::home_dir();
        let mut current = std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf());
        for _ in 0..24 {
            current.parent()?;
            if home.as_deref() == Some(current.as_path()) {
                return None;
            }
            let dot_git = current.join(".git");
            if let Ok(meta) = std::fs::metadata(&dot_git) {
                let checkout = current.to_string_lossy().into_owned();
                if meta.is_dir() {
                    return Some(RepoLocation { checkout: checkout.clone(), root: checkout });
                }
                if meta.is_file() {
                    if let Ok(text) = std::fs::read_to_string(&dot_git) {
                        if let Some(target) = text.lines().find_map(|l| l.strip_prefix("gitdir:")).map(str::trim) {
                            let git_dir: PathBuf =
                                if Path::new(target).is_absolute() { PathBuf::from(target) } else { current.join(target) };
                            let normalized = git_dir.to_string_lossy().replace('\\', "/");
                            if let Some(idx) = normalized.find("/.git/worktrees/") {
                                let root = normalized[..idx].to_string();
                                if !root.is_empty() {
                                    return Some(RepoLocation { checkout, root });
                                }
                            }
                        }
                    }
                    return Some(RepoLocation { checkout: checkout.clone(), root: checkout });
                }
            }
            let parent = current.parent()?;
            if parent == current {
                return None;
            }
            current = parent.to_path_buf();
        }
        None
    }

    /// Deduplicated display names of `projects`, excluding `own`.
    pub fn names(projects: &[String], own: &str) -> Vec<String> {
        let mut seen: HashSet<String> = HashSet::new();
        seen.insert(own.to_string());
        let mut out = Vec::new();
        for p in projects {
            let trimmed = p.trim_end_matches(['/', '\\']);
            let leaf = Path::new(trimmed).file_name().and_then(|n| n.to_str()).unwrap_or("").trim();
            if !leaf.is_empty() && seen.insert(leaf.to_string()) {
                out.push(leaf.to_string());
            }
        }
        out
    }

    /// Formats `"Nook + monorepo"` or `"Nook + monorepo +2"` when more other projects were edited.
    pub fn label(own: &str, others: &[String], shown: usize) -> String {
        if others.is_empty() || shown == 0 {
            return own.to_string();
        }
        let named: Vec<&str> = others.iter().take(shown).map(String::as_str).collect();
        let rest = others.len().saturating_sub(shown);
        if rest > 0 {
            format!("{own} + {} +{rest}", named.join(" + "))
        } else {
            format!("{own} + {}", named.join(" + "))
        }
    }
}

/// Parsing project sources and creating a new empty Git repository project (`AddProjectSource` on macOS, #1482).
pub struct AddProjectSource;

impl AddProjectSource {
    /// Parses `"owner/repo"`, `"github.com/owner/repo"`, or a GitHub URL into `"https://github.com/owner/repo.git"`.
    pub fn github_url(typed: &str) -> Option<String> {
        let mut text = typed.trim().to_string();
        if text.is_empty() {
            return None;
        }
        if text.starts_with("https://") || text.starts_with("git@") {
            let mut url = CloneLayout::repository_url_from_page(&text);
            if !url.to_ascii_lowercase().contains("github.com") {
                return None;
            }
            if url.starts_with("https://") && !url.ends_with(".git") {
                url.push_str(".git");
            }
            return Some(url);
        }
        for prefix in ["http://", "www.", "github.com/"] {
            if text.len() >= prefix.len() && text[..prefix.len()].eq_ignore_ascii_case(prefix) {
                text = text[prefix.len()..].to_string();
            }
        }
        if let Some(stripped) = text.strip_suffix(".git") {
            text = stripped.to_string();
        }
        let text = text.trim_end_matches('/');
        let parts: Vec<&str> = text.split('/').collect();
        if parts.len() != 2 {
            return None;
        }
        let valid_part = |p: &str| {
            !p.is_empty() && !p.starts_with('.') && p.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        };
        if !parts.iter().all(|p| valid_part(p)) {
            return None;
        }
        Some(format!("https://github.com/{}/{}.git", parts[0], parts[1]))
    }

    /// Cleans a typed project name into a safe single folder name (matching macOS `AddProjectPalette.name`).
    pub fn sanitize_name(typed: &str) -> String {
        let cleaned: String = typed.trim().chars().map(|c| if matches!(c, '/' | '\\' | ':') { '-' } else { c }).collect();
        let trimmed = cleaned.trim().trim_matches('.');
        trimmed.to_string()
    }

    /// Creates `<parent>/<name>` as a new folder with an empty git repository (`git init`).
    pub fn create_project(git: Option<&Git>, parent: &Path, name: &str) -> Result<String, String> {
        let clean = Self::sanitize_name(name);
        if clean.is_empty() {
            return Err(tr("Geef het project een naam.", "Give the project a name.").to_string());
        }
        let target = parent.join(&clean);
        if target.exists() {
            let non_empty = std::fs::read_dir(&target).map(|mut it| it.next().is_some()).unwrap_or(true);
            if non_empty {
                return Err(trf("{name} bestaat al en is niet leeg.", "{name} already exists and is not empty.", &[("name", &clean)]));
            }
        } else {
            std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
        }
        let folder = target.to_string_lossy().into_owned();
        if let Some(git) = git {
            git.init_repository(&folder).map_err(|e| e.0)?;
        }
        Ok(folder)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn parses_github_project_sources() {
        assert_eq!(AddProjectSource::github_url("IAMichan/Nook").as_deref(), Some("https://github.com/IAMichan/Nook.git"));
        assert_eq!(AddProjectSource::github_url("github.com/acme/app.git").as_deref(), Some("https://github.com/acme/app.git"));
        assert_eq!(AddProjectSource::github_url("https://github.com/acme/app/pull/42").as_deref(), Some("https://github.com/acme/app.git"));
        assert_eq!(AddProjectSource::github_url("git@github.com:acme/app.git").as_deref(), Some("git@github.com:acme/app.git"));
        assert!(AddProjectSource::github_url("https://gitlab.com/acme/app").is_none());
        assert!(AddProjectSource::github_url("just-one-part").is_none());
        assert!(AddProjectSource::github_url("acme/..").is_none());
    }

    #[test]
    fn formats_multi_project_labels() {
        assert_eq!(SessionProjects::label("Nook", &[], 1), "Nook");
        assert_eq!(SessionProjects::label("Nook", &["monorepo".into()], 1), "Nook + monorepo");
        assert_eq!(SessionProjects::label("Nook", &["monorepo".into(), "docs".into(), "site".into()], 1), "Nook + monorepo +2");
        let names =
            SessionProjects::names(&["/work/Nook".into(), "/work/monorepo".into(), "/other/monorepo".into(), "/work/docs".into()], "Nook");
        assert_eq!(names, vec!["monorepo", "docs"]);
    }

    #[test]
    fn tracks_edits_in_other_repositories_and_ignores_same_repo_worktrees() {
        let base = std::env::temp_dir().join(format!("nook-sess-proj-{}", Uuid::new_v4()));
        let repo_a = base.join("nook");
        let wt_a = base.join("nook-wt");
        let repo_b = base.join("monorepo");
        let scratch = base.join("loose");
        std::fs::create_dir_all(repo_a.join(".git/worktrees/wt1")).unwrap();
        std::fs::create_dir_all(&wt_a).unwrap();
        let gitdir_target = repo_a.join(".git/worktrees/wt1");
        std::fs::write(wt_a.join(".git"), format!("gitdir: {}\n", gitdir_target.display())).unwrap();
        std::fs::create_dir_all(repo_b.join(".git")).unwrap();
        std::fs::create_dir_all(repo_b.join("src")).unwrap();
        std::fs::create_dir_all(&scratch).unwrap();

        let own = repo_a.to_string_lossy().into_owned();
        // Same repo worktree -> ignored
        let in_wt = wt_a.join("file.rs").to_string_lossy().into_owned();
        assert!(SessionProjects::adding(&in_wt, &own, &[]).is_none());

        // Outside any git repo -> ignored
        let in_scratch = scratch.join("notes.txt").to_string_lossy().into_owned();
        assert!(SessionProjects::adding(&in_scratch, &own, &[]).is_none());

        // Different git repo -> added once
        let in_b = repo_b.join("src/lib.rs").to_string_lossy().into_owned();
        let added = SessionProjects::adding(&in_b, &own, &[]).expect("other repo added");
        assert_eq!(added.len(), 1);
        assert!(added[0].ends_with("monorepo"));
        assert!(SessionProjects::adding(&in_b, &own, &added).is_none());

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn creates_new_project_folder_and_rejects_non_empty_collision() {
        let parent = std::env::temp_dir().join(format!("nook-new-proj-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&parent).unwrap();

        let made = AddProjectSource::create_project(None, &parent, "my/app").unwrap();
        assert!(made.ends_with("my-app"));
        assert!(Path::new(&made).is_dir());

        std::fs::write(Path::new(&made).join("README.md"), "hi").unwrap();
        assert!(AddProjectSource::create_project(None, &parent, "my/app").is_err());

        let _ = std::fs::remove_dir_all(&parent);
    }
}
