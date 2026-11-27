//! Source control rules and git operations (`SourceControl`, `GitService+SourceControl`,
//! `ProjectIconStore` on macOS — AG-120):
//! - `AutoPull`: fast-forward the main checkout's default branch every ~15 min only when clean, idle, and behind.
//! - `CloneLayout`: parse git addresses, normalize browser page URLs to repository URLs, compute
//!   `<parent>/<host>/<owner>/<repo>` layout paths, prepare empty/DS_Store clone targets, and fall back
//!   from SSH to HTTPS when SSH is refused.
//! - `RepositoryPublish`: validate/suggest GitHub repository names, build `POST /user/repos` or
//!   `/orgs/{owner}/repos`, prepare a local folder (`git init`, initial commit), and push with an
//!   ephemeral token credential helper (never storing the token).
//! - `CommitReference`: recognize bare commit hashes and GitHub commit URLs in agent answers.
//! - `store_project_icon`: copy an image (<4 MB) into Nook's `project-icons` directory.

use std::collections::BTreeMap;
use std::ops::Range;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::i18n::{tr, trf};

use super::clone_progress::failure as clone_failure_message;
use super::git::{clone_folder_name, is_clone_url, run_process, Git, GitError, Output, Result as GitResult};
use super::settings::ProjectOverride;

// MARK: AutoPull

/// At most this often per repository: each look fetches the default branch once.
pub const AUTO_PULL_INTERVAL_SECS: u64 = 15 * 60;

