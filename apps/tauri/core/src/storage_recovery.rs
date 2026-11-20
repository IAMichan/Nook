//! Opens Nook's own SQLite files so that a file that cannot be used never makes data silently seem lost (the Mac's
//! `SQLiteRecovery` and `DatabaseIncidents`). When SQLite says the file is damaged or is not a database at all, the file
//! and its `-wal` and `-shm` are moved aside under a dated name (`nook.damaged-20261120-101500.sqlite`), never deleted,
//! and a fresh one is made in its place, so Nook keeps working. Any other failure (a full disk, a folder that is not
//! writable, a lock) leaves the file where it is. Either way an incident is kept, which the main window shows until you
//! dismiss it: which file, why, where the copy is.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum IncidentKind {
    /// Moved aside; Nook started with an empty file.
    Damaged,
    /// Left where it is; what it holds is not saved until Nook can open it again.
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Incident {
    pub id: u64,
    pub file: String,
    pub kind: IncidentKind,
    pub reason: String,
    pub moved_to: Option<String>,
}

static INCIDENTS: Mutex<Vec<Incident>> = Mutex::new(Vec::new());

pub fn incidents() -> Vec<Incident> {
    INCIDENTS.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn dismiss(id: u64) {
    INCIDENTS.lock().unwrap_or_else(|e| e.into_inner()).retain(|i| i.id != id);
}

fn record(mut incident: Incident) {
    let mut all = INCIDENTS.lock().unwrap_or_else(|e| e.into_inner());
    incident.id = all.iter().map(|i| i.id).max().unwrap_or(0) + 1;
    all.push(incident);
}

/// Whether an error means the file itself is damaged, rather than out of reach for now.
pub fn is_damage(error: &rusqlite::Error) -> bool {
    matches!(error, rusqlite::Error::SqliteFailure(e, _) if matches!(e.code, rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase))
}

/// The dated name a damaged file is moved to: `nook.sqlite` → `nook.damaged-20261120-101500.sqlite`.
pub fn aside_name(path: &Path, stamp: &str) -> PathBuf {
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    path.with_file_name(format!("{stem}.damaged-{stamp}{ext}"))
}

fn set_aside(path: &Path, stamp: &str) -> std::io::Result<PathBuf> {
    let target = aside_name(path, stamp);
    std::fs::rename(path, &target)?;
    for suffix in ["-wal", "-shm"] {
        let side = PathBuf::from(format!("{}{suffix}", path.display()));
        if side.exists() {
            let _ = std::fs::rename(&side, PathBuf::from(format!("{}{suffix}", target.display())));
        }
    }
    Ok(target)
}

/// Opens `path` with `open` (the store's own open: pragmas, migrations), checking the file first. A damaged file is set
/// aside and opened fresh; a file out of reach for another reason is left alone. None when there is nothing to use.
pub fn open<T>(path: &Path, open: impl Fn(&Path) -> Result<T, String>) -> Option<T> {
    let failure = match check(path).and_then(|_| open(path).map_err(Failure::Other)) {
        Ok(store) => return Some(store),
        Err(f) => f,
    };
    let file = path.to_string_lossy().into_owned();
    match failure {
        Failure::Damage(reason) => {
            let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
            match set_aside(path, &stamp) {
                Ok(copy) => {
                    let fresh = open(path);
                    let moved_to = Some(copy.to_string_lossy().into_owned());
                    match &fresh {
                        Ok(_) => record(Incident { id: 0, file, kind: IncidentKind::Damaged, reason, moved_to }),
                        Err(e) => record(Incident { id: 0, file, kind: IncidentKind::Unavailable, reason: e.clone(), moved_to }),
                    }
                    fresh.ok()
                }
                Err(e) => {
                    record(Incident { id: 0, file, kind: IncidentKind::Unavailable, reason: format!("{reason} ({e})"), moved_to: None });
                    None
                }
            }
        }
        Failure::Other(reason) => {
            record(Incident { id: 0, file, kind: IncidentKind::Unavailable, reason, moved_to: None });
            None
        }
    }
}

enum Failure {
    Damage(String),
    Other(String),
}

/// Reads the header and the schema, and runs `quick_check` on a small file (up to 8 MB), as the Mac does at launch.
fn check(path: &Path) -> Result<(), Failure> {
    if !path.exists() {
        return Ok(());
    }
    let conn = rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| if is_damage(&e) { Failure::Damage(e.to_string()) } else { Failure::Other(e.to_string()) })?;
    let classify = |e: rusqlite::Error| if is_damage(&e) { Failure::Damage(e.to_string()) } else { Failure::Other(e.to_string()) };
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0)).map_err(classify)?;
    let small = std::fs::metadata(path).map(|m| m.len() <= 8 << 20).unwrap_or(false);
    if small {
        let result: String = conn.query_row("PRAGMA quick_check", [], |r| r.get(0)).map_err(classify)?;
        if result != "ok" {
            return Err(Failure::Damage(result));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_that_is_no_database_is_set_aside_and_started_fresh() {
        let dir = std::env::temp_dir().join(format!("nook-recovery-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("nook.sqlite");
        std::fs::write(&path, b"this is not a database at all, but it is long enough to have a header....").unwrap();
        let opened = open(&path, |p| rusqlite::Connection::open(p).and_then(|c| c.execute_batch("CREATE TABLE t(x)").map(|_| c)).map_err(|e| e.to_string()));
        assert!(opened.is_some());
        let incident = incidents().into_iter().find(|i| i.file == path.to_string_lossy()).expect("an incident");
        assert_eq!(incident.kind, IncidentKind::Damaged);
        assert!(Path::new(incident.moved_to.as_deref().unwrap()).exists());
        dismiss(incident.id);
        assert!(incidents().iter().all(|i| i.id != incident.id));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn names_the_copy_by_date() {
        assert_eq!(aside_name(Path::new("/a/nook.sqlite"), "20261120-101500"), PathBuf::from("/a/nook.damaged-20261120-101500.sqlite"));
    }
}
