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
            return Self {
                repository: repository.into(),
                number,
                reference: head_branch.into(),
                branch: head_branch.into(),
                tracks_origin: true,
            };
        }
        Self::pull_ref(repository, number)
    }

    /// The pull request's own ref, which a fork's head is only reachable by.
    pub fn pull_ref(repository: &str, number: u64) -> Self {
        Self {
            repository: repository.into(),
            number,
            reference: format!("pull/{number}/head"),
            branch: format!("pr-{number}"),
            tracks_origin: false,
        }
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

/// Checks out the pull request according to `mode` (`Worktree` or `Here`) and returns the resulting folder path.
pub fn checkout(
    git: &Git,
    plan: &CheckoutPlan,
    mode: CheckoutMode,
    folder: &str,
    worktree_root: &str,
    reserved: &[String],
    dirty: &str,
) -> Result<String, GitError> {
    match mode {
        CheckoutMode::Worktree => worktree(git, plan, folder, worktree_root, reserved),
        CheckoutMode::Here => here(git, plan, folder, dirty),
    }
}

// ============================================================================
// AG-121: Disk space warning threshold, BuildLeftovers, WorktreeArchive, WorktreeMove
// ============================================================================

/// Disk space threshold with hysteresis (`DiskSpace` in `BuildLeftovers.swift`, AG-121).
pub mod disk_space {
    use std::path::Path;

    /// Below 25 GB free triggers a low-disk warning.
    pub const LOW_BYTES: u64 = 25_000_000_000;
    /// Recovers once free space reaches 40 GB.
    pub const RECOVERED_BYTES: u64 = 40_000_000_000;

    pub fn is_low(available: u64, was_low: bool) -> bool {
        available < if was_low { RECOVERED_BYTES } else { LOW_BYTES }
    }

    /// Reads the available bytes on the volume hosting `path` (or its closest existing ancestor).
    pub fn available_bytes(path: &Path) -> Option<u64> {
        let mut cursor = Some(path);
        while let Some(p) = cursor {
            if p.exists() {
                return platform_available_bytes(p);
            }
            cursor = p.parent();
        }
        None
    }

    #[cfg(unix)]
    fn platform_available_bytes(path: &Path) -> Option<u64> {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;
        unsafe {
            let mut stat: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c_path.as_ptr(), &mut stat) == 0 {
                let bavail = stat.f_bavail as u64;
                let frsize = if stat.f_frsize > 0 { stat.f_frsize as u64 } else { stat.f_bsize as u64 };
                Some(bavail.saturating_mul(frsize))
            } else {
                None
            }
        }
    }

    #[cfg(windows)]
    fn platform_available_bytes(path: &Path) -> Option<u64> {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        extern "system" {
            fn GetDiskFreeSpaceExW(
                lpDirectoryName: *const u16,
                lpFreeBytesAvailableToCaller: *mut u64,
                lpTotalNumberOfBytes: *mut u64,
                lpTotalNumberOfFreeBytes: *mut u64,
            ) -> i32;
        }
        let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
        wide.push(0);
        let mut free: u64 = 0;
        let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free, std::ptr::null_mut(), std::ptr::null_mut()) };
        (ok != 0).then_some(free)
    }

    #[cfg(not(any(unix, windows)))]
    fn platform_available_bytes(_path: &Path) -> Option<u64> {
        None
    }
}