/// Files inside `.git` that signal an in-progress git operation.
pub const OPERATION_MARKERS: [&str; 6] = ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoPullFacts {
    /// Branch checked out in the main checkout; `None` when HEAD is detached.
    pub branch: Option<String>,
    /// The repository's default branch on its remote (e.g. `"main"`).
    pub default_branch: Option<String>,
    /// Tracked files with staged or unstaged changes.
    pub dirty: bool,
    /// A merge, rebase, cherry-pick, revert or bisect is under way.
    pub operation_in_progress: bool,
    /// A session Nook runs works in this checkout itself (`IsolationMode::Folder`).
    pub session_working: bool,
    /// Local commits ahead of the remote tracking branch.
    pub ahead: u32,
    /// Remote commits behind the remote tracking branch.
    pub behind: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AutoPullSkipReason {
    NoDefaultBranch,
    NotOnDefaultBranch,
    Dirty,
    OperationInProgress,
    SessionWorking,
    Diverged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AutoPullVerdict {
    FastForward,
    UpToDate,
    Skip(AutoPullSkipReason),
}

pub struct AutoPull;

impl AutoPull {
    /// Whether any project can resolve to auto-pull on: either the global default is on,
    /// or at least one project override explicitly switches it on.
    pub fn enabled_anywhere(global: bool, overrides: &BTreeMap<String, ProjectOverride>) -> bool {
        global || overrides.values().any(|o| o.auto_pull == Some(true))
    }

    /// Never a merge and never a dirty tree: only a clean checkout of the default branch
    /// that is strictly behind its remote moves forward.
    pub fn decide(facts: &AutoPullFacts) -> AutoPullVerdict {
        let Some(target) = facts.default_branch.as_deref().filter(|t| !t.is_empty()) else {
            return AutoPullVerdict::Skip(AutoPullSkipReason::NoDefaultBranch);
        };
        if facts.branch.as_deref() != Some(target) {
            return AutoPullVerdict::Skip(AutoPullSkipReason::NotOnDefaultBranch);
        }
        if facts.operation_in_progress {
            return AutoPullVerdict::Skip(AutoPullSkipReason::OperationInProgress);
        }
        if facts.session_working {
            return AutoPullVerdict::Skip(AutoPullSkipReason::SessionWorking);
        }
        if facts.dirty {
            return AutoPullVerdict::Skip(AutoPullSkipReason::Dirty);
        }
        if facts.ahead > 0 {
            return if facts.behind > 0 { AutoPullVerdict::Skip(AutoPullSkipReason::Diverged) } else { AutoPullVerdict::UpToDate };
        }
        if facts.behind > 0 {
            AutoPullVerdict::FastForward
        } else {
            AutoPullVerdict::UpToDate
        }
    }

    /// Parses `git rev-list --left-right --count HEAD...origin/main` (`"ahead\tbehind"`).
    pub fn parse_counts(text: &str) -> Option<(u32, u32)> {
        let parts: Vec<u32> = text.split_whitespace().filter_map(|p| p.parse().ok()).collect();
        (parts.len() == 2).then(|| (parts[0], parts[1]))
    }
}

// MARK: CloneLayout

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloneAddress {
    pub host: String,
    pub owner: String,
    pub name: String,
}

const TWO_PART_HOSTS: [&str; 7] =
    ["github.com", "www.github.com", "bitbucket.org", "codeberg.org", "gitea.com", "git.cafe", "staging.git.cafe"];

const PAGE_ROUTES: [&str; 16] = [
    "tree",
    "blob",
    "commit",
    "commits",
    "pull",
    "pulls",
    "pull-requests",
    "issues",
    "actions",
    "releases",
    "compare",
    "wiki",
    "src",
    "raw",
    "tags",
    "branches",
];

const LIST_ROUTES: [&str; 9] = ["commits", "pulls", "pull-requests", "issues", "actions", "releases", "wiki", "tags", "branches"];

const SSH_REFUSED_PATTERNS: [&str; 10] = [
    "permission denied (publickey",
    "host key verification failed",
    "could not read from remote repository",
    "ssh: connect to host",
    "connection refused",
    "connection timed out",
    "no route to host",
    "ssh: could not resolve hostname",
    "kex_exchange_identification",
    "too many authentication failures",
];

pub struct CloneLayout;

impl CloneLayout {
    /// Parses `https://`, `http://`, `ssh://`, and scp-style (`git@host:owner/repo.git`) addresses.
    pub fn parse(url: &str) -> Option<CloneAddress> {
        let clean = url.trim();
        let (host_raw, raw_path) = if clean.starts_with("https://") || clean.starts_with("http://") || clean.starts_with("ssh://") {
            let parsed = reqwest::Url::parse(clean).ok()?;
            let host = parsed.host_str()?.to_string();
            (host, parsed.path().to_string())
        } else {
            let at = clean.find('@')?;
            let after_at = &clean[at + 1..];
            let colon = after_at.find(':')?;
            let host = after_at[..colon].to_string();
            let path = after_at[colon + 1..].to_string();
            (host, path)
        };

        let host = host_raw.to_lowercase();
        let mut parts: Vec<String> = raw_path.split('/').filter(|s| !s.is_empty() && *s != "~").map(str::to_string).collect();
        if parts.len() < 2 {
            return None;
        }
        let mut name = parts.pop()?;
        if name.ends_with(".git") {
            name.truncate(name.len() - 4);
        }
        let owner = parts.join("/");
        if host.is_empty() || owner.is_empty() || name.is_empty() {
            return None;
        }
        let all_safe = std::iter::once(host.as_str())
            .chain(std::iter::once(name.as_str()))
            .chain(parts.iter().map(String::as_str))
            .all(|s| s != "." && s != ".." && !s.starts_with('-'));
        if !all_safe {
            return None;
        }
        Some(CloneAddress { host, owner, name })
    }

    /// Normalizes a browser page URL into its cloneable repository URL:
    /// `https://github.com/owner/repo/tree/main` → `https://github.com/owner/repo`.
    /// Cuts GitLab pages at `/-/`, trims two-part hosts (`github.com`, `bitbucket.org`, …)
    /// to `owner/repo`, trims known page routes on self-hosted Gitea/Forgejo, and strips
    /// query/fragment. Leaves `.git`, `ssh://`, and scp-style URLs as typed (trimmed).
    pub fn repository_url_from_page(raw: &str) -> String {
        let clean = raw.trim();
        let lower = clean.to_lowercase();
        if !(lower.starts_with("https://") || lower.starts_with("http://")) {
            return clean.to_string();
        }
        let Ok(mut parsed) = reqwest::Url::parse(clean) else {
            return clean.to_string();
        };
        let Some(host) = parsed.host_str().map(str::to_lowercase).filter(|h| !h.is_empty()) else {
            return clean.to_string();
        };
        let orig_path = parsed.path().to_string();
        let drops_extras = parsed.query().is_some() || parsed.fragment().is_some();
        let mut new_path = orig_path.clone();
        let trimmed_path = orig_path.strip_suffix('/').unwrap_or(&orig_path);
        if !trimmed_path.ends_with(".git") {
            let mut parts: Vec<&str> = orig_path.split('/').collect();
            if let Some(marker) = parts.iter().position(|p| *p == "-") {
                if marker >= 3 {
                    parts.truncate(marker);
                }
            } else if TWO_PART_HOSTS.contains(&host.as_str()) && parts.len() > 3 && !parts[1].is_empty() && !parts[2].is_empty() {
                parts.truncate(3);
            } else if parts.len() > 3 && !parts[1].is_empty() && !parts[2].is_empty() && PAGE_ROUTES.contains(&parts[3]) {
                let has_rest = parts[4..].iter().any(|p| !p.is_empty());
                if has_rest || LIST_ROUTES.contains(&parts[3]) {
                    parts.truncate(3);
                }
            }
            new_path = parts.join("/");
        }
        if new_path == orig_path && !drops_extras {
            return clean.to_string();
        }
        parsed.set_path(&new_path);
        parsed.set_query(None);
        parsed.set_fragment(None);
        parsed.to_string()
    }

    /// Whether a clone may go into `path`: nonexistent, or an empty directory (or one containing
    /// only macOS Finder's `.DS_Store`, which is removed so `git clone` accepts it).
    pub fn prepare_clone_target(path: &Path) -> bool {
        if !path.exists() {
            return true;
        }
        if !path.is_dir() {
            return false;
        }
        let Ok(entries) = std::fs::read_dir(path) else {
            return false;
        };
        let mut names = Vec::new();
        for entry in entries {
            let Ok(entry) = entry else {
                return false;
            };
            let name = entry.file_name();
            if name != ".DS_Store" {
                return false;
            }
            names.push(entry.path());
        }
        for ds in names {
            let _ = std::fs::remove_file(ds);
        }
        std::fs::read_dir(path).map(|mut it| it.next().is_none()).unwrap_or(false)
    }

    /// Target folder for a clone: `<parent>/<folder_name>`, or with `host_layout`,
    /// `<parent>/<host>/<owner>/<folder_name>`. Returns `None` when `host_layout` is requested
    /// for a URL that cannot be parsed.
    pub fn target(url: &str, parent: &Path, host_layout: bool, folder_name: &str) -> Option<PathBuf> {
        if !host_layout {
            return Some(parent.join(folder_name));
        }
        let address = Self::parse(url)?;
        let mut folder = parent.join(&address.host);
        for part in address.owner.split('/') {
            if !part.is_empty() {
                folder.push(part);
            }
        }
        Some(folder.join(folder_name))
    }

    /// The root of a host layout a project already lives in:
    /// `/Users/me/src/github.com/me/app` → `/Users/me/src`
    /// (grandparent is a hostname containing `.`, with at least one directory above it).
    pub fn layout_root(project: &Path) -> Option<PathBuf> {
        let components: Vec<Component<'_>> = project.components().collect();
        let normal_count = components.iter().filter(|c| matches!(c, Component::Normal(_))).count();
        // Need at least <root_dir>/<host>/<owner>/<repo> (4 normal components).
        if normal_count < 4 || components.len() < 4 {
            return None;
        }
        let host_comp = components.get(components.len() - 3)?;
        let Component::Normal(host_os) = host_comp else {
            return None;
        };
        let host = host_os.to_str()?;
        if !host.contains('.') || !host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-') {
            return None;
        }
        let mut root = PathBuf::new();
        for comp in &components[..components.len() - 3] {
            root.push(comp.as_os_str());
        }
        Some(root)
    }

    /// Parent directory for a clone: the root of the current project's host layout when
    /// `host_layout` is on, otherwise `developer_dir`, or with `host_layout` off the parent
    /// next to `project` (falling back to `developer_dir`).
    pub fn clone_parent(project: Option<&Path>, host_layout: bool, developer_dir: &Path) -> PathBuf {
        if host_layout {
            return project.and_then(Self::layout_root).unwrap_or_else(|| developer_dir.to_path_buf());
        }
        project
            .and_then(Path::parent)
            .filter(|p| !p.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| developer_dir.to_path_buf())
    }

    /// Whether the address uses SSH (`ssh://` or `user@host:path`).
    pub fn is_ssh(url: &str) -> bool {
        let clean = url.trim();
        if clean.starts_with("ssh://") {
            return true;
        }
        !clean.contains("://") && clean.contains('@') && clean.contains(':')
    }

    /// The HTTPS fallback URL for an SSH address:
    /// `git@github.com:me/app.git` → `https://github.com/me/app.git`.
    pub fn https_fallback(url: &str) -> Option<String> {
        if !Self::is_ssh(url) {
            return None;
        }
        let address = Self::parse(url)?;
        Some(format!("https://{}/{}/{}.git", address.host, address.owner, address.name))
    }

    /// Whether git's stderr indicates SSH itself failed (no key, unknown host key, refused),
    /// so retrying over HTTPS may succeed.
    pub fn ssh_refused(stderr: &str) -> bool {
        let lower = stderr.to_lowercase();
        SSH_REFUSED_PATTERNS.iter().any(|pat| lower.contains(pat))
    }
}

// MARK: RepositoryPublish

pub struct RepositoryPublish;

impl RepositoryPublish {
    /// GitHub's repository name rule: ASCII letters, digits, `.`, `-`, `_`, 1..=100 chars, not `.` or `..`.
    pub fn is_valid_name(name: &str) -> bool {
        !name.is_empty()
            && name.len() <= 100
            && name != "."
            && name != ".."
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
    }

    /// Suggests a valid repository name from a folder name: `"My App (2)"` → `"My-App-2"`.
    pub fn suggested_name(folder: &str) -> String {
        let mut result = String::new();
        let mut last_dash = false;
        for ch in folder.chars() {
            if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' {
                result.push(ch);
                last_dash = false;
            } else if !last_dash && !result.is_empty() {
                result.push('-');
                last_dash = true;
            }
        }
        while result.ends_with('-') || result.ends_with('.') {
            result.pop();
        }
        let trimmed: String = result.chars().take(100).collect();
        if Self::is_valid_name(&trimmed) {
            trimmed
        } else {
            "project".into()
        }
    }

    /// API path for creating a GitHub repository under the user's own account or an organization.
    pub fn request_path(owner: Option<&str>) -> String {
        match owner.map(str::trim).filter(|o| !o.is_empty()) {
            Some(org) => format!("/orgs/{org}/repos"),
            None => "/user/repos".into(),
        }
    }

    /// JSON body for `POST /user/repos` or `/orgs/{org}/repos`.
    pub fn request_body(name: &str, is_private: bool) -> Value {
        json!({ "name": name, "private": is_private, "auto_init": false })
    }

    /// Only a project without any remote can be published.
    pub fn can_publish(is_repository: bool, remotes: &[String]) -> bool {
        !is_repository || remotes.is_empty()
    }

    /// Ephemeral credential helper reading `NOOK_PUBLISH_TOKEN` so git never persists the token.
    /// Git runs `!`-prefixed helpers via `/bin/sh` on Unix and Git for Windows' bundled `sh.exe` on Windows.
    pub const CREDENTIAL_HELPER: &'static str =
        r#"!f() { test "$1" = get && echo username=x-access-token && echo "password=$NOOK_PUBLISH_TOKEN"; }; f"#;
}

