//! `nook://` deep links (`NookDeepLink`, `SessionLink`, `PromptLink`, `IncomingLinkRoute` on the Mac):
//! parsing and routing `nook://` URLs into safe structured navigation targets without executing arbitrary commands.

use serde::{Deserialize, Serialize};
use url::Url;

/// Where an incoming web link opens while Nook acts as the default browser (`IncomingLinkTarget` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum IncomingLinkTarget {
    /// Opens in the browser of the session on screen, or in Nook's main browser when no session is on screen.
    #[default]
    Session,
    /// Opens in Nook's own browser in the main window (Agents › Browser).
    NookBrowser,
}

/// How an incoming URL handed to Nook is routed (`IncomingLinkRoute` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "route")]
pub enum IncomingLinkDecision {
    /// Nook's own `nook://` deep link.
    NookLink { target: DeepLinkRoute },
    /// A new tab in the session browser panel currently visible on screen.
    SessionPanel { url: String },
    /// The session on screen's browser, brought up in its side panel.
    SessionBrowser { url: String },
    /// Nook's own browser, full size in the main window.
    NookBrowser { url: String },
    /// Not a `nook://` or web link Nook handles: pass to the previous default browser / system opener.
    PreviousBrowser { url: String },
}

/// A parsed `nook://` deep link target (`NookDeepLink`, `SessionLink`, `PromptLink` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum DeepLinkRoute {
    /// `nook://chat/<id>` or `nook://conversation/<id>`: opens a chat thread or Nook conversation.
    Chat { id: String },
    /// `nook://session/<id>?title=...`: opens a coding agent session.
    Session {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    /// `nook://settings/<page>` (or `nook://memory` → `settings/memory`): opens a settings page.
    Settings { page: String },
    /// `nook://new`: opens a fresh Nook conversation or new session composer.
    New {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        project: Option<String>,
    },
    /// `nook://ask?q=...` or `nook://prompt?text=...`: pre-fills a question/draft (never auto-sends).
    Ask {
        query: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repo: Option<String>,
    },
    /// `nook://shortcuts`: opens the keyboard shortcuts sheet.
    Shortcuts,
}

impl DeepLinkRoute {
    pub const SCHEME: &'static str = "nook";
    pub const MAX_TEXT_LEN: usize = 4_000;
    pub const MAX_TITLE_LEN: usize = 200;

    /// Parses a `nook://` URL string into a structured [`DeepLinkRoute`].
    /// Returns `None` if the scheme is not `nook://`, the host is unknown, or parameters are invalid.
    pub fn parse(raw: &str) -> Option<Self> {
        let trimmed = raw.trim();
        let url = Url::parse(trimmed).ok()?;
        Self::parse_url(&url)
    }