/// Build leftovers left outside or inside worktrees (`BuildLeftovers.swift`, AG-121).
pub mod build_leftovers {
    use serde::{Deserialize, Serialize};
    use std::collections::HashSet;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime};

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    pub enum LeftoverKind {
        TestPackage,
        XcodeBuild,
        OrphanedDerivedData,
        Dependencies,
    }

    #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    pub struct Leftover {
        pub path: PathBuf,
        pub kind: LeftoverKind,
        pub size_bytes: u64,
    }

    #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    pub struct RemovedLeftover {
        pub leftover: Leftover,
        pub bytes: u64,
    }

    #[derive(Debug, Clone, Default)]
    pub struct Roots {
        pub temporary: Vec<PathBuf>,
        pub scratchpad_parents: Vec<PathBuf>,
        pub derived_data: Option<PathBuf>,
        pub worktrees: Vec<PathBuf>,
        pub settled_worktrees: HashSet<PathBuf>,
        pub idle_worktrees: HashSet<PathBuf>,
    }

    /// 2 days for active/open worktrees and temporary folders.
    pub const STALE_AFTER: Duration = Duration::from_secs(2 * 86_400);
    /// 1 hour for settled (merged/archived) worktrees.
    pub const SETTLED_STALE_AFTER: Duration = Duration::from_secs(60 * 60);

    const DEPENDENCY_FOLDERS: &[&str] = &["node_modules", "target", ".next", "dist", ".turbo"];

    const TEST_PACKAGE_PREFIXES: &[&str] = &["nook-core-tests", "nook-core", "nook-tests", "nook-test", "coretests", "nook-pkg"];

    const XCODE_BUILD_PREFIXES: &[&str] = &["nook-dd", "nook-build", "nook-derived", "dd"];

    /// Normalizes a folder path into a canonical or slash-trimmed prefix with a trailing `/`.
    fn folder_prefix(path: &str) -> Option<String> {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            return None;
        }
        let resolved = std::fs::canonicalize(trimmed)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| trimmed.trim_end_matches(['/', '\\']).to_string());
        let clean = resolved.replace('\\', "/");
        let clean = clean.trim_end_matches('/');
        if clean.is_empty() {
            return None;
        }
        Some(format!("{clean}/"))
    }

    /// Resolves busy working directories once for a whole sweep.
    pub fn held_folders(busy: &[String]) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for b in busy {
            if let Some(p) = folder_prefix(b) {
                if seen.insert(p.clone()) {
                    out.push(p);
                }
            }
        }
        out
    }

    /// A worktree is idle unless it is a main checkout or a busy process works in it or in a subfolder of it.
    pub fn is_idle(worktree: &str, busy: &[String], main_checkouts: &[String]) -> bool {
        let held = held_folders(busy);
        is_idle_with_held(worktree, &held, main_checkouts)
    }

    pub fn is_idle_with_held(worktree: &str, held: &[String], main_checkouts: &[String]) -> bool {
        let Some(wt) = folder_prefix(worktree) else { return false };
        for main in main_checkouts {
            if folder_prefix(main).as_deref() == Some(wt.as_str()) {
                return false;
            }
        }
        !held.iter().any(|h| h.starts_with(&wt))
    }

    /// Bounded recursive directory size in bytes.
    pub fn folder_size(path: &Path) -> u64 {
        let mut budget = 8_000usize;
        dir_size_bounded(path, &mut budget)
    }

    fn dir_size_bounded(path: &Path, budget: &mut usize) -> u64 {
        if *budget == 0 {
            return 0;
        }
        let Ok(entries) = std::fs::read_dir(path) else { return 0 };
        let mut total = 0u64;
        for entry in entries.flatten() {
            if *budget == 0 {
                break;
            }
            *budget -= 1;
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                total = total.saturating_add(dir_size_bounded(&entry.path(), budget));
            } else if ft.is_file() {
                total = total.saturating_add(entry.metadata().map(|m| m.len()).unwrap_or(0));
            }
        }
        total
    }

    /// Finds all stale build leftovers across `roots` at `now`.
    pub fn find(roots: &Roots, now: SystemTime) -> Vec<Leftover> {
        let mut found = Vec::new();
        let mut seen = HashSet::new();

        for tmp in &roots.temporary {
            let Ok(entries) = std::fs::read_dir(tmp) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if let Some(kind) = temporary_kind(&path, now) {
                    push_unique(&mut found, &mut seen, path, kind);
                }
            }
        }

        for parent in &roots.scratchpad_parents {
            for scratchpad in scratchpads(parent) {
                let Ok(entries) = std::fs::read_dir(&scratchpad) else { continue };
                for entry in entries.flatten() {
                    let path = entry.path();
                    if is_xcode_build(&path, now, STALE_AFTER) {
                        push_unique(&mut found, &mut seen, path, LeftoverKind::XcodeBuild);
                    }
                }
            }
        }

        let settled_norm: HashSet<PathBuf> =
            roots.settled_worktrees.iter().map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| p.clone())).collect();
        let idle_norm: HashSet<PathBuf> =
            roots.idle_worktrees.iter().map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| p.clone())).collect();

        for worktree in &roots.worktrees {
            let scratch = worktree.join(".scratch");
            if let Ok(entries) = std::fs::read_dir(&scratch) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if let Some(kind) = scratch_kind(&path, now) {
                        push_unique(&mut found, &mut seen, path, kind);
                    }
                }
            }
            let wt_canon = std::fs::canonicalize(worktree).unwrap_or_else(|_| worktree.clone());
            let build_age = if settled_norm.contains(&wt_canon) { SETTLED_STALE_AFTER } else { STALE_AFTER };
            let build_dir = worktree.join(".build");
            if let Ok(entries) = std::fs::read_dir(&build_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if is_xcode_build(&path, now, build_age) {
                        push_unique(&mut found, &mut seen, path, LeftoverKind::XcodeBuild);
                    }
                }
            }
            if idle_norm.contains(&wt_canon) {
                for dep in dependency_folders(worktree, 0) {
                    push_unique(&mut found, &mut seen, dep, LeftoverKind::Dependencies);
                }
            }
        }

        if let Some(ref dd) = roots.derived_data {
            if let Ok(entries) = std::fs::read_dir(dd) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if is_orphaned_derived_data(&path) {
                        push_unique(&mut found, &mut seen, path, LeftoverKind::OrphanedDerivedData);
                    }
                }
            }
        }

        found
    }

    /// Removes every build leftover found in `roots` and returns what was removed with its size.
    pub fn sweep(roots: &Roots, now: SystemTime) -> Vec<RemovedLeftover> {
        let mut removed = Vec::new();
        for mut item in find(roots, now) {
            let bytes = if item.size_bytes > 0 { item.size_bytes } else { folder_size(&item.path) };
            item.size_bytes = bytes;
            if std::fs::remove_dir_all(&item.path).is_ok() {
                removed.push(RemovedLeftover { leftover: item, bytes });
            }
        }
        removed
    }

    fn push_unique(found: &mut Vec<Leftover>, seen: &mut HashSet<PathBuf>, path: PathBuf, kind: LeftoverKind) {
        let key = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        if seen.insert(key) {
            let size_bytes = folder_size(&path);
            found.push(Leftover { path, kind, size_bytes });
        }
    }

    fn temporary_kind(folder: &Path, now: SystemTime) -> Option<LeftoverKind> {
        let name = folder.file_name()?.to_string_lossy().to_lowercase();
        if TEST_PACKAGE_PREFIXES.iter().any(|p| name.starts_with(p)) && is_stale_build(folder, now, STALE_AFTER) {
            return Some(LeftoverKind::TestPackage);
        }
        if XCODE_BUILD_PREFIXES.iter().any(|p| name.starts_with(p)) && is_xcode_build(folder, now, STALE_AFTER) {
            return Some(LeftoverKind::XcodeBuild);
        }
        None
    }

    fn scratch_kind(folder: &Path, now: SystemTime) -> Option<LeftoverKind> {
        if is_xcode_build(folder, now, STALE_AFTER) {
            return Some(LeftoverKind::XcodeBuild);
        }
        if is_swift_test_package(folder) && is_stale_build(folder, now, STALE_AFTER) {
            return Some(LeftoverKind::TestPackage);
        }
        None
    }

    fn is_swift_test_package(folder: &Path) -> bool {
        folder.join("Package.swift").is_file() && folder.join("Tests/CoreTests").is_dir()
    }

    fn is_stale_build(folder: &Path, now: SystemTime, stale_after: Duration) -> bool {
        let build = folder.join("Build");
        is_real_directory(&build) && is_older(&build, now, stale_after) && is_older(folder, now, stale_after)
    }

    fn is_xcode_build(folder: &Path, now: SystemTime, stale_after: Duration) -> bool {
        is_stale_build(folder, now, stale_after) && workspace_path(folder).is_some()
    }

    fn is_orphaned_derived_data(folder: &Path) -> bool {
        let Some(ws) = workspace_path(folder) else { return false };
        let norm = ws.replace('\\', "/");
        if !norm.contains("/worktrees/") {
            return false;
        }
        !Path::new(&ws).exists()
    }

    /// Reads `WorkspacePath` from an Xcode `info.plist` (XML or key-value text).
    fn workspace_path(folder: &Path) -> Option<String> {
        let plist = std::fs::read_to_string(folder.join("info.plist")).ok()?;
        let key_idx = plist.find("<key>WorkspacePath</key>")?;
        let after_key = &plist[key_idx + "<key>WorkspacePath</key>".len()..];
        let start_tag = after_key.find("<string>")?;
        let after_start = &after_key[start_tag + "<string>".len()..];
        let end_tag = after_start.find("</string>")?;
        let val = after_start[..end_tag].trim();
        (!val.is_empty()).then(|| val.to_string())
    }

    fn is_real_directory(path: &Path) -> bool {
        std::fs::symlink_metadata(path).map(|m| m.file_type().is_dir() && !m.file_type().is_symlink()).unwrap_or(false)
    }

    fn is_older(path: &Path, now: SystemTime, age: Duration) -> bool {
        let Ok(meta) = std::fs::metadata(path) else { return false };
        let Ok(modified) = meta.modified() else { return false };
        now.duration_since(modified).map(|d| d >= age).unwrap_or(false)
    }

    fn dependency_folders(folder: &Path, depth: usize) -> Vec<PathBuf> {
        if depth > 4 {
            return Vec::new();
        }
        let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
        let mut found = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if !is_real_directory(&path) {
                continue;
            }
            let Some(name_os) = path.file_name() else { continue };
            let name = name_os.to_string_lossy();
            if DEPENDENCY_FOLDERS.contains(&name.as_ref()) {
                found.push(path);
            } else if !name.starts_with('.') {
                found.extend(dependency_folders(&path, depth + 1));
            }
        }
        found
    }

    fn scratchpads(parent: &Path) -> Vec<PathBuf> {
        let Ok(projects) = std::fs::read_dir(parent) else { return Vec::new() };
        let mut found = Vec::new();
        for project in projects.flatten() {
            let Ok(sessions) = std::fs::read_dir(project.path()) else { continue };
            for session in sessions.flatten() {
                let pad = session.path().join("scratchpad");
                if is_real_directory(&pad) {
                    found.push(pad);
                }
            }
        }
        found
    }
}