// MARK: CommitReference

pub const COMMIT_SCHEME: &str = "nook-commit";

pub struct CommitReference;

impl CommitReference {
    /// 7..=40 lowercase hex characters with at least one digit and one letter.
    pub fn is_hash(text: &str) -> bool {
        let len = text.len();
        if !(7..=40).contains(&len) {
            return false;
        }
        let mut has_digit = false;
        let mut has_letter = false;
        for b in text.bytes() {
            if b.is_ascii_digit() {
                has_digit = true;
            } else if (b'a'..=b'f').contains(&b) {
                has_letter = true;
            } else {
                return false;
            }
        }
        has_digit && has_letter
    }

    pub fn link(hash: &str) -> String {
        format!("{COMMIT_SCHEME}:{}", hash.to_lowercase())
    }

    /// Extracts a commit hash from `nook-commit:<hash>` or a GitHub commit URL
    /// (`https://github.com/owner/repo/commit/<hash>` or `.../pull/12/commits/<hash>`).
    pub fn hash_in_url(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if let Some(rest) = trimmed.strip_prefix(&format!("{COMMIT_SCHEME}:")) {
            let text = rest.trim_matches('/');
            return Self::is_hash(text).then(|| text.to_string());
        }
        let parsed = reqwest::Url::parse(trimmed).ok()?;
        if parsed.scheme() != "https" || !parsed.host_str().is_some_and(|h| h.eq_ignore_ascii_case("github.com")) {
            return None;
        }
        let parts: Vec<&str> = parsed.path().split('/').filter(|p| !p.is_empty()).collect();
        if parts.len() >= 4 && parts[2] == "commit" {
            let h = parts[3].to_lowercase();
            if Self::is_hash(&h) {
                return Some(h);
            }
        }
        if parts.len() >= 6 && parts[2] == "pull" && parts[4] == "commits" {
            let h = parts[5].to_lowercase();
            if Self::is_hash(&h) {
                return Some(h);
            }
        }
        None
    }

