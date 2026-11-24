//! Diagnostics (Settings › System › Diagnostics, `DiagnosticsLog` and `DiagnosticsRedactor` on the Mac): Nook's own log
//! as rotating files in the data folder, the lines of the last half hour, and a redacted report to copy into a bug
//! report. The report never holds mail addresses, keys or tokens, phone numbers or your name in paths.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use chrono::{DateTime, Duration, Local, NaiveDateTime, TimeZone};
use regex::Regex;

/// The size one log file grows to before it is rotated.
pub const MAX_BYTES: u64 = 2_000_000;
/// How many older files are kept (`nook.log.1` … `nook.log.3`).
pub const KEEP: usize = 3;
/// The time format at the start of every line.
const STAMP: &str = "%Y-%m-%d %H:%M:%S%.3f";

pub fn log_dir() -> PathBuf {
    crate::paths::support_directory().join("logs")
}

/// A log file that rotates: at `max_bytes` the current file becomes `.1`, `.1` becomes `.2`, and so on up to `keep`.
pub struct RotatingLog {
    dir: PathBuf,
    max_bytes: u64,
    keep: usize,
    lock: Mutex<()>,
}

impl RotatingLog {
    pub fn new(dir: PathBuf, max_bytes: u64, keep: usize) -> Self {
        let _ = fs::create_dir_all(&dir);
        Self { dir, max_bytes, keep, lock: Mutex::new(()) }
    }

    pub fn file(&self) -> PathBuf {
        self.dir.join("nook.log")
    }

    fn numbered(&self, n: usize) -> PathBuf {
        self.dir.join(format!("nook.log.{n}"))
    }

    /// Appends one line with the time in front; rotates first when the file is full.
    pub fn append(&self, now: DateTime<Local>, level: &str, target: &str, message: &str) {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let file = self.file();
        if fs::metadata(&file).map(|m| m.len() >= self.max_bytes).unwrap_or(false) {
            let _ = fs::remove_file(self.numbered(self.keep));
            for n in (1..self.keep).rev() {
                let _ = fs::rename(self.numbered(n), self.numbered(n + 1));
            }
            let _ = fs::rename(&file, self.numbered(1));
        }
        // One line per entry: a message that spans lines keeps them joined so the time stays in front of each entry.
        let message = message.replace('\n', " ⏎ ");
        if let Ok(mut out) = OpenOptions::new().create(true).append(true).open(&file) {
            let _ = writeln!(out, "{} {level:<5} {target}: {message}", now.format(STAMP));
        }
    }

    /// The lines written since `since`, oldest first, from the current file and the one before it.
    pub fn lines_since(&self, since: DateTime<Local>) -> Vec<String> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = vec![];
        for path in [self.numbered(1), self.file()] {
            let Ok(text) = fs::read_to_string(&path) else { continue };
            for line in text.lines() {
                if stamp_of(line).is_some_and(|t| t >= since) {
                    out.push(line.to_string());
                }
            }
        }
        out
    }
}

fn stamp_of(line: &str) -> Option<DateTime<Local>> {
    let head = line.get(..23)?;
    let naive = NaiveDateTime::parse_from_str(head, STAMP).ok()?;
    Local.from_local_datetime(&naive).single()
}

/// The one log of this Nook, opened at the first line written.
pub fn log() -> &'static RotatingLog {
    static LOG: OnceLock<RotatingLog> = OnceLock::new();
    LOG.get_or_init(|| RotatingLog::new(log_dir(), MAX_BYTES, KEEP))
}

/// The log of the last `minutes` minutes.
pub fn recent(minutes: i64) -> Vec<String> {
    log().lines_since(Local::now() - Duration::minutes(minutes))
}

/// Takes out what could identify you or open your accounts (`DiagnosticsRedactor`): mail addresses, keys and tokens,
/// phone numbers, and your account name in paths.
pub fn redact(text: &str, user: &str) -> String {
    static RULES: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    let rules = RULES.get_or_init(|| {
        vec![
            (Regex::new(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}").unwrap(), "<mail>"),
            // Known key shapes first, then any long run of key-like characters.
            (Regex::new(r"\b(sk|pk|rk|ghp|gho|ghu|ghs|github_pat|xox[abpr]|glpat|AIza|ya29)[-_A-Za-z0-9]{10,}").unwrap(), "<key>"),
            (Regex::new(r"(?i)(bearer|token|key|secret|password)([=: ]+)[^\s,;]+").unwrap(), "$1$2<key>"),
            (Regex::new(r"\b[A-Za-z0-9_\-]{32,}\b").unwrap(), "<key>"),
            (Regex::new(r"\+?\d[\d \-()]{7,}\d").unwrap(), "<phone>"),
            (Regex::new(r"(?i)([\\/](?:Users|home)[\\/])[^\\/\s]+").unwrap(), "$1<you>"),
        ]
    });
    let mut out = text.to_string();
    for (pattern, replacement) in rules {
        out = pattern.replace_all(&out, *replacement).into_owned();
    }
    let user = user.trim();
    if user.chars().count() >= 3 {
        out = out.replace(user, "<you>");
    }
    out
}

/// The report Settings copies: a header of facts (versions, set-up) and the log of the last half hour, redacted.
pub fn report(header: &[(String, String)], user: &str) -> String {
    let mut text = String::new();
    for (name, value) in header {
        text.push_str(&format!("{name}: {value}\n"));
    }
    text.push_str("\n--- log, last 30 minutes ---\n");
    for line in recent(30) {
        text.push_str(&line);
        text.push('\n');
    }
    redact(&text, user)
}

/// The size of every file in `dir`, together.
pub fn folder_size(dir: &Path) -> u64 {
    fs::read_dir(dir).map(|it| it.flatten().filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_and_reads_back_the_recent_lines() {
        let dir = std::env::temp_dir().join(format!("nook-log-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let log = RotatingLog::new(dir.clone(), 200, 2);
        let now = Local::now();
        for i in 0..20 {
            log.append(now, "INFO", "test", &format!("line {i}"));
        }
        assert!(log.numbered(1).exists());
        assert!(!log.numbered(3).exists());
        let recent = log.lines_since(now - Duration::minutes(1));
        assert!(recent.iter().any(|l| l.ends_with("line 19")));
        assert!(log.lines_since(now + Duration::minutes(1)).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn takes_out_what_identifies_you() {
        let text = "mail anna@example.com key sk-abcdefghijklmnop1234 call +31 6 1234 5678 at C:\\Users\\Michan\\nook token=abc123";
        let out = redact(text, "Michan van der Hoek");
        assert!(!out.contains("anna@example.com"));
        assert!(!out.contains("sk-abcdefghijklmnop1234"));
        assert!(!out.contains("1234 5678"));
        assert!(!out.contains("Michan\\"));
        assert!(out.contains("token=<key>"));
    }
}