/// Keeps a removed worktree's `.scratch` files (screenshots, previews, notes) in `~/.nook/worktree-archive`
/// (`WorktreeArchive.swift`, AG-121).
pub mod worktree_archive {
    use sha2::{Digest, Sha256};
    use std::collections::HashSet;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime};

    pub const MAX_BYTES: u64 = 128 * 1024 * 1024;
    pub const MAX_TOTAL_BYTES: u64 = 1024 * 1024 * 1024;
    pub const KEEP_FOR: Duration = Duration::from_secs(30 * 86_400);

    const SKIPPED_NAMES: &[&str] = &[
        ".git",
        ".build",
        "Build",
        "DerivedData",
        "ModuleCache.noindex",
        "node_modules",
        ".next",
        "target",
        "dist",
        ".turbo",
        "__pycache__",
        ".pytest_cache",
        ".venv",
        "venv",
    ];

    pub fn default_root() -> PathBuf {
        let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into());
        PathBuf::from(home).join(".nook").join("worktree-archive")
    }

    fn normalize(path: &str) -> String {
        let p = Path::new(path);
        let resolved = if let Ok(canon) = std::fs::canonicalize(p) {
            canon.to_string_lossy().into_owned()
        } else {
            // When the worktree itself has already been deleted, canonicalize its nearest
            // existing ancestor so symlinked roots (e.g. /var -> /private/var) still hash identically.
            let mut cur = p;
            let mut tail = Vec::new();
            while let (Some(parent), Some(name)) = (cur.parent(), cur.file_name()) {
                tail.push(name.to_os_string());
                cur = parent;
                if let Ok(mut base) = std::fs::canonicalize(cur) {
                    for part in tail.into_iter().rev() {
                        base.push(part);
                    }
                    let s = base.to_string_lossy().replace('\\', "/");
                    let trimmed = s.trim_end_matches('/');
                    return if trimmed.is_empty() { "/".into() } else { trimmed.into() };
                }
            }
            path.to_string()
        };
        let s = resolved.replace('\\', "/");
        let trimmed = s.trim_end_matches('/');
        if trimmed.is_empty() {
            "/".into()
        } else {
            trimmed.into()
        }
    }

    pub fn relative_path(file: &str, worktree: &str) -> Option<String> {
        let base = normalize(worktree);
        let prefix = if base == "/" { "/".to_string() } else { format!("{base}/") };
        for candidate in [file.replace('\\', "/"), normalize(file)] {
            if let Some(rel) = candidate.strip_prefix(&prefix) {
                if !rel.is_empty() {
                    return Some(rel.to_string());
                }
            }
        }
        None
    }

    pub fn location(worktree: &str, root: &Path) -> PathBuf {
        let canonical = normalize(worktree);
        let name = Path::new(&canonical)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| "worktree".into());
        let mut slug = String::new();
        let mut last_dash = false;
        for c in name.chars() {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
                slug.push(c);
                last_dash = false;
            } else if !last_dash && !slug.is_empty() {
                slug.push('-');
                last_dash = true;
            }
        }
        let slug = slug.trim_matches('-');
        let slug = if slug.is_empty() { "worktree" } else { slug };
        let slug: String = slug.chars().take(48).collect();
        let digest = Sha256::digest(canonical.as_bytes());
        let hash: String = digest[..6].iter().map(|b| format!("{b:02x}")).collect();
        root.join(format!("{slug}-{hash}"))
    }

    /// Copies `<worktree>/.scratch` into the archive root before the worktree is removed.
    pub fn save(worktree: &str, root: &Path) -> bool {
        save_with_limits(worktree, root, MAX_BYTES, MAX_TOTAL_BYTES, SystemTime::now())
    }

    pub fn save_with_limits(worktree: &str, root: &Path, max_bytes: u64, max_total_bytes: u64, now: SystemTime) -> bool {
        let scratch = Path::new(worktree).join(".scratch");
        if !is_real_directory(&scratch) {
            return false;
        }
        let files = collect_files(&scratch);
        let total: u64 = files.iter().map(|(_, s)| *s).sum();
        if files.is_empty() || total == 0 || total > max_bytes {
            return false;
        }
        let dest_root = location(worktree, root);
        let dest = dest_root.join(".scratch");
        let _ = std::fs::remove_dir_all(&dest_root);
        let base = scratch.to_string_lossy().replace('\\', "/");
        let prefix = format!("{}/", base.trim_end_matches('/'));
        for (source, _) in files {
            let src_str = source.to_string_lossy().replace('\\', "/");
            let Some(rel) = src_str.strip_prefix(&prefix) else { continue };
            let target = dest.join(rel);
            if let Some(parent) = target.parent() {
                if std::fs::create_dir_all(parent).is_err() {
                    let _ = std::fs::remove_dir_all(&dest_root);
                    return false;
                }
            }
            if std::fs::copy(&source, &target).is_err() {
                let _ = std::fs::remove_dir_all(&dest_root);
                return false;
            }
        }
        set_modified(&dest_root, now);
        prune(root, now);
        limit(root, max_total_bytes, Some(&dest_root));
        true
    }

    /// Resolves `file` (which used to live inside `worktree`) to its archived copy, or to an unambiguous `.scratch` match.
    pub fn archived(file: &str, worktree: &str, root: &Path) -> Option<String> {
        let archive = location(worktree, root);
        if let Some(rel) = relative_path(file, worktree) {
            let candidate = archive.join(&rel);
            if candidate.exists() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
        let name = Path::new(file).file_name()?.to_string_lossy().into_owned();
        if name.is_empty() {
            return None;
        }
        scratch_file(&name, &archive.to_string_lossy())
    }

    /// Finds a file by name inside `<folder>/.scratch` when there is only one match.
    pub fn scratch_file(named: &str, folder: &str) -> Option<String> {
        if named.is_empty() {
            return None;
        }
        let scratch = Path::new(folder).join(".scratch");
        if !is_real_directory(&scratch) {
            return None;
        }
        let mut found: Option<String> = None;
        for (file, _) in collect_files(&scratch) {
            if file.file_name().map(|n| n.to_string_lossy()) == Some(named.into()) {
                if found.is_some() {
                    return None;
                }
                found = Some(file.to_string_lossy().into_owned());
            }
        }
        found
    }

    /// Removes archives older than `KEEP_FOR`.
    pub fn prune(root: &Path, now: SystemTime) {
        let Ok(entries) = std::fs::read_dir(root) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            let Ok(modified) = meta.modified() else { continue };
            if now.duration_since(modified).map(|d| d > KEEP_FOR).unwrap_or(false) {
                let _ = std::fs::remove_dir_all(path);
            }
        }
    }

    /// Evicts oldest archives when total size exceeds `max_total_bytes`, keeping `keeping`.
    pub fn limit(root: &Path, max_total_bytes: u64, keeping: Option<&Path>) {
        let Ok(entries) = std::fs::read_dir(root) else { return };
        let keep_name = keeping.and_then(|p| p.file_name()).map(|n| n.to_os_string());
        let mut archives: Vec<(PathBuf, SystemTime, u64)> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if !is_real_directory(&path) {
                continue;
            }
            let date = entry.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
            let bytes: u64 = collect_files(&path).iter().map(|(_, s)| *s).sum();
            archives.push((path, date, bytes));
        }
        let mut total: u64 = archives.iter().map(|(_, _, b)| *b).sum();
        if total <= max_total_bytes {
            return;
        }
        archives.sort_by_key(|(_, d, _)| *d);
        for (path, _, bytes) in archives {
            if total <= max_total_bytes {
                break;
            }
            if keep_name.as_ref().is_some_and(|k| path.file_name() == Some(k.as_os_str())) {
                continue;
            }
            if std::fs::remove_dir_all(&path).is_ok() {
                total = total.saturating_sub(bytes);
            }
        }
    }

    fn collect_files(folder: &Path) -> Vec<(PathBuf, u64)> {
        let skipped: HashSet<&str> = SKIPPED_NAMES.iter().copied().collect();
        let mut out = Vec::new();
        collect_inner(folder, folder, &skipped, &mut out);
        out
    }

    fn collect_inner(root: &Path, current: &Path, skipped: &HashSet<&str>, out: &mut Vec<(PathBuf, u64)>) {
        let Ok(entries) = std::fs::read_dir(current) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            let Some(name_os) = path.file_name() else { continue };
            let name = name_os.to_string_lossy();
            if skipped.contains(name.as_ref()) {
                continue;
            }
            if ft.is_dir() {
                if path != root && path.join(".git").exists() {
                    continue;
                }
                collect_inner(root, &path, skipped, out);
            } else if ft.is_file() {
                let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
                out.push((path, size));
            }
        }
    }

    fn is_real_directory(path: &Path) -> bool {
        std::fs::symlink_metadata(path).map(|m| m.file_type().is_dir() && !m.file_type().is_symlink()).unwrap_or(false)
    }

    fn set_modified(path: &Path, time: SystemTime) {
        if let Ok(file) = std::fs::File::open(path) {
            let _ = file.set_modified(time);
        }
    }
}

