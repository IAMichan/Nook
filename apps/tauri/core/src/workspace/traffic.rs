//! "Keep agent traffic" (Settings › System › Diagnostics, `ProviderTrafficLog` on the Mac): per session and process,
//! what Nook and the agent send each other, to replay a bug. Up to 4 MB per process, in the data folder under
//! `workspace/provider-traffic`; only the protocol lines are written, never the environment or a key.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

/// The most one process writes.
pub const LIMIT: u64 = 4_000_000;

static ON: AtomicBool = AtomicBool::new(false);

/// Set from the workspace settings when they are read or saved.
pub fn set_enabled(on: bool) {
    ON.store(on, Ordering::Relaxed);
}

pub fn enabled() -> bool {
    ON.load(Ordering::Relaxed)
}

pub fn folder() -> PathBuf {
    crate::paths::support_directory().join("workspace").join("provider-traffic")
}

/// The traffic file of one agent process; writing stops at `LIMIT`.
pub struct Recorder {
    file: Mutex<Option<(File, u64)>>,
}

impl Recorder {
    /// A recorder for run `run` and process `pid`, or none while the setting is off.
    pub fn open(run: &str, pid: Option<u32>) -> Option<Self> {
        if !enabled() {
            return None;
        }
        let dir = folder();
        fs::create_dir_all(&dir).ok()?;
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let path = dir.join(format!("{run}-{}-{stamp}.log", pid.unwrap_or(0)));
        let file = OpenOptions::new().create(true).append(true).open(path).ok()?;
        Some(Self { file: Mutex::new(Some((file, 0))) })
    }

    /// `to_agent`: a line Nook wrote to the agent; otherwise one the agent wrote.
    pub fn line(&self, to_agent: bool, text: &str) {
        let mut guard = self.file.lock().unwrap_or_else(|e| e.into_inner());
        let Some((file, written)) = guard.as_mut() else { return };
        let entry = format!("{} {} {}\n", chrono::Local::now().format("%H:%M:%S%.3f"), if to_agent { ">" } else { "<" }, text.trim_end());
        if *written + entry.len() as u64 > LIMIT {
            let _ = file.write_all(b"... the rest of this process is not kept (4 MB)\n");
            *guard = None;
            return;
        }
        if file.write_all(entry.as_bytes()).is_ok() {
            *written += entry.len() as u64;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_nothing_while_off() {
        set_enabled(false);
        assert!(Recorder::open("run", Some(1)).is_none());
    }
}
