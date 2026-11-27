//! Clones that run in the background (the Mac's `CloneCenter`): each one a quiet notice in the main window's top right
//! corner with how far git is, Hide and Cancel (`CloneNotices.svelte`), while you go on with anything else. The command
//! that starts one (`workspace_clone`) still answers with the new folder when git is done, so the composer that asked
//! picks the project by itself. Hide only takes the notice away; Cancel stops git and removes the half-made folder.
//! The list goes to every window as `clone-jobs`.

use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nook_core::i18n::tr;
use nook_core::workspace::clone_progress::{display_name, failure, CloneProgress, Lines};
use nook_core::workspace::git::{clone_folder_name, is_clone_url, Git};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneJob {
    pub id: u64,
    pub url: String,
    /// "owner/repo", as the notice names it.
    pub name: String,
    /// The notice's line ("Receiving objects · 42% · 12.40 MiB | 3.10 MiB/s"); none until git says something.
    pub progress: Option<String>,
    pub hidden: bool,
    pub cancelling: bool,
}

struct Running {
    job: CloneJob,
    child: Arc<Mutex<Option<Child>>>,
}

static JOBS: Mutex<Vec<Running>> = Mutex::new(Vec::new());
static NEXT: AtomicU64 = AtomicU64::new(1);

fn jobs() -> std::sync::MutexGuard<'static, Vec<Running>> {
    JOBS.lock().unwrap_or_else(|e| e.into_inner())
}

/// The clones running now, for a window that just opened.
pub fn list() -> Vec<CloneJob> {
    jobs().iter().map(|r| r.job.clone()).collect()
}

fn publish(app: &AppHandle) {
    let _ = app.emit("clone-jobs", list());
}

fn update(app: &AppHandle, id: u64, change: impl FnOnce(&mut CloneJob)) {
    {
        let mut all = jobs();
        let Some(running) = all.iter_mut().find(|r| r.job.id == id) else { return };
        change(&mut running.job);
    }
    publish(app);
}

pub fn hide(app: &AppHandle, id: u64) {
    update(app, id, |job| job.hidden = true);
}

pub fn cancel(app: &AppHandle, id: u64) {
    let child = {
        let mut all = jobs();
        let Some(running) = all.iter_mut().find(|r| r.job.id == id) else { return };
        if running.job.cancelling {
            return;
        }
        running.job.cancelling = true;
        running.child.clone()
    };
    if let Some(child) = child.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        let _ = child.kill();
    }
    publish(app);
}

/// Clones `url` into `<parent>/<name>` (or `<parent>/<host>/<owner>/<name>` when `host_layout` is on)
/// with git's progress on the notice; blocks until git is done and answers with the new folder.
/// Normalizes browser page URLs and falls back once to HTTPS if an SSH connection is refused.
pub fn clone(app: &AppHandle, git: &Git, url: &str, parent: &str, host_layout: bool) -> Result<String, String> {
    use nook_core::workspace::source_control_rules::CloneLayout;

    let clean = CloneLayout::repository_url_from_page(url);
    if !is_clone_url(&clean) {
        return Err(tr("Dat is geen adres van een repository.", "That is not the address of a repository.").into());
    }
    {
        let mut all = jobs();
        if let Some(running) = all.iter_mut().find(|r| r.job.url == clean) {
            running.job.hidden = false;
            drop(all);
            publish(app);
            return Err(tr("Deze repository wordt al gekloond.", "This repository is being cloned already.").into());
        }
    }
    let Some(target) = CloneLayout::target(&clean, Path::new(parent), host_layout, &clone_folder_name(&clean)) else {
        return Err(nook_core::i18n::trf(
            "Kon host en eigenaar van {url} niet lezen.",
            "Could not read the host and owner of {url}.",
            &[("url", &clean)],
        ));
    };
    if !CloneLayout::prepare_clone_target(&target) {
        return Err(nook_core::i18n::trf("De map {path} bestaat al.", "The folder {path} already exists.", &[("path", &target.display())]));
    }
    let work_dir = target.parent().unwrap_or_else(|| Path::new(parent));
    std::fs::create_dir_all(work_dir).map_err(|e| e.to_string())?;

    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let child_slot = Arc::new(Mutex::new(None));
    jobs().push(Running {
        job: CloneJob { id, url: clean.clone(), name: display_name(&clean), progress: None, hidden: false, cancelling: false },
        child: child_slot.clone(),
    });
    publish(app);

    let first = run(app, id, git, &clean, work_dir, &target, CloneLayout::is_ssh(&clean), &child_slot);
    let cancelled_now = || jobs().iter().find(|r| r.job.id == id).is_some_and(|r| r.job.cancelling);
    let result = match first {
        Ok(path) => Ok(path),
        Err(first_err) if !cancelled_now() => {
            if let Some(https) = CloneLayout::https_fallback(&clean) {
                if CloneLayout::ssh_refused(&first_err.raw_stderr) {
                    let _ = std::fs::remove_dir_all(&target);
                    update(app, id, |job| job.progress = None);
                    run(app, id, git, &https, work_dir, &target, false, &child_slot).map_err(|e| e.message)
                } else {
                    Err(first_err.message)
                }
            } else {
                Err(first_err.message)
            }
        }
        Err(first_err) => Err(first_err.message),
    };

    let cancelled = cancelled_now();
    jobs().retain(|r| r.job.id != id);
    publish(app);
    if cancelled {
        let _ = std::fs::remove_dir_all(&target);
        return Err(nook_core::i18n::trf("Klonen van {name} gestopt", "Stopped cloning {name}", &[("name", &display_name(&clean))]));
    }
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&target);
    }
    result
}

