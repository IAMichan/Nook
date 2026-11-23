//! A new build of Nook is on trial until it proves it runs (`UpdateTrial` on the Mac): before the update replaces the
//! app, the previous app is kept, and the database is copied while the old process is gone. The new build commits itself
//! after a minute of normal running. When a launch of it ends in a crash before that, the next launch puts the previous
//! app and the database back, starts the previous app, and that one tells you. The decisions and the file moves live here
//! and are tested; `src-tauri/src/updates.rs` drives them.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    /// Installed; the new build has not proved it runs yet.
    Trial,
    /// Putting the previous app and database back. Whichever build starts next finishes it.
    Restoring,
    /// Rolled back: the previous build says so once.
    RolledBack,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateTrial {
    pub stage: Stage,
    /// The version that installed the update and the version it installed.
    pub from: String,
    pub to: String,
    /// Where Nook runs: the install folder (Windows) or the AppImage file.
    pub app_path: String,
    /// The previous app, kept until the new one is committed.
    pub previous_app: String,
    /// The folder with the database as it was before the new build first started.
    pub snapshot: Option<String>,
    pub installed_at: DateTime<Utc>,
    /// Launches of the new build that crashed before it proved healthy.
    #[serde(default)]
    pub failed_launches: u32,
    /// A launch of the new build runs now; still set at the next launch means that launch crashed.
    #[serde(default)]
    pub running: bool,
}

/// What a launch, a healthy minute or a restore asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    None,
    /// Run normally and report healthy after [`HEALTHY_AFTER`].
    Watch,
    /// The trial is over: remove the kept app and the snapshot.
    CleanUp(UpdateTrial),
    /// Put the previous app and database back, start the previous app, quit.
    Restore(UpdateTrial),
    /// This is the previous build, put back: tell the user.
    ReportRollback(UpdateTrial),
}

/// Running this long without a crash proves a build healthy.
pub const HEALTHY_AFTER: Duration = Duration::from_secs(60);
/// Crashed launches before Nook gives up on the new build.
pub const MAX_FAILED_LAUNCHES: u32 = 1;

/// At launch, before anything opens the database. Returns the record to keep (None: remove it) and what to do.
pub fn launch(trial: Option<UpdateTrial>, build: &str) -> (Option<UpdateTrial>, Action) {
    let Some(mut trial) = trial else { return (None, Action::None) };
    match trial.stage {
        Stage::Restoring => (Some(trial.clone()), Action::Restore(trial)),
        Stage::RolledBack => {
            if build == trial.from {
                (None, Action::ReportRollback(trial))
            } else {
                (None, Action::None)
            }
        }
        Stage::Trial => {
            // The previous build started (put back by hand): its own app must not be removed.
            if build == trial.from {
                return (None, Action::None);
            }
            // Some other build replaced the new one: the trial is moot.
            if build != trial.to {
                return (None, Action::CleanUp(trial));
            }
            if trial.running {
                trial.failed_launches += 1;
            }
            if trial.failed_launches >= MAX_FAILED_LAUNCHES {
                trial.stage = Stage::Restoring;
                trial.running = false;
                return (Some(trial.clone()), Action::Restore(trial));
            }
            trial.running = true;
            (Some(trial), Action::Watch)
        }
    }
}

/// The new build ran [`HEALTHY_AFTER`] without a crash: it is committed.
pub fn healthy(trial: Option<UpdateTrial>, build: &str) -> (Option<UpdateTrial>, Action) {
    match trial {
        Some(t) if t.stage == Stage::Trial && t.to == build => (None, Action::CleanUp(t)),
        other => (other, Action::None),
    }
}

/// Nook quits normally during the trial: that launch did not crash.
pub fn clean_exit(trial: Option<UpdateTrial>, build: &str) -> Option<UpdateTrial> {
    match trial {
        Some(mut t) if t.stage == Stage::Trial && t.to == build => {
            t.running = false;
            Some(t)
        }
        other => other,
    }
}

/// The files are back: the previous build reports it when it starts.
pub fn restored(trial: &UpdateTrial) -> UpdateTrial {
    UpdateTrial { stage: Stage::RolledBack, ..trial.clone() }
}

// MARK: Store

pub fn record_path() -> PathBuf {
    crate::paths::support_directory().join("update-trial.json")
}

pub fn rollback_folder() -> PathBuf {
    crate::paths::support_directory().join("Rollback")
}

/// Where an update keeps the previous app until the new one is committed.
pub fn kept_app_path() -> PathBuf {
    rollback_folder().join("app")
}

/// Where the database is copied before the new build first starts.
pub fn snapshot_path() -> PathBuf {
    rollback_folder().join("database")
}

pub fn load(path: &Path) -> Option<UpdateTrial> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

