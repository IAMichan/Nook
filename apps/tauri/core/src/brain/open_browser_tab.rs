//! Reading a web page open in the user's own browser (`read_browser_tab`): matching running desktop browsers,
//! cleaning window titles and omnibox URLs, and formatting what was found for the brain. Pure logic here so it can
//! be unit-tested on every OS; the platform layer (`ScreenReader::read_browser_tab`) reads the browser through UI
//! Automation on Windows and AT-SPI on Linux (and in the future can prefer the browser extension from CH-60 first).

use serde::{Deserialize, Serialize};

use super::retrieval::{self, SourceReference};

/// The longest page text handed to the brain.
pub const TEXT_LIMIT: usize = 12_000;

/// Metadata for a desktop browser Nook knows how to inspect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrowserSpec {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub title_suffixes: &'static [&'static str],
}

/// Desktop browsers Nook reads tabs from, in priority order.
pub const BROWSERS: &[BrowserSpec] = &[
    BrowserSpec {
        name: "Google Chrome",
        aliases: &["chrome", "google chrome", "google-chrome", "chrome.exe"],
        title_suffixes: &[" - Google Chrome", " — Google Chrome", " - Chrome"],
    },
    BrowserSpec {
        name: "Microsoft Edge",
        aliases: &["msedge", "edge", "microsoft edge", "microsoft-edge", "msedge.exe"],
        title_suffixes: &[" - Microsoft Edge", " — Microsoft Edge", " - Microsoft\u{200b} Edge"],
    },
    BrowserSpec {
        name: "Brave Browser",
        aliases: &["brave", "brave browser", "brave-browser", "brave.exe"],
        title_suffixes: &[" - Brave", " — Brave", " - Brave Browser"],
    },
    BrowserSpec { name: "Arc", aliases: &["arc", "arc.exe"], title_suffixes: &[" - Arc", " — Arc"] },
    BrowserSpec { name: "Vivaldi", aliases: &["vivaldi", "vivaldi.exe"], title_suffixes: &[" - Vivaldi", " — Vivaldi"] },
    BrowserSpec { name: "Opera", aliases: &["opera", "opera.exe"], title_suffixes: &[" - Opera", " — Opera"] },
    BrowserSpec {
        name: "Firefox",
        aliases: &["firefox", "mozilla firefox", "firefox-esr", "firefox.exe"],
        title_suffixes: &[" — Mozilla Firefox", " - Mozilla Firefox", " — Firefox", " - Firefox"],
    },
    BrowserSpec {
        name: "Zen",
        aliases: &["zen", "zen browser", "zen-browser", "zen.exe"],
        title_suffixes: &[" — Zen Browser", " - Zen Browser", " — Zen", " - Zen"],
    },
    BrowserSpec {
        name: "Chromium",
        aliases: &["chromium", "chromium-browser", "chromium.exe"],
        title_suffixes: &[" - Chromium", " — Chromium"],
    },
];

/// An open browser tab found on the user's desktop.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserTab {
    pub browser: String,
    pub title: String,
    pub url: String,
    /// True when the tab is the active tab shown in its window; false for a tab behind another tab.
    pub visible: bool,
    pub text: String,
}

/// Platform outcome of reading an open browser tab.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserTabResult {
    Found(BrowserTab),
    NotFound { running: Vec<String> },
    Unsupported,
}

/// Matches a display name, executable name or user-typed browser name against `BROWSERS`.
pub fn match_browser(name_or_id: &str) -> Option<&'static BrowserSpec> {
    let lower = name_or_id.trim().to_lowercase();
    if lower.is_empty() {
        return None;
    }
    let stem = lower.strip_suffix(".exe").unwrap_or(&lower);
    BROWSERS.iter().find(|spec| {
        spec.name.eq_ignore_ascii_case(stem)
            || spec.aliases.iter().any(|a| *a == lower || *a == stem)
            || spec.name.to_lowercase().contains(stem) && stem.len() >= 3
            || stem.contains(&spec.name.to_lowercase())
    })
}

