//! A pull request on this computer, to work on it (`PullRequestCheckoutPlan`, `AppModel+PullRequestCheckout` on the Mac,
//! AG-125): in a worktree of its own, or in the folder you are in. Every session after it runs on the branch; the session
//! itself you start, as always.

use std::path::Path;
use std::time::Duration;

use super::git::{Git, GitError};
use super::source_control::RemoteRepository;

/// What `git fetch origin` asks for, and the local branch it lands in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckoutPlan {
    pub repository: String,
    pub number: u64,
    /// What `git fetch origin` asks for.
    pub reference: String,
    /// The local branch.
    pub branch: String,
    /// Only for a branch of the repository itself: pushing goes back to the pull request.
    pub tracks_origin: bool,
}

impl CheckoutPlan {
    /// A branch of the repository itself is fetched by name; a fork's (or an unknown head) by the pull request's own ref.
    pub fn new(repository: &str, number: u64, head_branch: &str, fork: bool) -> Self {
        if !fork && !head_branch.is_empty() {
            return Self { repository: repository.into(), number, reference: head_branch.into(), branch: head_branch.into(), tracks_origin: true };
        }
        Self::pull_ref(repository, number)
    }

    /// The pull request's own ref, which a fork's head is only reachable by.
    pub fn pull_ref(repository: &str, number: u64) -> Self {
        Self { repository: repository.into(), number, reference: format!("pull/{number}/head"), branch: format!("pr-{number}"), tracks_origin: false }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckoutMode {
    Worktree,
    Here,
}

/// The folder of this repository on this computer: the session's, else a favorite or recent project.
pub fn local_folder(git: &Git, repository: &str, folders: &[String]) -> Option<String> {
    let wanted = repository.to_lowercase();
    let mut seen = std::collections::HashSet::new();
    folders.iter().filter(|f| !f.is_empty() && Path::new(f).exists() && seen.insert(f.to_lowercase())).find_map(|f| {
        let url = git.remote_url(f, "origin")?;
        (RemoteRepository::detect(&url)?.path.to_lowercase() == wanted).then(|| f.clone())
    })
}

fn fetch(git: &Git, plan: &CheckoutPlan, repo: &str) -> Result<(), GitError> {
    // Never forced: a local branch with commits of its own refuses.
    let spec = format!("{}:refs/heads/{}", plan.reference, plan.branch);
    git.run_with(&["fetch", "origin", &spec], repo, Duration::from_secs(180), &[0], &Default::default())?;
    if plan.tracks_origin {
        let _ = git.run(&["branch", &format!("--set-upstream-to=origin/{}", plan.branch), &plan.branch], repo);
    }
    Ok(())
}

/// Fetches the plan, and when the branch of the repository itself is not there (a fork's head), the pull request's own ref.
fn fetch_with_fallback(git: &Git, plan: &CheckoutPlan, repo: &str) -> Result<CheckoutPlan, GitError> {
    match fetch(git, plan, repo) {
        Ok(()) => Ok(plan.clone()),
        Err(e) if plan.tracks_origin => {
            let own = CheckoutPlan::pull_ref(&plan.repository, plan.number);
            fetch(git, &own, repo).map(|_| own).map_err(|_| e)
        }
        Err(e) => Err(e),
    }
}

/// Makes a worktree of its own on the pull request's branch and returns its path.
pub fn worktree(git: &Git, plan: &CheckoutPlan, folder: &str, worktree_root: &str, reserved: &[String]) -> Result<String, GitError> {
    let root = git.repository_root(folder).unwrap_or_else(|| folder.to_string());
    let plan = fetch_with_fallback(git, plan, &root)?;
    let repo_name = Path::new(&root).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let path = super::models::worktree_path(worktree_root, &repo_name, &super::models::slug(&plan.branch.replace('/', "-"), 60), |p| {
        reserved.iter().any(|r| r == p) || Path::new(p).exists()
    });
    if let Some(parent) = Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| GitError(e.to_string()))?;
    }
    git.run_with(&["worktree", "add", "--", &path, &plan.branch], &root, Duration::from_secs(180), &[0], &Default::default())?;
    Ok(path)
}

