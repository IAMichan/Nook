//! Alle git-bewerkingen van Nook (`GitService` en `GitCheckpoints` op de Mac). Elke functie blokkeert: roep ze aan
//! buiten de interface-thread. Argumenten gaan als lijst naar git, zodat een branchnaam of pad nooit als shell-commando
//! kan draaien. Nook vraagt nooit om een wachtwoord (de credential helper van je systeem werkt gewoon).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::models::{is_plausible_branch_name, slug};
use super::paths::normalize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitError(pub String);

impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GitError {}

pub type Result<T> = std::result::Result<T, GitError>;

pub struct Output {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

/// Draait een programma met een lijst argumenten (nooit via een shell), met een tijdslimiet.
pub fn run_process(
    executable: &str,
    args: &[String],
    dir: Option<&Path>,
    env: &BTreeMap<String, String>,
    timeout: Duration,
) -> std::io::Result<Output> {
    let mut command = Command::new(executable);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(d) = dir {
        command.current_dir(d);
    }
    for (k, v) in env {
        command.env(k, v);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn()?;
    // Beide pijpen tegelijk leegmaken, anders loopt een proces met veel uitvoer vast.
    let mut out = child.stdout.take();
    let mut err = child.stderr.take();
    let out_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(o) = out.as_mut() {
            let _ = o.read_to_end(&mut buf);
        }
        buf
    });
    let err_thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(e) = err.as_mut() {
            let _ = e.read_to_end(&mut buf);
        }
        buf
    });
    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if start.elapsed() > timeout {
            timed_out = true;
            let _ = child.kill();
            break child.wait()?;
        }
        std::thread::sleep(Duration::from_millis(15));
    };
    let stdout = String::from_utf8_lossy(&out_thread.join().unwrap_or_default()).into_owned();
    let stderr = String::from_utf8_lossy(&err_thread.join().unwrap_or_default()).into_owned();
    Ok(Output { status: status.code().unwrap_or(-1), stdout, stderr, timed_out })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    Untracked,
    Conflicted,
    TypeChanged,
}