/// Detects when an agent moves its session into a newly added worktree (`WorktreeMove.swift`, AG-121).
pub mod worktree_move {
    use std::path::{Component, Path};

    const VALUE_FLAGS: &[&str] = &["-b", "-B", "--reason"];
    const GIT_VALUE_FLAGS: &[&str] = &["-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"];

    /// Normalizes a path by resolving `.` and `..` lexically without requiring the target to exist on disk.
    pub fn normalize(path: &str) -> String {
        let replaced = path.trim().replace('\\', "/");
        let is_abs = replaced.starts_with('/');
        let mut parts: Vec<&str> = Vec::new();
        for seg in replaced.split('/') {
            match seg {
                "" | "." => {}
                ".." => {
                    parts.pop();
                }
                s => parts.push(s),
            }
        }
        if is_abs {
            format!("/{}", parts.join("/"))
        } else if parts.is_empty() {
            ".".into()
        } else {
            parts.join("/")
        }
    }

    fn resolve(path: &str, base: &str) -> String {
        if path.starts_with('/') {
            return normalize(path);
        }
        if let Some(rest) = path.strip_prefix("~/") {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
            return normalize(&format!("{home}/{rest}"));
        }
        let p = Path::new(base).join(path);
        let mut comps = Vec::new();
        for c in p.components() {
            match c {
                Component::RootDir => comps.push("/".to_string()),
                Component::CurDir => {}
                Component::ParentDir => {
                    if comps.len() > 1 {
                        comps.pop();
                    }
                }
                Component::Normal(s) => comps.push(s.to_string_lossy().into_owned()),
                Component::Prefix(p) => comps.push(p.as_os_str().to_string_lossy().into_owned()),
            }
        }
        if comps.first().map(|s| s.as_str()) == Some("/") {
            format!("/{}", comps[1..].join("/"))
        } else {
            comps.join("/")
        }
    }

