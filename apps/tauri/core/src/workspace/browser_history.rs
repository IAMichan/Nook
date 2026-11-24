//! The pages you visited in Nook's browser (`BrowserHistory` on the Mac), for the address bar's suggestions. Only kept
//! while Settings › Sessions › Editor & browser › "Remember visited pages" is on; pages agents open are left out by the
//! caller. Stored in `browser-history.json`, newest first, at most `LIMIT` pages.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

pub const LIMIT: usize = 1000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Visit {
    pub url: String,
    pub title: String,
    /// Seconds since 1970.
    pub at: i64,
}

static LOCK: Mutex<()> = Mutex::new(());

pub fn file() -> PathBuf {
    crate::paths::support_directory().join("browser-history.json")
}

pub fn load(file: &Path) -> Vec<Visit> {
    std::fs::read(file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save(file: &Path, visits: &[Visit]) {
    if let Ok(bytes) = serde_json::to_vec(visits) {
        let _ = crate::paths::write_atomic(file, &bytes);
    }
}

/// Puts `url` at the top (once), with its newest title. Only web pages; a fragment does not make another page.
pub fn record_in(file: &Path, url: &str, title: &str, at: i64) {
    let Ok(mut parsed) = url::Url::parse(url.trim()) else { return };
    if !matches!(parsed.scheme(), "http" | "https") {
        return;
    }
    parsed.set_fragment(None);
    let url = parsed.to_string();
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut visits = load(file);
    let title = match visits.iter().position(|v| v.url == url) {
        Some(i) => {
            let old = visits.remove(i);
            if title.trim().is_empty() {
                old.title
            } else {
                title.trim().to_string()
            }
        }
        None => title.trim().to_string(),
    };
    visits.insert(0, Visit { url, title, at });
    visits.truncate(LIMIT);
    save(file, &visits);
}

pub fn clear_in(file: &Path) {
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _ = std::fs::remove_file(file);
}

/// The pages whose address (without its scheme and `www.`) or title starts with, or whose address contains, what you
/// typed; address matches first, newest first within each.
pub fn suggestions(visits: &[Visit], typed: &str, limit: usize) -> Vec<Visit> {
    let typed = typed.trim().to_lowercase();
    if typed.is_empty() {
        return vec![];
    }
    let bare = |u: &str| {
        let u = u.to_lowercase();
        let u = u.strip_prefix("https://").or_else(|| u.strip_prefix("http://")).map(str::to_string).unwrap_or(u);
        u.strip_prefix("www.").map(str::to_string).unwrap_or(u)
    };
    let typed_bare = bare(&typed);
    let mut first = vec![];
    let mut rest = vec![];
    for v in visits {
        let address = bare(&v.url);
        if address.starts_with(&typed_bare) {
            first.push(v.clone());
        } else if address.contains(&typed_bare) || v.title.to_lowercase().contains(&typed) {
            rest.push(v.clone());
        }
    }
    first.extend(rest);
    first.truncate(limit);
    first
}

pub fn record(url: &str, title: &str) {
    record_in(&file(), url, title, chrono::Utc::now().timestamp());
}

pub fn count() -> usize {
    load(&file()).len()
}

pub fn clear() {
    clear_in(&file());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-history-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("browser-history.json")
    }

    #[test]
    fn records_newest_first_once_and_only_web_pages() {
        let file = scratch();
        record_in(&file, "https://example.com/a#top", "A", 1);
        record_in(&file, "https://nook.app/", "Nook", 2);
        record_in(&file, "https://example.com/a", "", 3);
        record_in(&file, "file:///etc/passwd", "no", 4);
        record_in(&file, "javascript:alert(1)", "no", 5);
        let visits = load(&file);
        assert_eq!(visits.len(), 2);
        assert_eq!(visits[0], Visit { url: "https://example.com/a".into(), title: "A".into(), at: 3 });
        assert_eq!(visits[1].url, "https://nook.app/");
        clear_in(&file);
        assert!(load(&file).is_empty());
        let _ = std::fs::remove_dir_all(file.parent().unwrap());
    }

    #[test]
    fn keeps_at_most_the_limit() {
        let file = scratch();
        let many: Vec<Visit> = (0..LIMIT).map(|i| Visit { url: format!("https://x.test/{i}"), title: String::new(), at: 0 }).collect();
        save(&file, &many);
        record_in(&file, "https://new.test/", "New", 1);
        let visits = load(&file);
        assert_eq!(visits.len(), LIMIT);
        assert_eq!(visits[0].url, "https://new.test/");
        let _ = std::fs::remove_dir_all(file.parent().unwrap());
    }

    #[test]
    fn suggests_address_matches_before_title_matches() {
        let visits = vec![
            Visit { url: "https://docs.rs/serde".into(), title: "serde - Rust".into(), at: 3 },
            Visit { url: "https://www.rust-lang.org/".into(), title: "Rust".into(), at: 2 },
            Visit { url: "https://example.com/".into(), title: "Example".into(), at: 1 },
        ];
        let found: Vec<_> = suggestions(&visits, "rust", 5).into_iter().map(|v| v.url).collect();
        assert_eq!(found, vec!["https://www.rust-lang.org/", "https://docs.rs/serde"]);
        assert_eq!(suggestions(&visits, "https://exa", 5)[0].url, "https://example.com/");
        assert!(suggestions(&visits, "  ", 5).is_empty());
        assert_eq!(suggestions(&visits, "s", 1).len(), 1);
    }
}
