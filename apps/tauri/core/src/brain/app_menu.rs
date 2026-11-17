//! Every desktop app exposes commands in its menu bar, so the chat can act in any app the same way: list what the
//! menus offer (`list_app_menu`), then propose one command (`app_menu_command`) that runs only after the user approves
//! it. Pure logic here so parsing, label matching, validation and formatting can be tested on any OS; the platform
//! layer (`ScreenReader`) walks UI Automation / Win32 `HMENU` on Windows and AT-SPI on Linux.

use std::collections::HashSet;

use serde_json::Value;

use crate::services::screen;

/// Menus deeper than this are not listed or clicked: real commands live at most two levels below the menu bar.
pub const MAX_DEPTH: usize = 3;
/// Maximum lines returned by `list_app_menu` before truncation.
pub const DEFAULT_LIMIT: usize = 150;

/// A menu path from a tool call: an array of titles, or one string like `"File > New Folder"` (also `›`, `→`, `->`).
pub fn path(value: &Value) -> Vec<String> {
    let raw: Vec<String> = match value {
        Value::Array(items) => items.iter().filter_map(|v| v.as_str().map(str::to_string)).collect(),
        Value::String(text) => {
            const SEPARATORS: [&str; 7] = [" > ", " › ", " → ", " -> ", ">", "›", "→"];
            if let Some(sep) = SEPARATORS.iter().find(|s| text.contains(*s)) {
                text.split(sep).map(str::to_string).collect()
            } else {
                vec![text.clone()]
            }
        }
        _ => vec![],
    };
    raw.into_iter().map(|part| part.trim().to_string()).filter(|part| !part.is_empty()).collect()
}

/// Cleans a menu item's label for display and matching: removes any `\tShortcut` suffix and Win32 `&` accelerator
/// markers (`&&` becomes `&`, single `&` is stripped).
pub fn clean_label(raw: &str) -> String {
    let before_tab = raw.split('\t').next().unwrap_or("");
    let mut out = String::with_capacity(before_tab.len());
    let mut chars = before_tab.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '&' {
            if chars.peek() == Some(&'&') {
                out.push('&');
                chars.next();
            }
        } else {
            out.push(ch);
        }
    }
    out.trim().to_string()
}

fn normalized_for_match(label: &str) -> String {
    clean_label(label).to_lowercase().replace('…', "").replace("...", "").split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Whether a menu item's label matches the segment requested by the model (case-insensitive, ignoring `&` mnemonics,
/// shortcut hints after `\t`, and trailing ellipsis).
pub fn label_matches(candidate: &str, wanted: &str) -> bool {
    let a = normalized_for_match(candidate);
    let b = normalized_for_match(wanted);
    !a.is_empty() && a == b
}

/// What is wrong with a menu command, in plain language (empty = valid).
pub fn problems(app: &str, path: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let trimmed = app.trim();
    if trimmed.is_empty() {
        out.push("the app name is missing".into());
    } else if screen::is_excluded(trimmed) {
        out.push(format!("Nook does not control {trimmed}."));
    }
    if path.len() < 2 {
        out.push("give the full menu path, from the menu bar to the item, e.g. [\"File\", \"New Folder\"]".into());
    }
    if path.len() > MAX_DEPTH {
        out.push(format!("a menu path has at most {MAX_DEPTH} levels"));
    }
    out
}

/// The listing for the model: matches for `filter` first (case-insensitive), at most `limit` lines.
pub fn describe(raw: &[String], app: &str, filter: Option<&str>, limit: usize) -> String {
    let mut seen = HashSet::new();
    let mut lines: Vec<String> = raw.iter().map(|l| l.trim().to_string()).filter(|l| !l.is_empty() && seen.insert(l.clone())).collect();
    if lines.is_empty() {
        return format!("{app} shows no menu commands right now.");
    }
    if let Some(filter) = filter.map(str::trim).filter(|f| !f.is_empty()) {
        let words: Vec<String> = filter.to_lowercase().split_whitespace().map(str::to_string).collect();
        let hits: Vec<String> = lines
            .iter()
            .filter(|line| {
                let lower = line.to_lowercase();
                words.iter().any(|w| lower.contains(w))
            })
            .cloned()
            .collect();
        if !hits.is_empty() {
            lines = hits;
        }
    }
    let total = lines.len();
    let shown = &lines[..total.min(limit)];
    let more = if total > limit { format!("\n… {} more; pass a filter word to narrow the list.", total - limit) } else { String::new() };
    let bullets = shown.iter().map(|l| format!("- {l}")).collect::<Vec<_>>().join("\n");
    format!("Menu commands of {app} (use app_menu_command with one of these paths):\n{bullets}{more}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_paths_from_arrays_and_strings() {
        assert_eq!(path(&json!(["File", "New Folder"])), vec!["File", "New Folder"]);
        assert_eq!(path(&json!("File > New Folder")), vec!["File", "New Folder"]);
        assert_eq!(path(&json!("Edit › Paste and Match Style")), vec!["Edit", "Paste and Match Style"]);
        assert_eq!(path(&json!("View → Zoom In")), vec!["View", "Zoom In"]);
        assert_eq!(path(&json!("File -> Export -> PDF")), vec!["File", "Export", "PDF"]);
        assert!(path(&json!(null)).is_empty());
    }

    #[test]
    fn cleans_accelerators_and_shortcuts() {
        assert_eq!(clean_label("&File"), "File");
        assert_eq!(clean_label("Save &As...\tCtrl+Shift+S"), "Save As...");
        assert_eq!(clean_label("Search && Replace"), "Search & Replace");
        assert!(label_matches("&Save As...\tCtrl+Shift+S", "Save As…"));
        assert!(label_matches("&File", "file"));
        assert!(!label_matches("", "file"));
    }

    #[test]
    fn validates_app_and_depth() {
        assert!(problems("Notepad", &["File".into(), "Save".into()]).is_empty());
        assert_eq!(problems("", &["File".into(), "Save".into()]), vec!["the app name is missing"]);
        assert!(!problems("1Password", &["File".into(), "Lock".into()]).is_empty());
        assert!(!problems("Nook", &["File".into(), "Quit".into()]).is_empty());
        assert!(!problems("Notepad", &["File".into()]).is_empty());
        assert!(!problems("Notepad", &["A".into(), "B".into(), "C".into(), "D".into()]).is_empty());
    }

    #[test]
    fn describes_deduplicated_filtered_and_limited_menus() {
        let raw = vec!["File > New".into(), "File > New".into(), "File > Save".into(), "Edit > Copy".into(), "Edit > Paste".into()];
        let filtered = describe(&raw, "Notepad", Some("save copy"), DEFAULT_LIMIT);
        assert!(filtered.contains("- File > Save"));
        assert!(filtered.contains("- Edit > Copy"));
        assert!(!filtered.contains("Paste"));

        let limited = describe(&raw, "Notepad", None, 2);
        assert!(limited.contains("- File > New"));
        assert!(limited.contains("- File > Save"));
        assert!(limited.contains("… 2 more; pass a filter word to narrow the list."));

        assert_eq!(describe(&[], "Notepad", None, DEFAULT_LIMIT), "Notepad shows no menu commands right now.");
    }
}
