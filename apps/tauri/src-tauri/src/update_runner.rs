//! Runs an update's trial around Nook's launch (`UpdateTrialRunner` on the Mac) and keeps the installed tools up to date
//! (`ToolUpdates`). The rules live in `nook_core::updates::{trial, tool_updates}`.
//!
//! A new build whose last launch crashed before it proved healthy is rolled back in `at_launch`, before anything opens
//! the database: the database snapshot and the previous app are put back and the previous app starts. It cannot help a
//! build that crashes before `run` starts (a missing DLL): that one needs the previous version downloaded by hand.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use chrono::Utc;
use nook_core::paths;
use nook_core::updates::tool_updates;
use nook_core::updates::trial::{self, Action, UpdateTrial};
use tauri::{AppHandle, Manager};

static WATCHING: AtomicBool = AtomicBool::new(false);
static ROLLBACK: OnceLock<UpdateTrial> = OnceLock::new();

fn build() -> Option<String> {
    nook_core::updates::this_build().map(|b| b.version.to_string())
}

/// A rollback this (previous) build was put back by, to tell the user once Nook runs.
pub fn rollback_to_report() -> Option<&'static UpdateTrial> {
    ROLLBACK.get()
}

/// First thing at launch. Does not return when it rolls back: the previous app starts once this process is gone.
pub fn at_launch() {
    let Some(build) = build() else { return };
    let record = trial::record_path();
    let (next, action) = trial::launch(trial::load(&record), &build);
    trial::save(next.as_ref(), &record);
    match action {
        Action::None => {}
        Action::Watch => WATCHING.store(true, Ordering::SeqCst),
        Action::CleanUp(t) => trial::clean_up(&t),
        Action::ReportRollback(t) => {
            let _ = ROLLBACK.set(t);
        }
        Action::Restore(t) => restore(&t),
    }
}

fn restore(t: &UpdateTrial) {
    let record = trial::record_path();
    let fail = |e: String| {
        // Nothing to go back to: run this build rather than none, and do not try again on every launch.
        log::warn!("Rolling back the update failed: {e}");
        trial::save(None, &record);
    };
    if let Err(e) = trial::restore_database(t, &paths::database_file()) {
        return fail(e.to_string());
    }
    let app = Path::new(&t.app_path);
    let started = if app.is_dir() {
        // The install folder is in use by this process: a helper copies the kept folder back once it has ended.
        let exe = std::env::current_exe().ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()));
        let Some(exe) = exe else { return fail("unknown executable".into()) };
        spawn_helper(&trial::windows_restore_command(t, std::process::id(), &exe))
    } else {
        trial::restore_app(t).map_err(|e| e.to_string()).and_then(|_| relaunch_file(app))
    };
    if let Err(e) = started {
        return fail(e);
    }
    trial::save(Some(&trial::restored(t)), &record);
    std::process::exit(0);
}

#[cfg(target_os = "windows")]
fn spawn_helper(args: &[String]) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    std::process::Command::new("powershell.exe")
        .args(args)
        .creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[cfg(not(target_os = "windows"))]
fn spawn_helper(_args: &[String]) -> Result<(), String> {
    Err("the install-folder rollback runs only on Windows".into())
}

fn relaunch_file(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        std::process::Command::new("/bin/sh")
            .args(["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done; exec \"$2\" >/dev/null 2>&1", "nook-rollback"])
            .arg(std::process::id().to_string())
            .arg(path)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    #[cfg(not(unix))]
    {
        std::process::Command::new(path).spawn().map(|_| ()).map_err(|e| e.to_string())
    }
}

/// An update is about to replace the running Nook: keep the previous app and the database, and put the new build on
/// trial from its first launch. `app_path` is the install folder (Windows) or the AppImage file. Best effort: an update
/// without a kept copy still installs, it just has no rollback.
pub fn begin(from: &str, to: &str, app_path: &Path) {
    let kept = trial::kept_app_path();
    let _ = std::fs::remove_dir_all(trial::rollback_folder());
    if trial::copy_any(app_path, &kept).is_err() {
        let _ = std::fs::remove_dir_all(trial::rollback_folder());
        return;
    }
    let snapshot = trial::snapshot_path();
    let has_database = trial::take_snapshot(&paths::database_file(), &snapshot);
    let record = UpdateTrial {
        stage: trial::Stage::Trial,
        from: from.into(),
        to: to.into(),
        app_path: app_path.to_string_lossy().into(),
        previous_app: kept.to_string_lossy().into(),
        snapshot: has_database.then(|| snapshot.to_string_lossy().into()),
        installed_at: Utc::now(),
        failed_launches: 0,
        running: false,
    };
    trial::save(Some(&record), &trial::record_path());
}

/// Nook quits normally while on trial: this launch did not crash.
pub fn clean_exit() {
    if !WATCHING.load(Ordering::SeqCst) {
        return;
    }
    if let Some(build) = build() {
        let record = trial::record_path();
        trial::save(trial::clean_exit(trial::load(&record), &build).as_ref(), &record);
    }
}

/// Commits the trial after a healthy minute, and checks the installed tools once a day.
pub fn start(app: &AppHandle) {
    if WATCHING.load(Ordering::SeqCst) {
        tauri::async_runtime::spawn(async {
            tokio::time::sleep(trial::HEALTHY_AFTER).await;
            if !WATCHING.swap(false, Ordering::SeqCst) {
                return;
            }
            if let Some(build) = build() {
                let record = trial::record_path();
                let (next, action) = trial::healthy(trial::load(&record), &build);
                trial::save(next.as_ref(), &record);
                if let Action::CleanUp(t) = action {
                    trial::clean_up(&t);
                }
            }
        });
    }
    #[cfg(desktop)]
    {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(tool_updates::FIRST_CHECK).await;
            loop {
                check_tools(&app).await;
                tokio::time::sleep(tool_updates::TICK).await;
            }
        });
    }
}

#[cfg(desktop)]
async fn check_tools(app: &AppHandle) {
    let mut state = tool_updates::load();
    if !tool_updates::due(state.last_check, Utc::now()) {
        return;
    }
    state.last_check = Some(Utc::now());
    tool_updates::save(&state);
    // Antigravity: the pinned release, when one was installed (a no-op install when it is current).
    {
        use nook_core::workspace::{antigravity::Paths, antigravity_install as install};
        let paths = Paths::current();
        if tool_updates::antigravity_due(install::was_installed(&paths), install::installed(&paths).is_some()) {
            crate::commands::workspace::antigravity_install(app.clone());
        }
    }
    // GOWA: Nook's own copy to the newest release; a failed check waits for the next one.
    if let Some(connectors) = app.try_state::<crate::connectors::Connectors>() {
        let settings = connectors.whatsapp.settings();
        let own = nook_core::connectors::whatsapp::gowa_install::binary_path();
        if tool_updates::gowa_due(Path::new(&settings.gowa_path) == own && own.is_file(), &settings.gowa_version) {
            let _ = crate::commands::whatsapp::whatsapp_install_gowa(app.clone(), connectors, true).await;
        }
    }
}