/// Splits optional `tab` and `browser` arguments into `(browser_filter, tab_query)`.
/// If only `tab` was given and it is clearly a browser name (e.g. `"Edge"`), treats it as a browser filter.
pub fn parse_query(tab: &str, browser: &str) -> (Option<&'static BrowserSpec>, Option<String>) {
    let tab_trim = tab.trim();
    let browser_trim = browser.trim();
    if !browser_trim.is_empty() {
        let spec = match_browser(browser_trim);
        let q = (!tab_trim.is_empty()).then(|| tab_trim.to_string());
        return (spec, q);
    }
    if tab_trim.is_empty() {
        return (None, None);
    }
    if !tab_trim.contains('.') && !tab_trim.contains('/') {
        if let Some(spec) = match_browser(tab_trim) {
            return (Some(spec), None);
        }
    }
    (None, Some(tab_trim.to_string()))
}

/// Removes the browser's own window title suffix (`" - Google Chrome"`, `" — Mozilla Firefox"`, etc.).
pub fn clean_tab_title(window_title: &str, browser_name: &str) -> String {
    let mut trimmed = window_title.trim();
    if let Some(spec) = match_browser(browser_name) {
        for suffix in spec.title_suffixes {
            if let Some(stripped) = trimmed.strip_suffix(suffix) {
                trimmed = stripped.trim();
                break;
            }
        }
    } else {
        for spec in BROWSERS {
            for suffix in spec.title_suffixes {
                if let Some(stripped) = trimmed.strip_suffix(suffix) {
                    return stripped.trim().to_string();
                }
            }
        }
    }
    trimmed.to_string()
}

/// Normalizes a URL read from a browser's address bar or document value (adds `https://` when Chromium hides it).
/// Returns an empty string when `raw` does not look like an address.
pub fn normalize_url(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_whitespace) {
        return String::new();
    }
    let candidate = if trimmed.starts_with("https://") || trimmed.starts_with("http://") || trimmed.starts_with("file://") {
        trimmed.to_string()
    } else if trimmed.starts_with("localhost") && (trimmed.len() == 9 || trimmed[9..].starts_with(':') || trimmed[9..].starts_with('/')) {
        format!("http://{trimmed}")
    } else if trimmed.contains('.') && !trimmed.starts_with('.') && !trimmed.ends_with('.') && !trimmed.contains("://") {
        let host = trimmed.split('/').next().unwrap_or("");
        if host.split('.').all(|part| !part.is_empty()) {
            format!("https://{trimmed}")
        } else {
            return String::new();
        }
    } else {
        return String::new();
    };
    match url::Url::parse(&candidate) {
        Ok(u) if matches!(u.scheme(), "https" | "http" | "file") => candidate,
        _ => String::new(),
    }
}

/// Whether `haystack` (tab title or URL) matches the user's `query` (case-insensitive).
pub fn tab_matches(title: &str, url: &str, query: &str) -> bool {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return true;
    }
    title.to_lowercase().contains(&q) || url.to_lowercase().contains(&q)
}

/// Truncates page text cleanly to `TEXT_LIMIT` characters.
pub fn cap_text(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= TEXT_LIMIT {
        trimmed.to_string()
    } else {
        trimmed.chars().take(TEXT_LIMIT).collect()
    }
}

/// Formats an open browser tab for the brain, plus a citation reference line when the URL is openable.
pub fn describe(tab: &BrowserTab) -> String {
    let heading_title = if tab.title.trim().is_empty() { tab.url.trim() } else { tab.title.trim() };
    let mut lines = vec![format!("## {} ({})", heading_title, tab.browser)];
    if !tab.url.trim().is_empty() {
        lines.push(format!("URL: {}", tab.url.trim()));
    }
    lines.push(if tab.visible {
        format!("This tab is open and shown in the user's {} window.", tab.browser)
    } else {
        format!("This tab is open in {} but behind another tab in its window.", tab.browser)
    });
    lines.push(String::new());
    let body = cap_text(&tab.text);
    if body.is_empty() {
        lines.push("The page's text could not be read, but the page is open. Do not say it is not open or not on screen.".into());
    } else {
        lines.push(body);
    }
    let mut out = lines.join("\n");
    if SourceReference::is_openable(Some(tab.url.trim())) {
        let ref_title = if tab.title.trim().is_empty() { tab.url.trim() } else { tab.title.trim() };
        out.push_str("\n\n");
        out.push_str(&retrieval::reference_line(ref_title, Some(tab.url.trim()), &tab.browser));
    }
    out
}