    /// Returns the absolute folder path created by a `git worktree add` inside `command` run from `cwd`, if any.
    pub fn added(command: &str, cwd: &str) -> Option<String> {
        if !command.contains("worktree") {
            return None;
        }
        let mut directory = cwd.to_string();
        let mut added_path: Option<String> = None;
        for part in split_commands(command) {
            let tokens = words(&part);
            let Some(first) = tokens.first().map(|s| s.as_str()) else { continue };
            if first == "cd" {
                if let Some(target) = tokens.get(1) {
                    if target != "-" {
                        directory = resolve(target, &directory);
                    }
                }
            } else if first == "git" || first.ends_with("/git") {
                if let Some(target) = worktree_add_path(&tokens, &directory) {
                    added_path = Some(target);
                }
            }
        }
        added_path
    }

    /// Whether a session should follow a newly added worktree `added`:
    /// true when its own worktree checkout is gone, or when any changed file lives under `added`.
    pub fn follows(own_is_checkout: bool, added: &str, changed_files: &[String]) -> bool {
        if !own_is_checkout {
            return true;
        }
        let root = format!("{}/", normalize(added).trim_end_matches('/'));
        changed_files.iter().any(|f| normalize(f).starts_with(&root))
    }

    fn worktree_add_path(tokens: &[String], cwd: &str) -> Option<String> {
        let mut base = cwd.to_string();
        let mut i = 1usize;
        while i < tokens.len() {
            let token = tokens[i].as_str();
            if token == "-C" {
                if i + 1 < tokens.len() {
                    base = resolve(&tokens[i + 1], &base);
                    i += 2;
                    continue;
                }
                return None;
            }
            if GIT_VALUE_FLAGS.contains(&token) {
                i += 2;
                continue;
            }
            if token.starts_with('-') {
                i += 1;
                continue;
            }
            break;
        }
        if i + 1 >= tokens.len() || tokens[i] != "worktree" || tokens[i + 1] != "add" {
            return None;
        }
        i += 2;
        while i < tokens.len() {
            let token = tokens[i].as_str();
            if token == "--" {
                return tokens.get(i + 1).map(|t| resolve(t, &base));
            }
            if VALUE_FLAGS.contains(&token) {
                i += 2;
                continue;
            }
            if token.starts_with('-') {
                i += 1;
                continue;
            }
            return Some(resolve(token, &base));
        }
        None
    }