    /// Finds whole-word commit hashes in plain text as byte ranges.
    pub fn hashes_in_text(text: &str) -> Vec<Range<usize>> {
        let mut result = Vec::new();
        let mut start: Option<usize> = None;
        for (idx, ch) in text.char_indices() {
            if ch.is_alphanumeric() || matches!(ch, '_' | '/' | '-') {
                if start.is_none() {
                    start = Some(idx);
                }
            } else if let Some(begin) = start.take() {
                if Self::is_hash(&text[begin..idx]) {
                    result.push(begin..idx);
                }
            }
        }
        if let Some(begin) = start {
            if Self::is_hash(&text[begin..]) {
                result.push(begin..text.len());
            }
        }
        result
    }
}

// MARK: Git operations for source control

/// Result of cloning a repository with optional host layout and SSH→HTTPS fallback.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneResult {
    pub path: String,
    pub used_https: bool,
}

impl Git {
    /// The main checkout that `path` (a repository root or any of its worktrees) belongs to.
    pub fn main_checkout(&self, path: &str) -> Option<String> {
        let common = self.common_directory(path)?;
        let common_path = Path::new(&common);
        if common_path.file_name().and_then(|n| n.to_str()) != Some(".git") {
            return None;
        }
        common_path.parent().map(|p| p.to_string_lossy().into_owned())
    }

    /// Collects the facts `AutoPull::decide` needs for a main checkout.
    pub fn auto_pull_facts(
        &self,
        checkout: &str,
        branch: Option<String>,
        target: &str,
        tracking: &str,
        session_working: bool,
    ) -> AutoPullFacts {
        let dirty = self.run(&["status", "--porcelain=v1", "--untracked-files=no"], checkout).map(|out| !out.is_empty()).unwrap_or(true);
        let git_dir = self.run(&["rev-parse", "--absolute-git-dir"], checkout).ok().map(|s| s.trim().to_string()).unwrap_or_default();
        let operation_in_progress = git_dir.is_empty() || OPERATION_MARKERS.iter().any(|marker| Path::new(&git_dir).join(marker).exists());
        let counts = self
            .run(&["rev-list", "--left-right", "--count", &format!("HEAD...{tracking}")], checkout)
            .ok()
            .and_then(|s| AutoPull::parse_counts(&s));
        let (ahead, behind) = counts.unwrap_or((1, 1));
        AutoPullFacts { branch, default_branch: Some(target.to_string()), dirty, operation_in_progress, session_working, ahead, behind }
    }

    /// Fetches the default branch and fast-forwards the main checkout when `AutoPull::decide` allows.
    /// Never merges and never touches a dirty working tree.
    pub fn auto_pull(&self, checkout: &str, session_working: bool) -> GitResult<AutoPullVerdict> {
        let remotes = self.remotes(checkout);
        let remote = if remotes.iter().any(|r| r == "origin") {
            "origin".to_string()
        } else if let Some(first) = remotes.first() {
            first.clone()
        } else {
            return Ok(AutoPullVerdict::Skip(AutoPullSkipReason::NoDefaultBranch));
        };
        let Some(target) = self.default_branch(checkout, &remote) else {
            return Ok(AutoPullVerdict::Skip(AutoPullSkipReason::NoDefaultBranch));
        };
        let branch = self.current_branch(checkout);
        if branch.as_deref() != Some(target.as_str()) {
            return Ok(AutoPullVerdict::Skip(AutoPullSkipReason::NotOnDefaultBranch));
        }
        let refspec = format!("+refs/heads/{target}:refs/remotes/{remote}/{target}");
        let _ =
            self.run_with(&["fetch", "--quiet", "--no-tags", &remote, &refspec], checkout, Duration::from_secs(30), &[0], &BTreeMap::new());
        let tracking = format!("refs/remotes/{remote}/{target}");
        if !self.ref_exists(&tracking, checkout) {
            return Ok(AutoPullVerdict::Skip(AutoPullSkipReason::NoDefaultBranch));
        }
        let facts = self.auto_pull_facts(checkout, branch, &target, &tracking, session_working);
        let verdict = AutoPull::decide(&facts);
        if verdict != AutoPullVerdict::FastForward {
            return Ok(verdict);
        }
        self.run_with(&["merge", "--ff-only", "--quiet", &tracking], checkout, Duration::from_secs(120), &[0], &BTreeMap::new())?;
        Ok(verdict)
    }

    /// Clones into `<parent>/<repo>`, or `<parent>/<host>/<owner>/<repo>` with `host_layout`.
    /// Normalizes browser page URLs and retries once over HTTPS if an SSH connection is refused.
    pub fn clone_with_layout(&self, url: &str, parent: &str, host_layout: bool) -> GitResult<CloneResult> {
        let clean = CloneLayout::repository_url_from_page(url);
        if !is_clone_url(&clean) {
            return Err(GitError(tr("Dat is geen adres van een repository.", "That is not the address of a repository.").into()));
        }
        let folder_name = clone_folder_name(&clean);
        let Some(target) = CloneLayout::target(&clean, Path::new(parent), host_layout, &folder_name) else {
            return Err(GitError(trf(
                "Kon host en eigenaar van {url} niet lezen.",
                "Could not read the host and owner of {url}.",
                &[("url", &clean)],
            )));
        };
        if !CloneLayout::prepare_clone_target(&target) {
            return Err(GitError(trf("De map {path} bestaat al.", "The folder {path} already exists.", &[("path", &target.display())])));
        }
        let folder = target.parent().unwrap_or_else(|| Path::new(parent));
        std::fs::create_dir_all(folder).map_err(|e| GitError(e.to_string()))?;
        let target_text = target.to_string_lossy().into_owned();
        let first = self.clone_once(&clean, &target_text, folder, CloneLayout::is_ssh(&clean))?;
        if first.status == 0 && !first.timed_out {
            return Ok(CloneResult { path: target_text, used_https: false });
        }
        if let Some(https) = CloneLayout::https_fallback(&clean) {
            if CloneLayout::ssh_refused(&first.stderr) {
                let _ = std::fs::remove_dir_all(&target);
                let second = self.clone_once(&https, &target_text, folder, false)?;
                if second.status == 0 && !second.timed_out {
                    return Ok(CloneResult { path: target_text, used_https: true });
                }
                let msg = clone_failure_message(&second.stderr).unwrap_or_else(|| tr("Klonen mislukte.", "Cloning failed.").into());
                return Err(GitError(msg));
            }
        }
        let msg = clone_failure_message(&first.stderr).unwrap_or_else(|| tr("Klonen mislukte.", "Cloning failed.").into());
        Err(GitError(msg))
    }