    /// Parses a [`Url`] with the `nook` scheme.
    pub fn parse_url(url: &Url) -> Option<Self> {
        if !url.scheme().eq_ignore_ascii_case(Self::SCHEME) {
            return None;
        }
        let host = url.host_str()?.to_lowercase();
        let segments: Vec<&str> = url.path_segments().map(|s| s.filter(|p| !p.is_empty()).collect()).unwrap_or_default();

        match host.as_str() {
            "chat" | "conversation" | "chats" => {
                let raw_id = if segments.len() == 1 {
                    percent_decode(segments[0])?
                } else if segments.is_empty() {
                    query_param(url, "id").or_else(|| query_param(url, "key"))?
                } else {
                    return None;
                };
                let id = clean_identifier(&raw_id)?;
                Some(Self::Chat { id })
            }
            "session" | "sessions" => {
                if segments.len() != 1 {
                    return None;
                }
                let raw_id = percent_decode(segments[0])?;
                let id = clean_identifier(&raw_id)?;
                let title = query_param(url, "title").map(|t| clean_single_line(&t, Self::MAX_TITLE_LEN)).filter(|t| !t.is_empty());
                Some(Self::Session { id, title })
            }
            "settings" => {
                if segments.len() > 1 {
                    return None;
                }
                let page = segments.first().map(|s| s.to_lowercase()).unwrap_or_default();
                if !page.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
                    return None;
                }
                Some(Self::Settings { page })
            }
            "memory" => {
                if !segments.is_empty() {
                    return None;
                }
                Some(Self::Settings { page: "memory".to_string() })
            }
            "shortcuts" => {
                if !segments.is_empty() {
                    return None;
                }
                Some(Self::Shortcuts)
            }
            "new" => {
                if !segments.is_empty() {
                    return None;
                }
                let q = query_param(url, "q").or_else(|| query_param(url, "text")).or_else(|| query_param(url, "prompt"));
                let project = query_param(url, "project").map(|p| clean_single_line(&p, Self::MAX_TITLE_LEN)).filter(|p| !p.is_empty());
                if let Some(text) = q.map(|t| clean_text(&t, Self::MAX_TEXT_LEN)).filter(|t| !t.is_empty()) {
                    let repo = query_param(url, "repo").map(|r| clean_single_line(&r, Self::MAX_TITLE_LEN)).filter(|r| !r.is_empty());
                    return Some(Self::Ask { query: text, project, repo });
                }
                Some(Self::New { project })
            }
            "ask" | "prompt" => {
                if !segments.is_empty() {
                    return None;
                }
                let raw_q =
                    query_param(url, "q").or_else(|| query_param(url, "text")).or_else(|| query_param(url, "prompt")).unwrap_or_default();
                let query = clean_text(&raw_q, Self::MAX_TEXT_LEN);
                if query.is_empty() {
                    return None;
                }
                let project = query_param(url, "project").map(|p| clean_single_line(&p, Self::MAX_TITLE_LEN)).filter(|p| !p.is_empty());
                let repo = query_param(url, "repo").map(|r| clean_single_line(&r, Self::MAX_TITLE_LEN)).filter(|r| !r.is_empty());
                Some(Self::Ask { query, project, repo })
            }
            _ => None,
        }
    }

    /// Formats this route back into a canonical `nook://` URL string.
    pub fn to_url_string(&self) -> String {
        match self {
            Self::Chat { id } => format!("nook://chat/{}", percent_encode(id)),
            Self::Session { id, title } => match title.as_deref().filter(|t| !t.is_empty()) {
                Some(t) => format!("nook://session/{}?title={}", percent_encode(id), percent_encode(t)),
                None => format!("nook://session/{}", percent_encode(id)),
            },
            Self::Settings { page } => {
                if page.is_empty() {
                    "nook://settings".to_string()
                } else {
                    format!("nook://settings/{page}")
                }
            }
            Self::New { project } => match project.as_deref().filter(|p| !p.is_empty()) {
                Some(p) => format!("nook://new?project={}", percent_encode(p)),
                None => "nook://new".to_string(),
            },
            Self::Ask { query, project, repo } => {
                let mut url = format!("nook://ask?q={}", percent_encode(query));
                if let Some(p) = project.as_deref().filter(|p| !p.is_empty()) {
                    url.push_str(&format!("&project={}", percent_encode(p)));
                }
                if let Some(r) = repo.as_deref().filter(|r| !r.is_empty()) {
                    url.push_str(&format!("&repo={}", percent_encode(r)));
                }
                url
            }
            Self::Shortcuts => "nook://shortcuts".to_string(),
        }
    }
}

fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hi = (bytes[i + 1] as char).to_digit(16)?;
            let lo = (bytes[i + 2] as char).to_digit(16)?;
            out.push(((hi << 4) | lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Decides where an incoming URL handed to Nook should go (`IncomingLinkRoute.decide` on the Mac).
pub fn decide_incoming_link(
    raw: &str,
    target: IncomingLinkTarget,
    panel_shows_browser: bool,
    session_on_screen: bool,
) -> Option<IncomingLinkDecision> {
    let trimmed = raw.trim();
    let url = Url::parse(trimmed).ok()?;
    let scheme = url.scheme().to_lowercase();
    if scheme == DeepLinkRoute::SCHEME {
        let route = DeepLinkRoute::parse_url(&url)?;
        return Some(IncomingLinkDecision::NookLink { target: route });
    }
    let is_web = scheme == "http" || scheme == "https";
    let is_html_file = scheme == "file"
        && ["html", "htm", "xhtml", "shtml"].iter().any(|ext| url.path().rsplit('.').next().is_some_and(|e| e.eq_ignore_ascii_case(ext)));
    if !is_web && !is_html_file {
        return Some(IncomingLinkDecision::PreviousBrowser { url: trimmed.to_string() });
    }
    if panel_shows_browser {
        return Some(IncomingLinkDecision::SessionPanel { url: trimmed.to_string() });
    }
    match target {
        IncomingLinkTarget::Session if session_on_screen => Some(IncomingLinkDecision::SessionBrowser { url: trimmed.to_string() }),
        IncomingLinkTarget::Session | IncomingLinkTarget::NookBrowser => {
            Some(IncomingLinkDecision::NookBrowser { url: trimmed.to_string() })
        }
    }
}

fn query_param(url: &Url, key: &str) -> Option<String> {
    url.query_pairs().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v.into_owned())
}

fn clean_identifier(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 256 {
        return None;
    }
    // Identifiers may be UUIDs, chat keys (`whatsapp#316...`, `telegram#123`, `slack|name`), etc.,
    // but never paths (`..`, `/`, `\`) or control characters.
    if trimmed.contains("..") || trimmed.contains('/') || trimmed.contains('\\') || trimmed.chars().any(char::is_control) {
        return None;
    }
    Some(trimmed.to_string())
}

fn clean_single_line(raw: &str, max_len: usize) -> String {
    let flat: String = raw.chars().filter(|c| !c.is_control()).collect();
    flat.trim().chars().take(max_len).collect()
}

fn clean_text(raw: &str, max_len: usize) -> String {
    let filtered: String = raw.chars().filter(|&c| c == '\n' || c == '\t' || !c.is_control()).collect();
    filtered.trim().chars().take(max_len).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_chat_and_session_deep_links() {
        assert_eq!(
            DeepLinkRoute::parse("nook://chat/whatsapp%2331612345678%40s.whatsapp.net"),
            Some(DeepLinkRoute::Chat { id: "whatsapp#31612345678@s.whatsapp.net".into() })
        );
        assert_eq!(
            DeepLinkRoute::parse("nook://conversation/550e8400-e29b-41d4-a716-446655440000"),
            Some(DeepLinkRoute::Chat { id: "550e8400-e29b-41d4-a716-446655440000".into() })
        );
        assert_eq!(
            DeepLinkRoute::parse("nook://session/550e8400-e29b-41d4-a716-446655440000?title=Fix%20login"),
            Some(DeepLinkRoute::Session { id: "550e8400-e29b-41d4-a716-446655440000".into(), title: Some("Fix login".into()) })
        );
    }

    #[test]
    fn parses_settings_new_and_ask_deep_links() {
        assert_eq!(DeepLinkRoute::parse("nook://settings/notifications"), Some(DeepLinkRoute::Settings { page: "notifications".into() }));
        assert_eq!(DeepLinkRoute::parse("nook://settings"), Some(DeepLinkRoute::Settings { page: String::new() }));
        assert_eq!(DeepLinkRoute::parse("nook://memory"), Some(DeepLinkRoute::Settings { page: "memory".into() }));
        assert_eq!(DeepLinkRoute::parse("nook://new"), Some(DeepLinkRoute::New { project: None }));
        assert_eq!(
            DeepLinkRoute::parse("nook://ask?q=What%20is%20next%20on%20my%20calendar%3F"),
            Some(DeepLinkRoute::Ask { query: "What is next on my calendar?".into(), project: None, repo: None })
        );
        assert_eq!(
            DeepLinkRoute::parse("nook://prompt?text=Refactor%20auth&repo=nook/app"),
            Some(DeepLinkRoute::Ask { query: "Refactor auth".into(), project: None, repo: Some("nook/app".into()) })
        );
    }

    #[test]
    fn rejects_invalid_or_unsafe_deep_links() {
        assert_eq!(DeepLinkRoute::parse("https://example.com"), None);
        assert_eq!(DeepLinkRoute::parse("nook://unknown/path"), None);
        assert_eq!(DeepLinkRoute::parse("nook://chat/..%2Fetc%2Fpasswd"), None);
        assert_eq!(DeepLinkRoute::parse("nook://settings/bad$page"), None);
        assert_eq!(DeepLinkRoute::parse("nook://ask?q=   "), None);
    }

    #[test]
    fn incoming_link_routing_matches_macos_rules() {
        assert_eq!(
            decide_incoming_link("nook://new", IncomingLinkTarget::Session, true, true),
            Some(IncomingLinkDecision::NookLink { target: DeepLinkRoute::New { project: None } })
        );
        assert_eq!(
            decide_incoming_link("https://nook.ai/docs", IncomingLinkTarget::NookBrowser, true, true),
            Some(IncomingLinkDecision::SessionPanel { url: "https://nook.ai/docs".into() })
        );
        assert_eq!(
            decide_incoming_link("https://nook.ai/docs", IncomingLinkTarget::Session, false, true),
            Some(IncomingLinkDecision::SessionBrowser { url: "https://nook.ai/docs".into() })
        );
        assert_eq!(
            decide_incoming_link("https://nook.ai/docs", IncomingLinkTarget::Session, false, false),
            Some(IncomingLinkDecision::NookBrowser { url: "https://nook.ai/docs".into() })
        );
        assert_eq!(
            decide_incoming_link("mailto:test@example.com", IncomingLinkTarget::Session, false, false),
            Some(IncomingLinkDecision::PreviousBrowser { url: "mailto:test@example.com".into() })
        );
    }
}