/// None removes the record.
pub fn save(trial: Option<&UpdateTrial>, path: &Path) {
    match trial {
        None => {
            let _ = fs::remove_file(path);
        }
        Some(t) => {
            if let Ok(bytes) = serde_json::to_vec_pretty(t) {
                let _ = crate::paths::write_atomic(path, &bytes);
            }
        }
    }
}

// MARK: Files

/// The database and its companions, as SQLite keeps them next to each other.
pub fn database_files(database: &Path) -> Vec<PathBuf> {
    ["", "-wal", "-shm"].iter().map(|s| PathBuf::from(format!("{}{s}", database.display()))).collect()
}

/// Copies a file or a whole folder.
pub fn copy_any(from: &Path, to: &Path) -> io::Result<()> {
    if from.is_dir() {
        fs::create_dir_all(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            copy_any(&entry.path(), &to.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(from, to).map(|_| ())
    }
}

fn remove_any(path: &Path) {
    if path.is_dir() {
        let _ = fs::remove_dir_all(path);
    } else {
        let _ = fs::remove_file(path);
    }
}

/// Copies the database to `snapshot` (main file, -wal and -shm). Returns whether there was a database to take.
pub fn take_snapshot(database: &Path, snapshot: &Path) -> bool {
    remove_any(snapshot);
    if !database.is_file() || fs::create_dir_all(snapshot).is_err() {
        return false;
    }
    let name = database.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let target = snapshot.join(name);
    for (current, copy) in database_files(database).iter().zip(database_files(&target)) {
        if current.is_file() {
            let _ = fs::copy(current, copy);
        }
    }
    true
}

/// Puts the snapshot of the database back. The snapshot must hold the main file, or the database is left alone (a
/// database without its snapshot is better than none).
pub fn restore_database(trial: &UpdateTrial, database: &Path) -> io::Result<()> {
    let Some(snapshot) = &trial.snapshot else { return Ok(()) };
    let name = database.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let saved = database_files(&Path::new(snapshot).join(name));
    if !saved[0].is_file() {
        return Ok(());
    }
    for (current, copy) in database_files(database).iter().zip(&saved) {
        remove_any(current);
        if copy.is_file() {
            fs::copy(copy, current)?;
        }
    }
    Ok(())
}

/// Puts the previous app in place of the new one by moving (a file, or a folder nothing runs from). The caller handles
/// a running Windows install folder with [`windows_restore_command`] instead.
pub fn restore_app(trial: &UpdateTrial) -> io::Result<()> {
    let app = Path::new(&trial.app_path);
    let previous = Path::new(&trial.previous_app);
    // Already back (an interrupted restore that got this far).
    if !previous.exists() {
        return Ok(());
    }
    let failed = app.with_file_name(format!(".{}.failed", app.file_name().map(|n| n.to_string_lossy()).unwrap_or_default()));
    remove_any(&failed);
    let had_app = app.exists();
    if had_app {
        fs::rename(app, &failed)?;
    }
    if let Err(e) = fs::rename(previous, app) {
        if had_app {
            let _ = fs::rename(&failed, app);
        }
        return Err(e);
    }
    remove_any(&failed);
    Ok(())
}

/// The trial is over: the kept app and the snapshot go. Never the app that runs.
pub fn clean_up(trial: &UpdateTrial) {
    if trial.previous_app == trial.app_path {
        return;
    }
    remove_any(Path::new(&trial.previous_app));
    if let Some(snapshot) = &trial.snapshot {
        remove_any(Path::new(snapshot));
    }
}

/// The PowerShell arguments that, once process `pid` has ended, copy the kept install folder over the install folder
/// (robocopy mirrors it, so files the new build added go) and start `exe_name` again.
pub fn windows_restore_command(trial: &UpdateTrial, pid: u32, exe_name: &str) -> Vec<String> {
    let quote = |s: &str| s.replace('\'', "''");
    let script = format!(
        "Wait-Process -Id {pid} -Timeout 60 -ErrorAction SilentlyContinue; robocopy '{prev}' '{app}' /MIR /R:3 /W:1 /NFL /NDL /NJH /NJS | Out-Null; Start-Process -FilePath (Join-Path '{app}' '{exe}')",
        prev = quote(&trial.previous_app),
        app = quote(&trial.app_path),
        exe = quote(exe_name),
    );
    vec!["-NoProfile".into(), "-WindowStyle".into(), "Hidden".into(), "-Command".into(), script]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trial() -> UpdateTrial {
        UpdateTrial {
            stage: Stage::Trial,
            from: "1.0.0".into(),
            to: "1.1.0".into(),
            app_path: "app".into(),
            previous_app: "kept".into(),
            snapshot: Some("snap".into()),
            installed_at: Utc::now(),
            failed_launches: 0,
            running: false,
        }
    }

    #[test]
    fn a_new_build_is_watched_and_committed_after_a_healthy_minute() {
        let (kept, action) = launch(Some(trial()), "1.1.0");
        assert_eq!(action, Action::Watch);
        assert!(kept.as_ref().unwrap().running);
        let (kept, action) = healthy(kept, "1.1.0");
        assert!(kept.is_none());
        assert!(matches!(action, Action::CleanUp(_)));
    }

    #[test]
    fn a_crashed_launch_rolls_back_at_the_next_launch() {
        let (kept, _) = launch(Some(trial()), "1.1.0");
        let (kept, action) = launch(kept, "1.1.0");
        assert!(matches!(action, Action::Restore(_)));
        assert_eq!(kept.as_ref().unwrap().stage, Stage::Restoring);
        // An interrupted restore is finished by whichever build starts next.
        assert!(matches!(launch(kept.clone(), "1.0.0").1, Action::Restore(_)));
        let done = restored(&kept.unwrap());
        assert_eq!(launch(Some(done.clone()), "1.0.0").1, Action::ReportRollback(done.clone()));
        assert_eq!(launch(Some(done), "1.1.0"), (None, Action::None));
    }

    #[test]
    fn a_clean_quit_is_not_a_crash() {
        let (kept, _) = launch(Some(trial()), "1.1.0");
        let kept = clean_exit(kept, "1.1.0");
        let (kept, action) = launch(kept, "1.1.0");
        assert_eq!(action, Action::Watch);
        assert_eq!(kept.unwrap().failed_launches, 0);
    }

    #[test]
    fn other_builds_end_the_trial() {
        assert_eq!(launch(Some(trial()), "1.0.0"), (None, Action::None));
        assert!(matches!(launch(Some(trial()), "9.9.9"), (None, Action::CleanUp(_))));
        assert_eq!(launch(None, "1.1.0"), (None, Action::None));
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-trial-{name}-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_database_and_app_come_back() {
        let root = temp("files");
        let db = root.join("nook.sqlite");
        fs::write(&db, "old").unwrap();
        fs::write(root.join("nook.sqlite-wal"), "old-wal").unwrap();
        let snapshot = root.join("snap");
        assert!(take_snapshot(&db, &snapshot));
        fs::write(&db, "new").unwrap();
        fs::remove_file(root.join("nook.sqlite-wal")).unwrap();
        fs::create_dir_all(root.join("app")).unwrap();
        fs::write(root.join("app/nook.exe"), "v2").unwrap();
        fs::create_dir_all(root.join("kept")).unwrap();
        fs::write(root.join("kept/nook.exe"), "v1").unwrap();
        let t = UpdateTrial {
            app_path: root.join("app").to_string_lossy().into(),
            previous_app: root.join("kept").to_string_lossy().into(),
            snapshot: Some(snapshot.to_string_lossy().into()),
            ..trial()
        };
        restore_database(&t, &db).unwrap();
        restore_app(&t).unwrap();
        assert_eq!(fs::read_to_string(&db).unwrap(), "old");
        assert_eq!(fs::read_to_string(root.join("nook.sqlite-wal")).unwrap(), "old-wal");
        assert_eq!(fs::read_to_string(root.join("app/nook.exe")).unwrap(), "v1");
        assert!(!root.join("kept").exists());
        // Running the restore again changes nothing.
        restore_app(&t).unwrap();
        clean_up(&t);
        assert!(!snapshot.exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn without_a_snapshot_main_file_the_database_stays() {
        let root = temp("nosnap");
        let db = root.join("nook.sqlite");
        fs::write(&db, "keep").unwrap();
        fs::create_dir_all(root.join("snap")).unwrap();
        let t = UpdateTrial { snapshot: Some(root.join("snap").to_string_lossy().into()), ..trial() };
        restore_database(&t, &db).unwrap();
        assert_eq!(fs::read_to_string(&db).unwrap(), "keep");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn the_record_round_trips_and_the_windows_command_names_both_folders() {
        let root = temp("record");
        let path = root.join("update-trial.json");
        save(Some(&trial()), &path);
        assert_eq!(load(&path).unwrap().to, "1.1.0");
        save(None, &path);
        assert!(load(&path).is_none());
        let command = windows_restore_command(&trial(), 42, "nook.exe");
        assert!(command[4].contains("robocopy 'kept' 'app' /MIR") && command[4].contains("Wait-Process -Id 42"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn copies_folders() {
        let root = temp("copy");
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("a/b/c.txt"), "x").unwrap();
        copy_any(&root.join("a"), &root.join("z")).unwrap();
        assert_eq!(fs::read_to_string(root.join("z/b/c.txt")).unwrap(), "x");
        let _ = fs::remove_dir_all(root);
    }
}