    fn split_commands(command: &str) -> Vec<String> {
        let mut parts = Vec::new();
        let mut current = String::new();
        let mut quote: Option<char> = None;
        let mut escaped = false;
        let mut chars = command.chars().peekable();
        while let Some(c) = chars.next() {
            if escaped {
                current.push(c);
                escaped = false;
                continue;
            }
            if c == '\\' && quote != Some('\'') {
                escaped = true;
                current.push(c);
                continue;
            }
            if let Some(q) = quote {
                if c == q {
                    quote = None;
                }
                current.push(c);
                continue;
            }
            if c == '\'' || c == '"' {
                quote = Some(c);
                current.push(c);
                continue;
            }
            if c == ';' || c == '\n' {
                parts.push(std::mem::take(&mut current));
                continue;
            }
            if (c == '&' || c == '|') && chars.peek() == Some(&c) {
                chars.next();
                parts.push(std::mem::take(&mut current));
                continue;
            }
            current.push(c);
        }
        parts.push(current);
        parts
    }

    fn words(segment: &str) -> Vec<String> {
        let mut tokens = Vec::new();
        let mut current = String::new();
        let mut in_word = false;
        let mut quote: Option<char> = None;
        let mut escaped = false;
        for c in segment.chars() {
            if escaped {
                current.push(c);
                in_word = true;
                escaped = false;
                continue;
            }
            if c == '\\' && quote != Some('\'') {
                escaped = true;
                in_word = true;
                continue;
            }
            if let Some(q) = quote {
                if c == q {
                    quote = None;
                } else {
                    current.push(c);
                }
                in_word = true;
                continue;
            }
            if c == '\'' || c == '"' {
                quote = Some(c);
                in_word = true;
                continue;
            }
            if c.is_whitespace() {
                if in_word {
                    tokens.push(std::mem::take(&mut current));
                    in_word = false;
                }
                continue;
            }
            current.push(c);
            in_word = true;
        }
        if in_word {
            tokens.push(current);
        }
        tokens
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{Duration, SystemTime};

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
        let path = checkout(&git, &plan, CheckoutMode::Worktree, &c, &root, &[], "dirty").unwrap();
        assert_eq!(std::fs::read_to_string(Path::new(&path).join("a.txt")).unwrap(), "2\n");
        // A second worktree of the same branch: git refuses, with its own words.
        assert!(worktree(&git, &plan, &c, &root, &[]).is_err());

        // Here: refuses with changes, works when clean.
        std::fs::write(clone.join("dirty.txt"), "x").unwrap();
        assert!(here(&git, &CheckoutPlan::new("a/b", 1, "main", false), &c, "dirty").is_err());
        std::fs::remove_file(clone.join("dirty.txt")).unwrap();
        git.run(&["worktree", "remove", "--force", &path], &c).unwrap();
        git.run(&["branch", "-D", "feature"], &c).unwrap();
        assert_eq!(checkout(&git, &plan, CheckoutMode::Here, &c, &root, &[], "dirty").unwrap(), c);
        assert_eq!(git.current_branch(&c).as_deref(), Some("feature"));

        let found = local_folder(&git, "x/y", std::slice::from_ref(&c));
        assert!(found.is_none());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn low_disk_space_warns_once_until_it_recovered() {
        assert!(!disk_space::is_low(30_000_000_000, false));
        assert!(disk_space::is_low(20_000_000_000, false));
        assert!(disk_space::is_low(30_000_000_000, true));
        assert!(!disk_space::is_low(45_000_000_000, true));
    }

    fn make_build(folder: &Path, workspace: Option<&str>, now: SystemTime, age_secs: u64) -> PathBuf {
        let build = folder.join("Build");
        std::fs::create_dir_all(&build).unwrap();
        if let Some(ws) = workspace {
            let plist = format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>WorkspacePath</key><string>{ws}</string></dict></plist>"
            );
            std::fs::write(folder.join("info.plist"), plist).unwrap();
        }
        let mtime = now - Duration::from_secs(age_secs);
        for p in [&build, &folder.join("info.plist"), &folder.to_path_buf()] {
            if p.exists() {
                if let Ok(f) = std::fs::File::open(p) {
                    let _ = f.set_modified(mtime);
                }
            }
        }
        folder.to_path_buf()
    }