    fn clone_once(&self, url: &str, target: &str, folder: &Path, batch_ssh: bool) -> GitResult<Output> {
        let mut env = self.environment();
        if batch_ssh && !env.contains_key("GIT_SSH_COMMAND") {
            env.insert("GIT_SSH_COMMAND".into(), "ssh -o BatchMode=yes -o ConnectTimeout=15".into());
        }
        run_process(
            &self.executable,
            &["clone".into(), "--".into(), url.into(), target.into()],
            Some(folder),
            &env,
            Duration::from_secs(900),
        )
        .map_err(|e| GitError(e.to_string()))
    }

    /// Makes a local folder ready to publish: initializes git if needed and creates an initial commit
    /// when there are no commits yet. Returns the branch name to push.
    pub fn prepare_publish(&self, folder: &str) -> GitResult<String> {
        if self.repository_root(folder).is_none() {
            self.run(&["init", "--quiet"], folder)?;
        }
        if !self.has_commits(folder) {
            self.run_with(&["add", "-A"], folder, Duration::from_secs(120), &[0], &BTreeMap::new())?;
            self.run_with(
                &["commit", "--quiet", "--allow-empty", "-m", "Initial commit"],
                folder,
                Duration::from_secs(120),
                &[0],
                &BTreeMap::new(),
            )?;
        }
        self.current_branch(folder).ok_or_else(|| GitError(tr("De map staat niet op een branch.", "The folder is not on a branch.").into()))
    }

    /// Adds `origin` and pushes `branch` to it using an ephemeral token credential helper when `token`
    /// is provided. Removes `origin` again if the push fails so retrying starts clean.
    pub fn publish(&self, folder: &str, remote_url: &str, branch: &str, token: Option<&str>) -> GitResult<()> {
        if !self.remotes(folder).is_empty() {
            return Err(GitError(tr("Deze repository heeft al een remote.", "This repository already has a remote.").into()));
        }
        self.run(&["remote", "add", "origin", remote_url], folder)?;
        let mut env = self.environment();
        let mut args: Vec<String> = vec!["-C".into(), folder.into()];
        if let Some(tok) = token {
            env.insert("NOOK_PUBLISH_TOKEN".into(), tok.into());
            args.extend([
                "-c".into(),
                "credential.helper=".into(),
                "-c".into(),
                format!("credential.helper={}", RepositoryPublish::CREDENTIAL_HELPER),
            ]);
        }
        args.extend(["push".into(), "--set-upstream".into(), "origin".into(), format!("HEAD:refs/heads/{branch}")]);
        let output = run_process(&self.executable, &args, Some(Path::new(folder)), &env, Duration::from_secs(600)).map_err(|e| {
            let _ = self.run(&["remote", "remove", "origin"], folder);
            GitError(e.to_string())
        })?;
        if output.status != 0 || output.timed_out {
            let _ = self.run(&["remote", "remove", "origin"], folder);
            let msg = clone_failure_message(&output.stderr)
                .unwrap_or_else(|| tr("Pushen naar GitHub mislukte.", "Pushing to GitHub failed.").into());
            return Err(GitError(msg));
        }
        Ok(())
    }
}

// MARK: GitHub repository creation

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishedRepo {
    pub clone_url: String,
    pub html_url: String,
    pub full_name: String,
    pub token: String,
}

fn github_api_client() -> reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder().connect_timeout(Duration::from_secs(10)).timeout(Duration::from_secs(30)).build().unwrap_or_default()
        })
        .clone()
}

/// Creates a GitHub repository under the user's account or an organization using the first token
/// that succeeds.
pub async fn create_github_repository(
    tokens: &[String],
    name: &str,
    owner: Option<&str>,
    is_private: bool,
) -> Result<PublishedRepo, String> {
    if !RepositoryPublish::is_valid_name(name) {
        return Err(tr(
            "Gebruik letters, cijfers, '.', '-' en '_', maximaal 100 tekens.",
            "Use letters, digits, '.', '-' and '_', at most 100 characters.",
        )
        .into());
    }
    if tokens.is_empty() {
        return Err(tr(
            "GitHub is niet gekoppeld. Koppel het bij Instellingen › Koppelingen.",
            "GitHub is not connected. Connect it under Settings › Connections.",
        )
        .into());
    }
    let url = format!("https://api.github.com{}", RepositoryPublish::request_path(owner));
    let body = RepositoryPublish::request_body(name, is_private);
    let client = github_api_client();
    let mut last_error = String::new();

    for token in tokens {
        let response = match client
            .post(&url)
            .bearer_auth(token)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header("User-Agent", "Nook")
            .json(&body)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                last_error = trf("GitHub is niet bereikbaar: {error}", "GitHub is unreachable: {error}", &[("error", &e.to_string())]);
                continue;
            }
        };
        let status = response.status().as_u16();
        let object: Value = response.json().await.unwrap_or(Value::Null);
        if (200..300).contains(&status) {
            let clone_url = object.get("clone_url").and_then(Value::as_str);
            let html_url = object.get("html_url").and_then(Value::as_str);
            let full_name = object.get("full_name").and_then(Value::as_str);
            if let (Some(clone_url), Some(html_url)) = (clone_url, html_url) {
                return Ok(PublishedRepo {
                    clone_url: clone_url.to_string(),
                    html_url: html_url.to_string(),
                    full_name: full_name.unwrap_or(name).to_string(),
                    token: token.clone(),
                });
            }
        }
        let mut message = object.get("message").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("GitHub ({status})"));
        if let Some(errors) = object.get("errors").and_then(Value::as_array) {
            let details: Vec<&str> = errors.iter().filter_map(|e| e.get("message").and_then(Value::as_str)).collect();
            if !details.is_empty() {
                message.push(' ');
                message.push_str(&details.join(" "));
            }
        }
        last_error = format!("GitHub: {message}");
    }
    Err(last_error)
}