/// The pull request's branch in the folder itself. Refuses with changes in it, so nothing of yours gets mixed in.
pub fn here(git: &Git, plan: &CheckoutPlan, folder: &str, dirty: &str) -> Result<String, GitError> {
    if !git.status(folder)?.is_clean() {
        return Err(GitError(dirty.into()));
    }
    let plan = fetch_with_fallback(git, plan, folder)?;
    git.run(&["switch", &plan.branch], folder)?;
    Ok(folder.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_by_branch_or_pull_ref() {
        let own = CheckoutPlan::new("a/b", 7, "feature/x", false);
        assert_eq!((own.reference.as_str(), own.branch.as_str(), own.tracks_origin), ("feature/x", "feature/x", true));
        let fork = CheckoutPlan::new("a/b", 7, "main", true);
        assert_eq!((fork.reference.as_str(), fork.branch.as_str(), fork.tracks_origin), ("pull/7/head", "pr-7", false));
        assert_eq!(CheckoutPlan::new("a/b", 8, "", false).branch, "pr-8");
    }

    fn sh(git: &Git, dir: &str, args: &[&str]) {
        git.run(args, dir).unwrap();
    }

    #[test]
    fn checks_out_a_pull_request_in_a_worktree_and_here() {
        let Some(git) = Git::locate() else { return };
        let base = std::env::temp_dir().join(format!("nook-pr-{}", uuid::Uuid::new_v4()));
        let origin = base.join("origin");
        let clone = base.join("clone");
        std::fs::create_dir_all(&origin).unwrap();
        let (o, c) = (origin.to_string_lossy().into_owned(), clone.to_string_lossy().into_owned());
        sh(&git, &o, &["init", "-b", "main"]);
        sh(&git, &o, &["config", "user.email", "t@nook.local"]);
        sh(&git, &o, &["config", "user.name", "T"]);
        std::fs::write(origin.join("a.txt"), "1\n").unwrap();
        sh(&git, &o, &["add", "."]);
        sh(&git, &o, &["commit", "-m", "one"]);
        sh(&git, &o, &["checkout", "-b", "feature"]);
        std::fs::write(origin.join("a.txt"), "2\n").unwrap();
        sh(&git, &o, &["commit", "-am", "two"]);
        sh(&git, &o, &["checkout", "main"]);
        git.run(&["clone", &o, &c], &base.to_string_lossy()).unwrap();

        let plan = CheckoutPlan::new("a/b", 1, "feature", false);
        let root = base.join("wt").to_string_lossy().into_owned();
        let path = worktree(&git, &plan, &c, &root, &[]).unwrap();
        assert_eq!(std::fs::read_to_string(Path::new(&path).join("a.txt")).unwrap(), "2\n");
        // A second worktree of the same branch: git refuses, with its own words.
        assert!(worktree(&git, &plan, &c, &root, &[]).is_err());

        // Here: refuses with changes, works when clean.
        std::fs::write(clone.join("dirty.txt"), "x").unwrap();
        assert!(here(&git, &CheckoutPlan::new("a/b", 1, "main", false), &c, "dirty").is_err());
        std::fs::remove_file(clone.join("dirty.txt")).unwrap();
        git.run(&["worktree", "remove", "--force", &path], &c).unwrap();
        git.run(&["branch", "-D", "feature"], &c).unwrap();
        assert_eq!(here(&git, &plan, &c, "dirty").unwrap(), c);
        assert_eq!(git.current_branch(&c).as_deref(), Some("feature"));

        let found = local_folder(&git, "x/y", &[c.clone()]);
        assert!(found.is_none());
        let _ = std::fs::remove_dir_all(&base);
    }
}