/// Message returned when no matching tab or running browser was found.
pub fn no_browser_message(running_browsers: &[String], tab_query: Option<&str>) -> String {
    if running_browsers.is_empty() {
        return "No browser that Nook can read (Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox, Zen) is running.".into();
    }
    if let Some(query) = tab_query.map(str::trim).filter(|q| !q.is_empty()) {
        return format!(
            "No open tab whose title or address contains \"{query}\" in {}. Call read_browser_tab without a name for the page shown in the browser.",
            running_browsers.join(", ")
        );
    }
    format!("No open web page found in {}.", running_browsers.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_desktop_browsers_by_exe_or_name() {
        assert_eq!(match_browser("msedge.exe").map(|b| b.name), Some("Microsoft Edge"));
        assert_eq!(match_browser("chrome").map(|b| b.name), Some("Google Chrome"));
        assert_eq!(match_browser("firefox").map(|b| b.name), Some("Firefox"));
        assert_eq!(match_browser("Brave Browser").map(|b| b.name), Some("Brave Browser"));
        assert!(match_browser("notepad.exe").is_none());
    }

    #[test]
    fn parses_tab_and_browser_queries() {
        assert_eq!(parse_query("", "").0, None);
        assert_eq!(parse_query("", "").1, None);
        let (b, t) = parse_query("Edge", "");
        assert_eq!(b.map(|s| s.name), Some("Microsoft Edge"));
        assert_eq!(t, None);
        let (b, t) = parse_query("FileSender", "");
        assert_eq!(b, None);
        assert_eq!(t.as_deref(), Some("FileSender"));
        let (b, t) = parse_query("bol.com", "Chrome");
        assert_eq!(b.map(|s| s.name), Some("Google Chrome"));
        assert_eq!(t.as_deref(), Some("bol.com"));
        let (b, t) = parse_query("arc.dev", "");
        assert_eq!(b, None);
        assert_eq!(t.as_deref(), Some("arc.dev"));
    }

    #[test]
    fn cleans_window_title_suffixes_and_normalizes_urls() {
        assert_eq!(clean_tab_title("FileSender - Google Chrome", "Google Chrome"), "FileSender");
        assert_eq!(clean_tab_title("Docs — Mozilla Firefox", "Firefox"), "Docs");
        assert_eq!(clean_tab_title("GitHub - Microsoft Edge", "msedge"), "GitHub");

        assert_eq!(normalize_url("https://filesender.bit.nl/?s=upload"), "https://filesender.bit.nl/?s=upload");
        assert_eq!(normalize_url("github.com/IAMichan/Nook"), "https://github.com/IAMichan/Nook");
        assert_eq!(normalize_url("localhost:3000/app"), "http://localhost:3000/app");
        assert_eq!(normalize_url("Search or enter web address"), "");
        assert_eq!(normalize_url(""), "");
    }

    #[test]
    fn describes_visible_unreadable_and_background_tabs() {
        let visible_empty = BrowserTab {
            browser: "Microsoft Edge".into(),
            title: "FileSender".into(),
            url: "https://filesender.bit.nl/?s=upload".into(),
            visible: true,
            text: String::new(),
        };
        let out = describe(&visible_empty);
        assert!(out.contains("## FileSender (Microsoft Edge)"));
        assert!(out.contains("URL: https://filesender.bit.nl/?s=upload"));
        assert!(out.contains("Do not say it is not open"));
        assert!(out.contains("https://filesender.bit.nl/?s=upload"));

        let behind = BrowserTab {
            browser: "Firefox".into(),
            title: "Upload".into(),
            url: "https://example.com".into(),
            visible: false,
            text: "Line one\nLine two".into(),
        };
        let out = describe(&behind);
        assert!(out.contains("behind another tab"));
        assert!(out.contains("Line one\nLine two"));
    }

    #[test]
    fn formats_missing_browser_and_tab_messages() {
        assert!(no_browser_message(&[], None).contains("Chrome, Edge"));
        let msg = no_browser_message(&["Google Chrome".into()], Some("FileSender"));
        assert!(msg.contains("FileSender"));
        assert!(msg.contains("read_browser_tab without a name"));
    }
}