// MARK: ProjectIconStore

const MAX_PROJECT_ICON_BYTES: usize = 4 * 1024 * 1024;

/// Copies an image file (<4 MB) into `icons_dir` under a unique filename so the project icon
/// keeps working if the original file moves.
pub fn store_project_icon(source: &Path, icons_dir: &Path) -> Result<PathBuf, String> {
    let data = std::fs::read(source).map_err(|e| e.to_string())?;
    if data.is_empty() || data.len() >= MAX_PROJECT_ICON_BYTES {
        return Err(tr("Deze afbeelding is te groot (maximaal 4 MB).", "This image is too large (at most 4 MB).").into());
    }
    if !looks_like_image(&data) {
        return Err(tr("Kies een geldige afbeelding.", "Choose a valid image file.").into());
    }
    std::fs::create_dir_all(icons_dir).map_err(|e| e.to_string())?;
    let ext = source
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_lowercase)
        .filter(|e| matches!(e.as_str(), "png" | "jpg" | "jpeg" | "gif" | "webp" | "ico" | "svg" | "bmp"))
        .unwrap_or_else(|| "png".into());
    let target = icons_dir.join(format!("{}.{ext}", uuid::Uuid::new_v4()));
    crate::paths::write_atomic(&target, &data).map_err(|e| e.to_string())?;
    Ok(target)
}