impl ChangeKind {
    pub fn letter(self) -> &'static str {
        match self {
            Self::Added => "A",
            Self::Modified => "M",
            Self::Deleted => "D",
            Self::Renamed => "R",
            Self::Copied => "C",
            Self::Untracked => "U",
            Self::Conflicted => "!",
            Self::TypeChanged => "T",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChange {
    pub path: String,
    pub old_path: Option<String>,
    pub kind: ChangeKind,
    pub staged: bool,
    pub unstaged: bool,
    pub added: Option<u64>,
    pub removed: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatus {
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub detached: bool,
    pub files: Vec<FileChange>,
}

impl GitStatus {
    pub fn is_clean(&self) -> bool {
        self.files.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub path: String,
    pub head: String,
    pub branch: Option<String>,
    pub is_main: bool,
    pub locked: bool,
    pub prunable: bool,
}

pub const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

#[derive(Debug, Clone)]
pub struct Git {
    pub executable: String,
}

impl Git {
    /// Zoekt git. `None` als het er niet is.
    pub fn locate() -> Option<Self> {
        let mut candidates: Vec<PathBuf> = crate::agents::which("git").into_iter().collect();
        if cfg!(windows) {
            candidates.push(PathBuf::from(r"C:\Program Files\Git\cmd\git.exe"));
        } else {
            candidates.extend([PathBuf::from("/usr/bin/git"), PathBuf::from("/usr/local/bin/git")]);
        }
        for c in candidates {
            let git = Git { executable: c.to_string_lossy().into_owned() };
            if let Ok(o) = git.raw(&["--version".into()], None, Duration::from_secs(15)) {
                if o.status == 0 && o.stdout.starts_with("git version") {
                    return Some(git);
                }
            }
        }
        None
    }

    fn environment(&self) -> BTreeMap<String, String> {
        let mut env: BTreeMap<String, String> = std::env::vars().collect();
        // Nooit blijven hangen op een wachtwoordvraag.
        env.insert("GIT_TERMINAL_PROMPT".into(), "0".into());
        env.insert("GIT_OPTIONAL_LOCKS".into(), "0".into());
        env.insert("LC_ALL".into(), "C".into());
        env
    }

    pub fn raw(&self, args: &[String], dir: Option<&Path>, timeout: Duration) -> Result<Output> {
        run_process(&self.executable, args, dir, &self.environment(), timeout).map_err(|e| GitError(e.to_string()))
    }

    /// Draait git in `dir` en geeft bij een fout de foutuitvoer van git.
    pub fn run(&self, args: &[&str], dir: &str) -> Result<String> {
        self.run_with(args, dir, Duration::from_secs(60), &[0], &BTreeMap::new())
    }

    pub fn run_with(&self, args: &[&str], dir: &str, timeout: Duration, ok: &[i32], extra: &BTreeMap<String, String>) -> Result<String> {
        let mut full: Vec<String> = vec!["-C".into(), dir.into()];
        full.extend(args.iter().map(|a| a.to_string()));
        let mut env = self.environment();
        env.extend(extra.clone());
        let output = run_process(&self.executable, &full, Some(Path::new(dir)), &env, timeout).map_err(|e| GitError(e.to_string()))?;
        let first = args.first().copied().unwrap_or("");
        if output.timed_out {
            return Err(GitError(format!("git {first} duurde te lang en is gestopt.")));
        }
        if !ok.contains(&output.status) {
            let message = output.stderr.trim();
            return Err(GitError(if message.is_empty() { format!("git {first} mislukte ({}).", output.status) } else { message.into() }));
        }
        Ok(output.stdout)
    }

    // MARK: Repository

    pub fn repository_root(&self, path: &str) -> Option<String> {
        let text = self.run(&["rev-parse", "--show-toplevel"], path).ok()?;
        let root = text.trim();
        (!root.is_empty()).then(|| normalize(root))
    }

    /// De gedeelde .git-map: dezelfde voor de hoofdmap en al zijn worktrees.
    pub fn common_directory(&self, path: &str) -> Option<String> {
        let text = self.run(&["rev-parse", "--path-format=absolute", "--git-common-dir"], path).ok()?;
        let dir = text.trim();
        (!dir.is_empty()).then(|| dir.into())
    }

    pub fn has_commits(&self, repo: &str) -> bool {
        self.run(&["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], repo).is_ok()
    }

    pub fn current_branch(&self, repo: &str) -> Option<String> {
        let text = self.run(&["symbolic-ref", "--quiet", "--short", "HEAD"], repo).ok()?;
        let name = text.trim();
        (!name.is_empty()).then(|| name.into())
    }

    /// Lokale en externe branches (zonder origin/HEAD).
    pub fn branches(&self, repo: &str) -> Result<(Vec<String>, Vec<String>)> {
        let text = self.run(&["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], repo)?;
        let mut local = vec![];
        let mut remote = vec![];
        for line in text.lines() {
            if let Some(b) = line.strip_prefix("refs/heads/") {
                local.push(b.to_string());
            } else if let Some(r) = line.strip_prefix("refs/remotes/") {
                if !line.ends_with("/HEAD") {
                    remote.push(r.to_string());
                }
            }
        }
        Ok((local, remote))
    }

    /// De standaard basisbranch (origin/main), anders de huidige.
    pub fn default_base_branch(&self, repo: &str, local: Option<&[String]>, fallback: Option<String>) -> Option<String> {
        if let Ok(text) = self.run(&["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], repo) {
            let name = text.trim();
            if !name.is_empty() {
                let short = name.strip_prefix("origin/").unwrap_or(name).to_string();
                let locals = local.map(|l| l.to_vec()).unwrap_or_else(|| self.branches(repo).map(|b| b.0).unwrap_or_default());
                return Some(if locals.contains(&short) { short } else { name.into() });
            }
        }
        fallback.or_else(|| self.current_branch(repo))
    }

    pub fn ref_exists(&self, r: &str, repo: &str) -> bool {
        self.run(&["rev-parse", "--verify", "--quiet", &format!("{r}^{{commit}}")], repo).is_ok()
    }

    pub fn local_branch_exists(&self, name: &str, repo: &str) -> bool {
        self.run(&["show-ref", "--verify", "--quiet", &format!("refs/heads/{name}")], repo).is_ok()
    }

    pub fn is_valid_branch_name(&self, name: &str, repo: &str) -> bool {
        is_plausible_branch_name(name) && self.run(&["check-ref-format", "--branch", name], repo).is_ok()
    }

    pub fn remotes(&self, repo: &str) -> Vec<String> {
        self.run(&["remote"], repo).unwrap_or_default().lines().map(str::to_string).filter(|l| !l.is_empty()).collect()
    }

    pub fn remote_url(&self, repo: &str, remote: &str) -> Option<String> {
        let text = self.run(&["remote", "get-url", remote], repo).ok()?;
        let t = text.trim();
        (!t.is_empty()).then(|| t.into())
    }

    // MARK: Status en wijzigingen

    pub fn changed_file_count(&self, dir: &str) -> Option<usize> {
        let text = self.run(&["status", "--porcelain=v1", "-z", "--untracked-files=all"], dir).ok()?;
        Some(parse_status(&text).files.len())
    }

    pub fn status(&self, dir: &str) -> Result<GitStatus> {
        let text = self.run(&["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"], dir)?;
        let mut status = parse_status(&text);
        if status.files.is_empty() {
            return Ok(status);
        }
        // Regels erbij en eraf: uit de diff voor bekende bestanden, uit het bestand zelf voor nieuwe.
        let base = if self.has_commits(dir) { "HEAD" } else { EMPTY_TREE };
        if let Ok(numstat) = self.run(&["diff", "--numstat", "-z", base], dir) {
            let counts = parse_numstat(&numstat);
            for f in status.files.iter_mut() {
                if let Some((a, r)) = counts.get(&f.path) {
                    f.added = *a;
                    f.removed = *r;
                } else if f.kind == ChangeKind::Untracked {
                    f.added = line_count(&Path::new(dir).join(&f.path));
                    f.removed = Some(0);
                }
            }
        }
        Ok(status)
    }

    /// Hoeveel commits deze branch voor (en achter) `base` loopt.
    pub fn divergence(&self, dir: &str, base: &str) -> Option<(u32, u32)> {
        let text = self.run(&["rev-list", "--left-right", "--count", &format!("{base}...HEAD")], dir).ok()?;
        let parts: Vec<u32> = text.split_whitespace().filter_map(|p| p.parse().ok()).collect();
        (parts.len() == 2).then(|| (parts[1], parts[0]))
    }

    /// De diff van één bestand ten opzichte van HEAD (of de lege boom zonder commits).
    pub fn diff(&self, dir: &str, file: &FileChange) -> Result<String> {
        if file.kind == ChangeKind::Untracked {
            // Afsluitcode 1 betekent hier "er zijn verschillen", geen fout.
            return self.run_with(
                &["diff", "--no-color", "--no-index", "--", "/dev/null", &file.path],
                dir,
                Duration::from_secs(60),
                &[0, 1],
                &BTreeMap::new(),
            );
        }
        let base = if self.has_commits(dir) { "HEAD" } else { EMPTY_TREE };
        let mut args = vec!["diff", "--no-color", "-M", base, "--"];
        if let Some(old) = &file.old_path {
            args.push(old);
        }
        args.push(&file.path);
        self.run(&args, dir)
    }

    // MARK: Worktrees

    pub fn worktrees(&self, repo: &str) -> Result<Vec<Worktree>> {
        Ok(parse_worktrees(&self.run(&["worktree", "list", "--porcelain"], repo)?))
    }

    /// Maakt een worktree met een nieuwe branch vanaf `base`. De huidige map en branch blijven zoals ze zijn.
    pub fn add_worktree(&self, repo: &str, path: &str, branch: &str, base: &str) -> Result<()> {
        if !self.has_commits(repo) {
            return Err(GitError("Deze repository heeft nog geen commits; een worktree heeft een eerste commit nodig.".into()));
        }
        if !self.ref_exists(base, repo) {
            return Err(GitError(format!("De basisbranch '{base}' bestaat niet.")));
        }
        if !self.is_valid_branch_name(branch, repo) {
            return Err(GitError(format!("'{branch}' is geen geldige branchnaam.")));
        }
        if self.local_branch_exists(branch, repo) {
            return Err(GitError(format!("De branch '{branch}' bestaat al. Kies een andere naam.")));
        }
        if Path::new(path).exists() {
            return Err(GitError(format!("De map {path} bestaat al.")));
        }
        if let Some(parent) = Path::new(path).parent() {
            std::fs::create_dir_all(parent).map_err(|e| GitError(e.to_string()))?;
        }
        self.run_with(&["worktree", "add", "-b", branch, path, base], repo, Duration::from_secs(180), &[0], &BTreeMap::new())
            .map(|_| ())
            .map_err(|e| friendly_worktree_error(e, base))
    }

    /// Haalt een worktree weg. Alleen worktrees die git voor deze repository kent, en nooit de hoofdmap. Zonder
    /// `force` weigert git als er niet-vastgelegde wijzigingen zijn.
    pub fn remove_worktree(&self, repo: &str, path: &str, force: bool) -> Result<()> {
        let target = normalize(path);
        let known = self.worktrees(repo)?;
        let Some(found) = known.iter().find(|w| normalize(&w.path) == target) else {
            return Err(GitError(format!("Git kent geen worktree op {path}.")));
        };
        if found.is_main {
            return Err(GitError("Dit is de hoofdmap van de repository; die haalt Nook nooit weg.".into()));
        }
        let mut args = vec!["worktree", "remove"];
        if force {
            args.push("--force");
        }
        args.push(&found.path);
        self.run_with(&args, repo, Duration::from_secs(120), &[0], &BTreeMap::new()).map(|_| ())
    }

    /// Haalt een branch alleen weg als hij al is samengevoegd (`git branch -d`, nooit -D).
    pub fn delete_merged_branch(&self, repo: &str, branch: &str) -> Result<()> {
        self.run(&["branch", "-d", branch], repo).map(|_| ())
    }

    // MARK: Klonen

    /// Kloont naar `<parent>/<naam>`. De map mag nog niet bestaan.
    pub fn clone(&self, url: &str, parent: &str) -> Result<String> {
        let clean = url.trim();
        if !is_clone_url(clean) {
            return Err(GitError("Geen herkende git-URL (https://… of git@host:pad).".into()));
        }
        let target = Path::new(parent).join(clone_folder_name(clean));
        if target.exists() {
            return Err(GitError(format!("De map {} bestaat al.", target.display())));
        }
        std::fs::create_dir_all(parent).map_err(|e| GitError(e.to_string()))?;
        let target_text = target.to_string_lossy().into_owned();
        let out =
            self.raw(&["clone".into(), "--".into(), clean.into(), target_text.clone()], Some(Path::new(parent)), Duration::from_secs(900))?;
        if out.status != 0 {
            let m = out.stderr.trim();
            return Err(GitError(if m.is_empty() { "Klonen mislukte.".into() } else { m.into() }));
        }
        Ok(target_text)
    }

    // MARK: Vastleggen en pushen

    /// Zet precies deze bestanden klaar en legt ze vast met jouw bericht. Geeft de korte hash.
    pub fn commit(&self, dir: &str, message: &str, paths: &[String]) -> Result<String> {
        let clean = message.trim();
        if clean.is_empty() {
            return Err(GitError("Een commit heeft een bericht nodig.".into()));
        }
        if paths.is_empty() {
            return Err(GitError("Kies minstens één bestand.".into()));
        }
        let mut add = vec!["add", "-A", "--"];
        add.extend(paths.iter().map(String::as_str));
        self.run(&add, dir)?;
        self.run_with(&["commit", "-m", clean], dir, Duration::from_secs(120), &[0], &BTreeMap::new())?;
        Ok(self.run(&["rev-parse", "--short", "HEAD"], dir)?.trim().to_string())
    }

    /// Wisselt naar een bestaande lokale branch. Git weigert zelf als er werk verloren zou gaan.
    pub fn checkout(&self, dir: &str, branch: &str) -> Result<()> {
        if branch.is_empty() || branch.starts_with('-') {
            return Err(GitError("Ongeldige branchnaam.".into()));
        }
        self.run(&["checkout", branch], dir).map(|_| ())
    }

    /// Pusht de huidige branch naar `remote` en zet de upstream. Nooit forceren.
    pub fn push(&self, dir: &str, remote: &str, branch: &str) -> Result<()> {
        if !self.remotes(dir).iter().any(|r| r == remote) {
            return Err(GitError(format!("De remote '{remote}' bestaat niet.")));
        }
        self.run_with(
            &["push", "--set-upstream", remote, &format!("HEAD:refs/heads/{branch}")],
            dir,
            Duration::from_secs(300),
            &[0],
            &BTreeMap::new(),
        )
        .map(|_| ())
    }

    // MARK: Momentopnamen (checkpoints)

    fn identity(extra: &[(&str, &str)]) -> BTreeMap<String, String> {
        let mut env: BTreeMap<String, String> = [
            ("GIT_AUTHOR_NAME", "Nook"),
            ("GIT_AUTHOR_EMAIL", "nook@localhost"),
            ("GIT_COMMITTER_NAME", "Nook"),
            ("GIT_COMMITTER_EMAIL", "nook@localhost"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        for (k, v) in extra {
            env.insert(k.to_string(), v.to_string());
        }
        env
    }

    fn with_index<T>(&self, body: impl FnOnce(&BTreeMap<String, String>) -> Result<T>) -> Result<T> {
        let index = std::env::temp_dir().join(format!("nook-index-{}", uuid::Uuid::new_v4()));
        let env = Self::identity(&[("GIT_INDEX_FILE", &index.to_string_lossy())]);
        let result = body(&env);
        let _ = std::fs::remove_file(&index);
        result
    }

    fn g(&self, args: &[&str], dir: &str, env: &BTreeMap<String, String>) -> Result<String> {
        self.run_with(args, dir, Duration::from_secs(120), &[0], env)
    }

    /// Legt `dir` vast onder `ref` met een tijdelijke index: de branch, HEAD en de index veranderen niet.
    pub fn checkpoint(&self, dir: &str, r: &str) -> Result<String> {
        self.with_index(|env| {
            let head =
                self.g(&["rev-parse", "--verify", "-q", "HEAD"], dir, env).ok().map(|h| h.trim().to_string()).filter(|h| !h.is_empty());
            if let Some(h) = &head {
                self.g(&["read-tree", h], dir, env)?;
            }
            self.g(&["add", "-A", "--", "."], dir, env)?;
            let tree = self.g(&["write-tree"], dir, env)?.trim().to_string();
            let mut args = vec!["commit-tree", tree.as_str(), "-m", "Nook checkpoint"];
            if let Some(h) = &head {
                args.extend(["-p", h.as_str()]);
            }
            let commit = self.g(&args, dir, env)?.trim().to_string();
            self.g(&["update-ref", r, &commit], dir, env)?;
            Ok(commit)
        })
    }

    /// De eerste momentopname van een nieuwe worktree is precies HEAD.
    pub fn checkpoint_head(&self, dir: &str, r: &str) -> Result<()> {
        self.g(&["update-ref", r, "HEAD"], dir, &Self::identity(&[])).map(|_| ())
    }

    /// Zet de bestanden van `dir` terug zoals ze bij `ref` waren. HEAD, de branch en de index blijven.
    pub fn restore(&self, dir: &str, r: &str) -> Result<()> {
        let none = Self::identity(&[]);
        let target: BTreeSet<String> = self
            .g(&["ls-tree", "-r", "-z", "--name-only", r], dir, &none)?
            .split('\0')
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect();
        let current: BTreeSet<String> = self.with_index(|env| {
            self.g(&["add", "-A", "--", "."], dir, env)?;
            Ok(self.g(&["ls-files", "-z"], dir, env)?.split('\0').filter(|s| !s.is_empty()).map(str::to_string).collect())
        })?;
        self.with_index(|env| {
            self.g(&["read-tree", r], dir, env)?;
            self.g(&["checkout-index", "-a", "-f", "-q"], dir, env).map(|_| ())
        })?;
        let root = PathBuf::from(normalize(dir));
        for path in current.difference(&target) {
            if path.contains("..") {
                continue;
            }
            let full = root.join(path);
            if full.starts_with(&root) {
                let _ = std::fs::remove_file(full);
            }
        }
        Ok(())
    }

    /// Haalt de momentopnamen van een sessie weg.
    pub fn remove_checkpoints(&self, dir: &str, session: &str) {
        let prefix = format!("refs/nook/checkpoints/{}/", session.to_lowercase());
        let none = Self::identity(&[]);
        if let Ok(list) = self.g(&["for-each-ref", "--format=%(refname)", &prefix], dir, &none) {
            for r in list.lines().filter(|l| !l.is_empty()) {
                let _ = self.g(&["update-ref", "-d", r], dir, &none);
            }
        }
    }
}

pub fn checkpoint_ref(session: &str, index: usize) -> String {
    format!("refs/nook/checkpoints/{}/{index}", session.to_lowercase())
}

/// De weigering "al uitgecheckt" van git in woorden waar je iets mee kunt.
fn friendly_worktree_error(error: GitError, base: &str) -> GitError {
    let text = error.0.clone();
    let lower = text.to_lowercase();
    if !(lower.contains("is already used by worktree at") || lower.contains("is already checked out at")) {
        return error;
    }
    let location = text.split('\'').nth(3).map(|l| format!(" ({l})")).unwrap_or_default();
    GitError(format!(
        "'{base}' is al uitgecheckt in een andere worktree{location}. Begin vanaf een andere branch, of haal die worktree eerst weg."
    ))
}

/// Alleen gewone git-URL's (https, ssh, git@host:pad); nooit iets dat als optie gelezen kan worden.
pub fn is_clone_url(url: &str) -> bool {
    let clean = url.trim();
    if clean.is_empty() || clean.starts_with('-') || clean.contains(' ') || clean.len() >= 500 {
        return false;
    }
    if let Some(rest) = clean.strip_prefix("https://").or_else(|| clean.strip_prefix("ssh://")) {
        let host = rest.split('/').next().unwrap_or("");
        let host = host.rsplit('@').next().unwrap_or("");
        return !host.is_empty();
    }
    let re = regex::Regex::new(r"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/~-]+$").unwrap();
    re.is_match(clean)
}

/// De mapnaam die git clone zou kiezen: "repo" uit ".../repo.git".
pub fn clone_folder_name(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    let last = trimmed.rsplit(['/', ':']).next().unwrap_or("repo");
    let last = last.strip_suffix(".git").unwrap_or(last);
    slug(last, 60)
}

pub fn parse_status(text: &str) -> GitStatus {
    let mut status = GitStatus::default();
    let mut entries = text.split('\0').filter(|e| !e.is_empty()).peekable();
    if let Some(first) = entries.peek() {
        if let Some(line) = first.strip_prefix("## ") {
            parse_branch_line(line, &mut status);
            entries.next();
        }
    }
    while let Some(entry) = entries.next() {
        let chars: Vec<char> = entry.chars().collect();
        if chars.len() < 4 {
            continue;
        }
        let (x, y) = (chars[0], chars[1]);
        let path: String = chars[3..].iter().collect();
        let mut old_path = None;
        if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
            old_path = entries.next().map(str::to_string);
        }
        if x == '!' {
            continue;
        }
        let kind = if x == '?' {
            ChangeKind::Untracked
        } else if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') {
            ChangeKind::Conflicted
        } else if x == 'R' || y == 'R' {
            ChangeKind::Renamed
        } else if x == 'C' || y == 'C' {
            ChangeKind::Copied
        } else if x == 'A' {
            ChangeKind::Added
        } else if x == 'D' || y == 'D' {
            ChangeKind::Deleted
        } else if x == 'T' || y == 'T' {
            ChangeKind::TypeChanged
        } else {
            ChangeKind::Modified
        };
        status.files.push(FileChange {
            path,
            old_path,
            kind,
            staged: x != ' ' && x != '?',
            unstaged: y != ' ',
            added: None,
            removed: None,
        });
    }
    status
}

fn parse_branch_line(line: &str, status: &mut GitStatus) {
    let mut head = line.to_string();
    if let Some(i) = head.find(" [") {
        let info = head[i + 2..].trim_end_matches(']').to_string();
        for part in info.split(',') {
            let words: Vec<&str> = part.split_whitespace().collect();
            if words.len() == 2 {
                if let Ok(n) = words[1].parse() {
                    match words[0] {
                        "ahead" => status.ahead = n,
                        "behind" => status.behind = n,
                        _ => {}
                    }
                }
            }
        }
        head.truncate(i);
    }
    if head.starts_with("HEAD (no branch)") {
        status.detached = true;
        return;
    }
    if let Some(b) = head.strip_prefix("No commits yet on ") {
        status.branch = Some(b.into());
        return;
    }
    let mut parts = head.splitn(2, "...");
    status.branch = parts.next().map(str::to_string);
    status.upstream = parts.next().map(str::to_string);
}

/// `git diff --numstat -z`: regels erbij en eraf per pad (`None` voor binaire bestanden).
pub fn parse_numstat(text: &str) -> HashMap<String, (Option<u64>, Option<u64>)> {
    let mut result = HashMap::new();
    let fields: Vec<&str> = text.split('\0').collect();
    let mut i = 0;
    while i < fields.len() {
        let entry = fields[i];
        i += 1;
        let parts: Vec<&str> = entry.splitn(3, '\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let (added, removed) = (parts[0].parse().ok(), parts[1].parse().ok());
        let mut path = parts[2].to_string();
        if path.is_empty() {
            // Hernoemd: daarna volgen het oude en het nieuwe pad.
            i += 1;
            path = fields.get(i).copied().unwrap_or("").to_string();
            i += 1;
        }
        if !path.is_empty() {
            result.insert(path, (added, removed));
        }
    }
    result
}

pub fn parse_worktrees(text: &str) -> Vec<Worktree> {
    let mut result: Vec<Worktree> = vec![];
    for block in text.split("\n\n") {
        let (mut path, mut head, mut branch, mut locked, mut prunable, mut bare) =
            (String::new(), String::new(), None, false, false, false);
        for line in block.lines() {
            if let Some(p) = line.strip_prefix("worktree ") {
                path = p.into();
            } else if let Some(h) = line.strip_prefix("HEAD ") {
                head = h.into();
            } else if let Some(r) = line.strip_prefix("branch ") {
                branch = Some(r.strip_prefix("refs/heads/").unwrap_or(r).to_string());
            } else if line.starts_with("locked") {
                locked = true;
            } else if line.starts_with("prunable") {
                prunable = true;
            } else if line == "bare" {
                bare = true;
            }
        }
        if path.is_empty() || bare {
            continue;
        }
        let is_main = result.is_empty();
        result.push(Worktree { path, head, branch, is_main, locked, prunable });
    }
    result
}

/// Regels in een nieuw tekstbestand; `None` voor grote of binaire bestanden.
pub fn line_count(path: &Path) -> Option<u64> {
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() >= 2_000_000 {
        return None;
    }
    let data = std::fs::read(path).ok()?;
    if data.contains(&0) {
        return None;
    }
    if data.is_empty() {
        return Some(0);
    }
    let newlines = data.iter().filter(|b| **b == b'\n').count() as u64;
    Some(if data.last() == Some(&b'\n') { newlines } else { newlines + 1 })
}

// MARK: De boom met gewijzigde bestanden

/// Een rij in de boom met gewijzigde bestanden (`ChangedFilesTree` op de Mac): mappen tellen hun inhoud op, een
/// keten van mappen met één kind wordt één rij ("src/app"), en elke rij heeft een vast id (zijn pad).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeRow {
    pub depth: usize,
    pub is_directory: bool,
    pub name: String,
    pub path: String,
    pub added: u64,
    pub removed: u64,
    pub file_count: usize,
    pub has_numbers: bool,
    pub kind: Option<ChangeKind>,
}

#[derive(Default)]
struct Builder {
    dirs: BTreeMap<String, Builder>,
    files: Vec<(String, String, &'static str, u64, u64, bool, ChangeKind)>,
}

/// Alle rijen van de boom (alles open). De interface klapt mappen zelf in.
pub fn changed_files_tree(files: &[FileChange]) -> Vec<TreeRow> {
    let mut root = Builder::default();
    for f in files {
        let parts: Vec<&str> = f.path.split('/').collect();
        let Some((name, dirs)) = parts.split_last() else { continue };
        let mut cursor = &mut root;
        for d in dirs {
            cursor = cursor.dirs.entry(d.to_string()).or_default();
        }
        cursor.files.push((
            name.to_string(),
            f.path.clone(),
            "",
            f.added.unwrap_or(0),
            f.removed.unwrap_or(0),
            f.added.is_some() || f.removed.is_some(),
            f.kind,
        ));
    }
    let mut rows = vec![];
    emit(&root, "", 0, &mut rows);
    rows
}

fn totals(b: &Builder) -> (u64, u64, usize, bool) {
    let mut t = (0, 0, 0, false);
    for f in &b.files {
        t.0 += f.3;
        t.1 += f.4;
        t.2 += 1;
        t.3 |= f.5;
    }
    for d in b.dirs.values() {
        let s = totals(d);
        t.0 += s.0;
        t.1 += s.1;
        t.2 += s.2;
        t.3 |= s.3;
    }
    t
}

fn emit(b: &Builder, prefix: &str, depth: usize, rows: &mut Vec<TreeRow>) {
    let mut dirs: Vec<(&String, &Builder)> = b.dirs.iter().collect();
    dirs.sort_by_key(|(n, _)| n.to_lowercase());
    for (name, mut dir) in dirs {
        let mut label = name.clone();
        let mut path = if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
        // Een keten van mappen met elk één map wordt één rij.
        while dir.files.is_empty() && dir.dirs.len() == 1 {
            let (child_name, child) = dir.dirs.iter().next().unwrap();
            label = format!("{label}/{child_name}");
            path = format!("{path}/{child_name}");
            dir = child;
        }
        let t = totals(dir);
        rows.push(TreeRow {
            depth,
            is_directory: true,
            name: label,
            path: path.clone(),
            added: t.0,
            removed: t.1,
            file_count: t.2,
            has_numbers: t.3,
            kind: None,
        });
        emit(dir, &path, depth + 1, rows);
    }
    let mut files: Vec<_> = b.files.iter().collect();
    files.sort_by_key(|f| f.0.to_lowercase());
    for f in files {
        rows.push(TreeRow {
            depth,
            is_directory: false,
            name: f.0.clone(),
            path: f.1.clone(),
            added: f.3,
            removed: f.4,
            file_count: 1,
            has_numbers: f.5,
            kind: Some(f.6),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_status() {
        let text = "## main...origin/main [ahead 2, behind 1]\0 M Sources/App.swift\0A  New.swift\0R  Renamed.swift\0Old.swift\0?? notes.txt\0D  Gone.swift\0UU Conflict.swift\0";
        let s = parse_status(text);
        assert_eq!(s.branch.as_deref(), Some("main"));
        assert_eq!(s.upstream.as_deref(), Some("origin/main"));
        assert_eq!((s.ahead, s.behind), (2, 1));
        assert_eq!(
            s.files.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(),
            vec!["Sources/App.swift", "New.swift", "Renamed.swift", "notes.txt", "Gone.swift", "Conflict.swift"]
        );
        assert_eq!(
            s.files.iter().map(|f| f.kind).collect::<Vec<_>>(),
            vec![
                ChangeKind::Modified,
                ChangeKind::Added,
                ChangeKind::Renamed,
                ChangeKind::Untracked,
                ChangeKind::Deleted,
                ChangeKind::Conflicted
            ]
        );
        assert_eq!(s.files[2].old_path.as_deref(), Some("Old.swift"));
        assert!(!s.files[0].staged && s.files[0].unstaged && s.files[1].staged);
        assert_eq!(parse_status("## No commits yet on main\0").branch.as_deref(), Some("main"));
        assert!(parse_status("## HEAD (no branch)\0").detached);
        assert!(parse_status("## feature\0").is_clean());
    }

    #[test]
    fn parses_numstat_and_worktrees() {
        let counts = parse_numstat("3\t1\tSources/App.swift\0-\t-\timage.png\x005\t0\t\0old.swift\0new.swift\0");
        assert_eq!(counts["Sources/App.swift"], (Some(3), Some(1)));
        assert_eq!(counts["image.png"], (None, None));
        assert_eq!(counts["new.swift"].0, Some(5));
        assert!(!counts.contains_key("old.swift"));
        let list = parse_worktrees("worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /wt/one\nHEAD def\nbranch refs/heads/nook/one\nlocked\n\nworktree /wt/two\nHEAD 123\ndetached\nprunable gitdir file points to non-existent location\n\n");
        assert_eq!(list.iter().map(|w| w.path.as_str()).collect::<Vec<_>>(), vec!["/repo", "/wt/one", "/wt/two"]);
        assert!(list[0].is_main && !list[1].is_main);
        assert_eq!(list[1].branch.as_deref(), Some("nook/one"));
        assert!(list[1].locked);
        assert!(list[2].branch.is_none() && list[2].prunable);
    }

    #[test]
    fn clone_urls() {
        assert!(is_clone_url("https://github.com/owner/repo.git"));
        assert!(is_clone_url("git@github.com:owner/repo.git"));
        assert!(is_clone_url("ssh://git@host.example/x/y"));
        assert!(!is_clone_url("--upload-pack=touch /tmp/x"));
        assert!(!is_clone_url("file:///etc"));
        assert!(!is_clone_url("https://exa mple.com/x"));
        assert!(!is_clone_url(""));
        assert_eq!(clone_folder_name("https://github.com/owner/My.Repo.git/"), "my-repo");
    }

    #[test]
    fn tree_collapses_chains_and_sums() {
        let f = |p: &str, a: u64, r: u64| FileChange {
            path: p.into(),
            old_path: None,
            kind: ChangeKind::Modified,
            staged: false,
            unstaged: true,
            added: Some(a),
            removed: Some(r),
        };
        let rows = changed_files_tree(&[f("src/app/a.rs", 3, 1), f("src/app/b.rs", 2, 0), f("README.md", 1, 1)]);
        assert_eq!(rows[0].name, "src/app");
        assert!(rows[0].is_directory);
        assert_eq!((rows[0].added, rows[0].removed, rows[0].file_count), (5, 1, 2));
        assert_eq!(rows[1].depth, 1);
        assert_eq!(rows.last().unwrap().name, "README.md");
    }

    fn setup() -> Option<(Git, PathBuf, String)> {
        let git = Git::locate()?;
        let root = std::env::temp_dir().join(format!("nook-git-{}", uuid::Uuid::new_v4()));
        let repo = root.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let r = repo.to_string_lossy().into_owned();
        let id = Git::identity(&[("GIT_CONFIG_NOSYSTEM", "1")]);
        git.run_with(&["init", "-q", "-b", "main"], &r, Duration::from_secs(30), &[0], &id).unwrap();
        std::fs::write(repo.join("README.md"), "hallo\n").unwrap();
        git.run_with(&["add", "README.md"], &r, Duration::from_secs(30), &[0], &id).unwrap();
        git.run_with(&["-c", "commit.gpgsign=false", "commit", "-q", "-m", "eerste"], &r, Duration::from_secs(30), &[0], &id).unwrap();
        Some((git, root, r))
    }

    #[test]
    fn worktree_lifecycle_commit_and_diff() {
        let Some((git, root, repo)) = setup() else { return };
        assert_eq!(git.repository_root(&repo), Some(normalize(&repo)));
        assert_eq!(git.current_branch(&repo).as_deref(), Some("main"));
        assert!(git.is_valid_branch_name("nook/test-1", &repo));
        assert!(!git.is_valid_branch_name("bad..name", &repo));
        let wt = root.join("worktrees").join("repo").join("taak-a").to_string_lossy().into_owned();
        git.add_worktree(&repo, &wt, "nook/taak-a", "main").unwrap();
        assert_eq!(git.current_branch(&wt).as_deref(), Some("nook/taak-a"));
        assert_eq!(git.current_branch(&repo).as_deref(), Some("main"));
        std::fs::write(Path::new(&wt).join("a.txt"), "a\n").unwrap();
        let status = git.status(&wt).unwrap();
        assert_eq!(status.files[0].kind, ChangeKind::Untracked);
        assert_eq!(status.files[0].added, Some(1));
        assert!(git.status(&repo).unwrap().is_clean());
        assert!(git.remove_worktree(&repo, &wt, false).is_err(), "vies: niet zonder force");
        assert!(git.diff(&wt, &status.files[0]).unwrap().contains("+a"));
        let sha = git.run_with(&["add", "-A", "--", "a.txt"], &wt, Duration::from_secs(30), &[0], &Git::identity(&[])).and_then(|_| {
            git.run_with(
                &["-c", "commit.gpgsign=false", "commit", "-q", "-m", "voeg a toe"],
                &wt,
                Duration::from_secs(30),
                &[0],
                &Git::identity(&[]),
            )
        });
        assert!(sha.is_ok());
        assert_eq!(git.divergence(&wt, "main"), Some((1, 0)));
        assert_eq!(git.worktrees(&repo).unwrap().len(), 2);
        git.remove_worktree(&repo, &wt, false).unwrap();
        assert!(!Path::new(&wt).exists());
        assert!(git.local_branch_exists("nook/taak-a", &repo));
        assert!(git.add_worktree(&repo, &wt, "nook/x", "bestaat-niet").is_err());
        assert!(git.add_worktree(&repo, &wt, "main", "main").is_err());
        assert!(git.remove_worktree(&repo, &repo, true).is_err(), "nooit de hoofdmap");
        assert!(git.commit(&repo, "  ", &["x".into()]).is_err());
        assert!(git.commit(&repo, "ok", &[]).is_err());
        assert!(git.push(&repo, "origin", "main").is_err());
        assert!(git.clone(&repo, &root.join("clones").to_string_lossy()).is_err(), "een lokaal pad is geen kloon-URL");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn checkpoints_and_restore() {
        let Some((git, root, repo)) = setup() else { return };
        let p = Path::new(&repo);
        std::fs::write(p.join(".gitignore"), "secret.txt\n").unwrap();
        let head = git.run(&["rev-parse", "HEAD"], &repo).unwrap();
        std::fs::write(p.join("README.md"), "twee").unwrap();
        std::fs::write(p.join("new.txt"), "nieuw").unwrap();
        std::fs::write(p.join("secret.txt"), "geheim").unwrap();
        let r = checkpoint_ref("ABC", 0);
        git.checkpoint(&repo, &r).unwrap();
        assert_eq!(git.run(&["rev-parse", "HEAD"], &repo).unwrap(), head, "de branch krijgt geen commit");
        std::fs::write(p.join("README.md"), "drie").unwrap();
        std::fs::remove_file(p.join("new.txt")).unwrap();
        std::fs::write(p.join("later.txt"), "later").unwrap();
        git.restore(&repo, &r).unwrap();
        assert_eq!(std::fs::read_to_string(p.join("README.md")).unwrap(), "twee");
        assert_eq!(std::fs::read_to_string(p.join("new.txt")).unwrap(), "nieuw");
        assert!(!p.join("later.txt").exists());
        assert_eq!(std::fs::read_to_string(p.join("secret.txt")).unwrap(), "geheim");
        git.remove_checkpoints(&repo, "abc");
        assert!(git.run(&["rev-parse", "--verify", "-q", &r], &repo).is_err());
        let _ = std::fs::remove_dir_all(root);
    }
}
