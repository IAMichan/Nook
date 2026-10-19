//! Mappen waar een agent mag werken (`WorkspacePathPolicy` op de Mac). Nooit systeemmappen, de hele schijf of je
//! thuismap zelf.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Verdict {
    Ok,
    Missing,
    NotDirectory,
    Unreadable,
    Forbidden,
}

impl Verdict {
    pub fn message(self, path: &str) -> String {
        match self {
            Self::Ok => String::new(),
            Self::Missing => format!("De map {path} bestaat niet."),
            Self::NotDirectory => format!("{path} is geen map."),
            Self::Unreadable => format!("Nook kan {path} niet lezen."),
            Self::Forbidden => "Kies een projectmap, niet je thuismap of een systeemmap.".into(),
        }
    }
}

#[cfg(windows)]
fn forbidden(path: &str) -> bool {
    let lower = path.to_lowercase().replace('/', "\\");
    let trimmed = lower.trim_end_matches('\\');
    // Een schijf zelf (C:), en de systeemmappen met alles erin.
    if trimmed.len() <= 2 && trimmed.ends_with(':') {
        return true;
    }
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into()).to_lowercase();
    let roots = [windir, "c:\\program files".into(), "c:\\program files (x86)".into(), "c:\\programdata".into(), "c:\\users".into()];
    roots.iter().any(|r| trimmed == r || r != "c:\\users" && trimmed.starts_with(&format!("{r}\\")))
}

#[cfg(not(windows))]
fn forbidden(path: &str) -> bool {
    const ROOTS: &[&str] = &[
        "/",
        "/System",
        "/Library",
        "/bin",
        "/sbin",
        "/usr",
        "/private",
        "/etc",
        "/var",
        "/dev",
        "/cores",
        "/opt",
        "/Applications",
        "/Volumes",
        "/home",
        "/root",
        "/boot",
        "/proc",
        "/sys",
        "/run",
        "/lib",
        "/lib64",
        "/mnt",
        "/media",
        "/srv",
    ];
    if ROOTS.contains(&path) {
        return true;
    }
    // Systeemmappen en alles erin, behalve /opt/…, /mnt/…, /media/… en /srv/… (externe schijven, projecten).
    ["/System", "/bin", "/sbin", "/usr", "/etc", "/dev", "/proc", "/sys", "/boot", "/private/etc", "/private/var/db", "/lib", "/lib64"]
        .iter()
        .any(|r| path.starts_with(&format!("{r}/")))
}

pub fn normalize(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let expanded: PathBuf = if let Some(rest) = trimmed.strip_prefix("~/").or_else(|| trimmed.strip_prefix("~\\")) {
        crate::agents::home_dir().join(rest)
    } else if trimmed == "~" {
        crate::agents::home_dir()
    } else {
        PathBuf::from(trimmed)
    };
    let resolved = std::fs::canonicalize(&expanded).unwrap_or(expanded);
    let text = resolved.to_string_lossy().into_owned();
    // Op Windows geeft canonicalize een `\\?\`-pad; dat begrijpen niet alle programma's.
    let text = text.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(text);
    if text.len() > 1 {
        text.trim_end_matches(['/', '\\']).to_string()
    } else {
        text
    }
}

pub fn verdict(raw: &str) -> Verdict {
    verdict_with_home(raw, &crate::agents::home_dir())
}

pub fn verdict_with_home(raw: &str, home: &Path) -> Verdict {
    let path = normalize(raw);
    if path.is_empty() {
        return Verdict::Missing;
    }
    if path == normalize(&home.to_string_lossy()) || forbidden(&path) {
        return Verdict::Forbidden;
    }
    let p = Path::new(&path);
    match std::fs::metadata(p) {
        Err(_) => Verdict::Missing,
        Ok(m) if !m.is_dir() => Verdict::NotDirectory,
        Ok(_) => {
            if std::fs::read_dir(p).is_err() {
                Verdict::Unreadable
            } else {
                Verdict::Ok
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_and_home_are_forbidden() {
        let home = std::env::temp_dir().join(format!("nook-home-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(home.join("project")).unwrap();
        assert_eq!(verdict_with_home(&home.to_string_lossy(), &home), Verdict::Forbidden);
        assert_eq!(verdict_with_home(&home.join("project").to_string_lossy(), &home), Verdict::Ok);
        assert_eq!(verdict_with_home(&home.join("nope").to_string_lossy(), &home), Verdict::Missing);
        assert_eq!(verdict_with_home("", &home), Verdict::Missing);
        #[cfg(not(windows))]
        {
            assert_eq!(verdict_with_home("/", &home), Verdict::Forbidden);
            assert_eq!(verdict_with_home("/usr/lib", &home), Verdict::Forbidden);
            assert_eq!(verdict_with_home("/etc", &home), Verdict::Forbidden);
        }
        let _ = std::fs::remove_dir_all(home);
    }
}