    #[test]
    fn build_leftovers_detection_and_sweep() {
        use build_leftovers::*;
        let now = SystemTime::now();
        let old = 3 * 86_400;
        let base = std::env::temp_dir().join(format!("nook-leftovers-{}", uuid::Uuid::new_v4()));
        let tmp = base.join("tmp");
        let claude = base.join("claude");
        let dd = base.join("DerivedData");
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::create_dir_all(&dd).unwrap();

        make_build(&tmp.join("nook-core-tests.abc"), None, now, old);
        make_build(&tmp.join("nook-dd-feature"), Some("/x/Nook.xcodeproj"), now, old);
        make_build(&tmp.join("nook-core-tests.fresh"), None, now, 60);
        make_build(&tmp.join("someone-else"), None, now, old);

        let mut roots = Roots {
            temporary: vec![tmp.clone()],
            scratchpad_parents: vec![claude.clone()],
            derived_data: Some(dd.clone()),
            ..Default::default()
        };

        let found = find(&roots, now);
        let names: std::collections::HashSet<String> =
            found.iter().filter_map(|f| f.path.file_name().map(|n| n.to_string_lossy().into_owned())).collect();
        assert_eq!(names, ["nook-core-tests.abc".to_string(), "nook-dd-feature".to_string()].into_iter().collect());

        // Idle worktree dependency folders
        let idle = base.join("worktrees/idle");
        let busy = base.join("worktrees/busy");
        std::fs::create_dir_all(idle.join("node_modules/react/node_modules")).unwrap();
        std::fs::create_dir_all(idle.join("packages/app/target")).unwrap();
        std::fs::create_dir_all(busy.join("node_modules")).unwrap();
        roots.worktrees = vec![idle.clone(), busy.clone()];
        roots.idle_worktrees.insert(idle.clone());

        let found_deps: Vec<_> = find(&roots, now).into_iter().filter(|l| l.kind == LeftoverKind::Dependencies).collect();
        assert_eq!(found_deps.len(), 2);

        let removed = sweep(&roots, now);
        assert!(removed.len() >= 4);
        assert!(!tmp.join("nook-core-tests.abc").exists());

        assert!(is_idle("/w/nook/feature", &["/w/nook/other".into(), "/Users/me".into()], &[]));
        assert!(!is_idle("/w/nook/feature", &["/w/nook/feature/apps/web".into()], &[]));
        assert!(!is_idle("/w/nook/feature", &[], &["/w/nook/feature".into()]));

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn worktree_archive_saves_and_prunes_scratch() {
        use worktree_archive::*;
        let base = std::env::temp_dir().join(format!("nook-archive-{}", uuid::Uuid::new_v4()));
        let wt = base.join("repo-feature");
        let root = base.join("archive");
        std::fs::create_dir_all(wt.join(".scratch/preview")).unwrap();
        std::fs::write(wt.join(".scratch/preview/popover.png"), "png").unwrap();

        let wt_str = wt.to_string_lossy().into_owned();
        assert_eq!(
            scratch_file("popover.png", &wt_str).map(|p| std::fs::canonicalize(p).unwrap()),
            Some(std::fs::canonicalize(wt.join(".scratch/preview/popover.png")).unwrap())
        );

        // Cloned repo or node_modules inside .scratch is excluded
        std::fs::create_dir_all(wt.join(".scratch/clone/.git")).unwrap();
        std::fs::write(wt.join(".scratch/clone/main.rs"), "fn main() {}").unwrap();
        std::fs::create_dir_all(wt.join(".scratch/web/node_modules/x")).unwrap();
        std::fs::write(wt.join(".scratch/web/node_modules/x/index.js"), "js").unwrap();

        assert!(save(&wt_str, &root));
        let file_path = wt.join(".scratch/preview/popover.png").to_string_lossy().into_owned();
        let clone_file = wt.join(".scratch/clone/main.rs").to_string_lossy().into_owned();
        std::fs::remove_dir_all(&wt).unwrap();

        let kept = archived(&file_path, &wt_str, &root).expect("archived png");
        assert_eq!(std::fs::read_to_string(kept).unwrap(), "png");
        assert!(archived(&clone_file, &wt_str, &root).is_none());

        prune(&root, SystemTime::now() + KEEP_FOR + Duration::from_secs(60));
        assert!(!location(&wt_str, &root).exists());

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn worktree_move_detects_added_worktrees_and_follows() {
        use worktree_move::*;
        let cwd = "/Users/me/.nook/worktrees/nook/old-122f";
        assert_eq!(
            added(
                "cd /Users/me/Nook && git fetch -q origin main && git worktree add -q -b nook/next-122f /Users/me/.nook/worktrees/nook/next-122f origin/main && cd /Users/me/.nook/worktrees/nook/next-122f && git log --oneline -3",
                cwd
            ).as_deref(),
            Some("/Users/me/.nook/worktrees/nook/next-122f")
        );
        assert_eq!(added("git worktree add ../new-one", cwd).as_deref(), Some("/Users/me/.nook/worktrees/nook/new-one"));
        assert_eq!(added("cd /repo; git worktree add wt/a main", cwd).as_deref(), Some("/repo/wt/a"));
        assert_eq!(added("git -C /repo worktree add -B feat --reason 'x y' ../feat", cwd).as_deref(), Some("/feat"));
        assert_eq!(added("git worktree add -f --detach \"/tmp/with space\" HEAD", cwd).as_deref(), Some("/tmp/with space"));
        assert_eq!(added("git worktree add -- /x/y", cwd).as_deref(), Some("/x/y"));

        assert!(added("git worktree list", cwd).is_none());
        assert!(added("git worktree remove /a/b", cwd).is_none());
        assert!(added("echo 'git worktree add /a/b'", cwd).is_none());
        assert!(added("grep -rn \"worktree add\" Services", cwd).is_none());
        assert!(added("git worktree add", cwd).is_none());

        assert!(follows(false, "/w/new", &[]));
        assert!(follows(true, "/w/new", &["/w/new/apps/a.swift".into()]));
        assert!(!follows(true, "/w/new", &["/w/old/a.swift".into(), "/w/newer/b.swift".into()]));
    }
}