fn looks_like_image(data: &[u8]) -> bool {
    // PNG, JPEG, GIF, BMP, ICO, RIFF/WEBP, or SVG XML.
    if data.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])
        || data.starts_with(&[0xFF, 0xD8, 0xFF])
        || data.starts_with(b"GIF87a")
        || data.starts_with(b"GIF89a")
        || data.starts_with(b"BM")
        || data.starts_with(&[0x00, 0x00, 0x01, 0x00])
    {
        return true;
    }
    if data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        return true;
    }
    if let Ok(text) = std::str::from_utf8(&data[..data.len().min(512)]) {
        let trimmed = text.trim_start();
        if trimmed.starts_with("<svg") || (trimmed.starts_with("<?xml") && trimmed.contains("<svg")) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn clean_facts() -> AutoPullFacts {
        AutoPullFacts {
            branch: Some("main".into()),
            default_branch: Some("main".into()),
            dirty: false,
            operation_in_progress: false,
            session_working: false,
            ahead: 0,
            behind: 2,
        }
    }

    #[test]
    fn auto_pull_decision_matrix() {
        assert_eq!(AutoPull::decide(&clean_facts()), AutoPullVerdict::FastForward);

        let mut f = clean_facts();
        f.behind = 0;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::UpToDate);

        let mut f = clean_facts();
        f.ahead = 1;
        f.behind = 0;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::UpToDate);

        let mut f = clean_facts();
        f.ahead = 1;
        f.behind = 2;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::Diverged));

        let mut f = clean_facts();
        f.branch = Some("feature".into());
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::NotOnDefaultBranch));

        let mut f = clean_facts();
        f.branch = None;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::NotOnDefaultBranch));

        let mut f = clean_facts();
        f.default_branch = None;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::NoDefaultBranch));

        let mut f = clean_facts();
        f.dirty = true;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::Dirty));

        let mut f = clean_facts();
        f.operation_in_progress = true;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::OperationInProgress));

        let mut f = clean_facts();
        f.session_working = true;
        assert_eq!(AutoPull::decide(&f), AutoPullVerdict::Skip(AutoPullSkipReason::SessionWorking));
    }

    #[test]
    fn auto_pull_counts_and_enabled_anywhere() {
        assert_eq!(AutoPull::parse_counts("0\t3\n"), Some((0, 3)));
        assert_eq!(AutoPull::parse_counts("2 5"), Some((2, 5)));
        assert_eq!(AutoPull::parse_counts("bad"), None);

        let mut overrides = BTreeMap::new();
        assert!(!AutoPull::enabled_anywhere(false, &overrides));
        assert!(AutoPull::enabled_anywhere(true, &overrides));
        overrides.insert("/p".into(), ProjectOverride { auto_pull: Some(false), ..Default::default() });
        assert!(!AutoPull::enabled_anywhere(false, &overrides));
        overrides.insert("/q".into(), ProjectOverride { auto_pull: Some(true), ..Default::default() });
        assert!(AutoPull::enabled_anywhere(false, &overrides));
    }

    #[test]
    fn clone_layout_parse_and_targets() {
        let a = CloneLayout::parse("git@github.com:IAMichan/nook.git").unwrap();
        assert_eq!(a, CloneAddress { host: "github.com".into(), owner: "IAMichan".into(), name: "nook".into() });

        let b = CloneLayout::parse("https://GitLab.com/group/sub/project.git").unwrap();
        assert_eq!(b, CloneAddress { host: "gitlab.com".into(), owner: "group/sub".into(), name: "project".into() });

        let c = CloneLayout::parse("ssh://git@codeberg.org:2222/team/app").unwrap();
        assert_eq!(c, CloneAddress { host: "codeberg.org".into(), owner: "team".into(), name: "app".into() });

        assert!(CloneLayout::parse("not-a-url").is_none());
        assert!(CloneLayout::parse("https://github.com/owner/../evil").is_none());

        let parent = PathBuf::from("dev");
        assert_eq!(CloneLayout::target("git@github.com:IAMichan/nook.git", &parent, false, "nook"), Some(parent.join("nook")));
        assert_eq!(
            CloneLayout::target("git@github.com:IAMichan/nook.git", &parent, true, "nook"),
            Some(parent.join("github.com").join("IAMichan").join("nook"))
        );
        assert_eq!(
            CloneLayout::target("https://gitlab.com/a/b/c.git", &parent, true, "c"),
            Some(parent.join("gitlab.com").join("a").join("b").join("c"))
        );
        assert_eq!(CloneLayout::target("bad", &parent, true, "x"), None);
    }

    #[test]
    fn clone_layout_repository_url_from_page() {
        assert_eq!(
            CloneLayout::repository_url_from_page("https://github.com/owner/repo/tree/main/src?tab=1#L5"),
            "https://github.com/owner/repo"
        );
        assert_eq!(CloneLayout::repository_url_from_page("https://github.com/owner/repo/pull/42"), "https://github.com/owner/repo");
        assert_eq!(
            CloneLayout::repository_url_from_page("https://gitlab.corp.nl/team/sub/app/-/merge_requests/9"),
            "https://gitlab.corp.nl/team/sub/app"
        );
        assert_eq!(CloneLayout::repository_url_from_page("https://gitea.local/me/app/issues"), "https://gitea.local/me/app");
        assert_eq!(CloneLayout::repository_url_from_page("https://gitea.local/me/app/src/branch/main"), "https://gitea.local/me/app");
        assert_eq!(CloneLayout::repository_url_from_page("https://gitlab.corp.nl/team/sub/tree"), "https://gitlab.corp.nl/team/sub/tree");
        assert_eq!(CloneLayout::repository_url_from_page("https://github.com/owner/repo.git"), "https://github.com/owner/repo.git");
        assert_eq!(CloneLayout::repository_url_from_page("git@github.com:owner/repo.git"), "git@github.com:owner/repo.git");
    }

    #[test]
    fn clone_layout_root_and_ssh_fallback() {
        let project = PathBuf::from("Users").join("me").join("src").join("github.com").join("me").join("app");
        assert_eq!(CloneLayout::layout_root(&project), Some(PathBuf::from("Users").join("me").join("src")));
        let flat = PathBuf::from("Users").join("me").join("Developer").join("app");
        assert_eq!(CloneLayout::layout_root(&flat), None);

        assert!(CloneLayout::is_ssh("git@github.com:me/app.git"));
        assert!(CloneLayout::is_ssh("ssh://git@github.com/me/app.git"));
        assert!(!CloneLayout::is_ssh("https://github.com/me/app.git"));
        assert_eq!(CloneLayout::https_fallback("git@github.com:me/app.git").as_deref(), Some("https://github.com/me/app.git"));
        assert_eq!(CloneLayout::https_fallback("ssh://git@github.com:2222/me/app").as_deref(), Some("https://github.com/me/app.git"));
        assert!(CloneLayout::https_fallback("https://github.com/me/app.git").is_none());
        assert!(CloneLayout::ssh_refused("git@github.com: Permission denied (publickey)."));
        assert!(!CloneLayout::ssh_refused("fatal: repository not found"));
    }

    #[test]
    fn prepare_clone_target_accepts_empty_and_ds_store() {
        let dir = temp_dir("nook-clone-target");
        let fresh = dir.join("fresh");
        assert!(CloneLayout::prepare_clone_target(&fresh));

        let empty = dir.join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        assert!(CloneLayout::prepare_clone_target(&empty));

        let ds_only = dir.join("ds");
        std::fs::create_dir_all(&ds_only).unwrap();
        std::fs::write(ds_only.join(".DS_Store"), b"junk").unwrap();
        assert!(CloneLayout::prepare_clone_target(&ds_only));
        assert!(!ds_only.join(".DS_Store").exists());

        let nonempty = dir.join("nonempty");
        std::fs::create_dir_all(&nonempty).unwrap();
        std::fs::write(nonempty.join("README.md"), b"hi").unwrap();
        assert!(!CloneLayout::prepare_clone_target(&nonempty));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn repository_publish_rules() {
        assert!(RepositoryPublish::is_valid_name("my-repo_1.0"));
        assert!(!RepositoryPublish::is_valid_name(""));
        assert!(!RepositoryPublish::is_valid_name("."));
        assert!(!RepositoryPublish::is_valid_name(".."));
        assert!(!RepositoryPublish::is_valid_name("has space"));
        assert!(!RepositoryPublish::is_valid_name(&"a".repeat(101)));

        assert_eq!(RepositoryPublish::suggested_name("My App (2)"), "My-App-2");
        assert_eq!(RepositoryPublish::suggested_name("..."), "project");
        assert_eq!(RepositoryPublish::request_path(None), "/user/repos");
        assert_eq!(RepositoryPublish::request_path(Some("  ")), "/user/repos");
        assert_eq!(RepositoryPublish::request_path(Some("acme")), "/orgs/acme/repos");
        assert_eq!(RepositoryPublish::request_body("demo", true), json!({ "name": "demo", "private": true, "auto_init": false }));
        assert!(RepositoryPublish::can_publish(false, &[]));
        assert!(RepositoryPublish::can_publish(true, &[]));
        assert!(!RepositoryPublish::can_publish(true, &["origin".into()]));
    }

    #[test]
    fn commit_references() {
        assert!(CommitReference::is_hash("a1b2c3d"));
        assert!(CommitReference::is_hash("0123456789abcdef0123456789abcdef01234567"));
        assert!(!CommitReference::is_hash("1234567"));
        assert!(!CommitReference::is_hash("deadbeef"));
        assert!(!CommitReference::is_hash("A1B2C3D"));
        assert!(!CommitReference::is_hash("a1b2c3"));

        assert_eq!(CommitReference::link("A1B2C3D"), "nook-commit:a1b2c3d");
        assert_eq!(CommitReference::hash_in_url("nook-commit:a1b2c3d").as_deref(), Some("a1b2c3d"));
        assert_eq!(CommitReference::hash_in_url("https://github.com/acme/app/commit/a1b2c3d4").as_deref(), Some("a1b2c3d4"));
        assert_eq!(CommitReference::hash_in_url("https://github.com/acme/app/pull/12/commits/f0e1d2c").as_deref(), Some("f0e1d2c"));
        assert!(CommitReference::hash_in_url("https://example.com/acme/app/commit/a1b2c3d").is_none());

        let text = "Fixed in a1b2c3d and f9e8d7c6, not deadbeef or foo/a1b2c3d.";
        let found: Vec<&str> = CommitReference::hashes_in_text(text).into_iter().map(|r| &text[r]).collect();
        assert_eq!(found, vec!["a1b2c3d", "f9e8d7c6"]);
    }

    #[test]
    fn store_project_icon_validates_and_copies() {
        let dir = temp_dir("nook-icon-store");
        let icons = dir.join("icons");
        let png = dir.join("logo.png");
        std::fs::write(&png, [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]).unwrap();
        let stored = store_project_icon(&png, &icons).unwrap();
        assert!(stored.exists());
        assert_eq!(stored.extension().and_then(|e| e.to_str()), Some("png"));

        let bad = dir.join("notes.txt");
        std::fs::write(&bad, b"not an image").unwrap();
        assert!(store_project_icon(&bad, &icons).is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn git_auto_pull_and_publish_end_to_end() {
        let Some(git) = Git::locate() else { return };
        let root = temp_dir("nook-sc-e2e");
        let bare = root.join("remote.git");
        let seed = root.join("seed");
        let checkout = root.join("checkout");
        std::fs::create_dir_all(&bare).unwrap();
        std::fs::create_dir_all(&seed).unwrap();

        let bare_s = bare.to_string_lossy().to_string();
        let seed_s = seed.to_string_lossy().to_string();
        let checkout_s = checkout.to_string_lossy().to_string();

        git.run(&["init", "--bare", "-q", "-b", "main"], &bare_s).unwrap();
        git.run(&["init", "-q", "-b", "main"], &seed_s).unwrap();
        git.run(&["config", "user.email", "t@example.com"], &seed_s).unwrap();
        git.run(&["config", "user.name", "Test"], &seed_s).unwrap();
        std::fs::write(seed.join("a.txt"), "one\n").unwrap();
        git.commit_all(&seed_s, "first", "").unwrap();
        git.run(&["remote", "add", "origin", &bare_s], &seed_s).unwrap();
        git.run(&["push", "-q", "-u", "origin", "main"], &seed_s).unwrap();

        // Clone to checkout
        git.run(&["clone", "-q", &bare_s, &checkout_s], &root.to_string_lossy()).unwrap();
        git.run(&["config", "user.email", "t@example.com"], &checkout_s).unwrap();
        git.run(&["config", "user.name", "Test"], &checkout_s).unwrap();
        assert!(git.main_checkout(&checkout_s).is_some());

        // Already up to date
        assert_eq!(git.auto_pull(&checkout_s, false).unwrap(), AutoPullVerdict::UpToDate);

        // Push a new commit from seed
        std::fs::write(seed.join("b.txt"), "two\n").unwrap();
        git.commit_all(&seed_s, "second", "").unwrap();
        git.run(&["push", "-q", "origin", "main"], &seed_s).unwrap();

        // Skips while session is working in folder
        assert_eq!(git.auto_pull(&checkout_s, true).unwrap(), AutoPullVerdict::Skip(AutoPullSkipReason::SessionWorking));
        assert!(!checkout.join("b.txt").exists());

        // Skips when dirty
        std::fs::write(checkout.join("a.txt"), "edited\n").unwrap();
        assert_eq!(git.auto_pull(&checkout_s, false).unwrap(), AutoPullVerdict::Skip(AutoPullSkipReason::Dirty));
        std::fs::write(checkout.join("a.txt"), "one\n").unwrap();

        // Fast-forwards cleanly once idle & clean
        assert_eq!(git.auto_pull(&checkout_s, false).unwrap(), AutoPullVerdict::FastForward);
        assert!(checkout.join("b.txt").exists());

        // Publish a fresh local folder into a bare remote
        let local = root.join("new-project");
        let dest = root.join("dest.git");
        std::fs::create_dir_all(&local).unwrap();
        std::fs::create_dir_all(&dest).unwrap();
        let local_s = local.to_string_lossy().to_string();
        let dest_s = dest.to_string_lossy().to_string();
        git.run(&["init", "--bare", "-q"], &dest_s).unwrap();
        std::fs::write(local.join("hello.txt"), "hello").unwrap();
        // Configure git identity in local repo after init via env fallback if global isn't set
        git.run(&["init", "-q", "-b", "main"], &local_s).unwrap();
        git.run(&["config", "user.email", "t@example.com"], &local_s).unwrap();
        git.run(&["config", "user.name", "Test"], &local_s).unwrap();
        let branch = git.prepare_publish(&local_s).unwrap();
        assert_eq!(branch, "main");
        assert!(git.has_commits(&local_s));
        git.publish(&local_s, &dest_s, &branch, None).unwrap();
        assert_eq!(git.remotes(&local_s), vec!["origin"]);
        // Publishing again refuses because remote exists
        assert!(git.publish(&local_s, &dest_s, &branch, None).is_err());

        let _ = std::fs::remove_dir_all(&root);
    }
}