struct CloneFailure {
    message: String,
    raw_stderr: String,
}

#[allow(clippy::too_many_arguments)]
fn run(
    app: &AppHandle,
    id: u64,
    git: &Git,
    url: &str,
    work_dir: &Path,
    target: &Path,
    batch_ssh: bool,
    slot: &Arc<Mutex<Option<Child>>>,
) -> Result<String, CloneFailure> {
    let mut env = git.environment();
    if batch_ssh && !env.contains_key("GIT_SSH_COMMAND") {
        env.insert("GIT_SSH_COMMAND".into(), "ssh -o BatchMode=yes -o ConnectTimeout=15".into());
    }
    let mut command = Command::new(&git.executable);
    command
        .args(["clone", "--progress", "--", url])
        .arg(target)
        .current_dir(work_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .envs(env);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window for git.
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|e| CloneFailure { message: e.to_string(), raw_stderr: String::new() })?;
    let mut stderr = child.stderr.take();
    *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(child);

    let mut all = String::new();
    let mut lines = Lines::default();
    let mut last_sent = Instant::now() - Duration::from_secs(1);
    let mut buf = [0u8; 4096];
    while let Some(err) = stderr.as_mut() {
        let n = match err.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let text = String::from_utf8_lossy(&buf[..n]);
        all.push_str(&text);
        // Only the newest progress line counts, and the notice changes at most four times a second.
        if let Some(progress) = lines.feed(&text).iter().rev().find_map(|l| CloneProgress::parse(l)) {
            if last_sent.elapsed() >= Duration::from_millis(250) {
                last_sent = Instant::now();
                let summary = progress.summary();
                update(app, id, |job| job.progress = Some(summary));
            }
        }
    }
    let status = slot.lock().unwrap_or_else(|e| e.into_inner()).as_mut().map(|c| c.wait());
    *slot.lock().unwrap_or_else(|e| e.into_inner()) = None;
    match status {
        Some(Ok(s)) if s.success() => Ok(target.to_string_lossy().into_owned()),
        _ => Err(CloneFailure {
            message: failure(&all).unwrap_or_else(|| tr("Klonen mislukte.", "Cloning failed.").into()),
            raw_stderr: all,
        }),
    }
}

#[tauri::command]
pub fn clone_jobs() -> Vec<CloneJob> {
    list()
}

#[tauri::command]
pub fn clone_hide(app: AppHandle, id: u64) {
    hide(&app, id);
}

#[tauri::command]
pub fn clone_cancel(app: AppHandle, id: u64) {
    cancel(&app, id);
}
