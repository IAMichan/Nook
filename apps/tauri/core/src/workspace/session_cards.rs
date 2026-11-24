//! Cards an agent puts in its own timeline through the bridge, without approval because nothing happens until the user
//! acts on them: a suggested new session (`session_suggest`, the Mac's `SessionSuggestion`) and a page it shows
//! (`render_page`, the Mac's `RenderedPage`). The rules are here, so they are tested anywhere; the bridge in
//! `src-tauri/src/workspace/bridge/cards.rs` keeps them, the timeline draws them.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

use super::models::{EventKind, EventState, RunEvent};

fn text(a: &Map<String, Value>, key: &str) -> Option<String> {
    a.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

fn one_line(text: &str) -> String {
    text.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
}

// MARK: Suggested sessions

/// A new session an agent suggests, as Claude's "New session" card: a side task it noticed, shown in its own timeline
/// with a title, where it would run and a short summary. Nothing starts until you choose: Start (a new session beside
/// this one), Do it here (the prompt goes to this session as your next message), Options (the new-session composer,
/// filled in) or ×. Kept as a System event with `tool` `SUGGESTION_TOOL`: `text` the title, `detail` this as JSON,
/// `state` pending until you choose, `output` the new session's id once started.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSuggestion {
    pub title: String,
    /// What the new session is asked: everything it needs, since it does not see this conversation.
    pub prompt: String,
    /// One or two sentences for the card.
    pub summary: String,
    /// An agent other than the caller's (its name), or empty for the same agent.
    #[serde(default)]
    pub agent: String,
    /// True for a worktree of its own, false for the caller's folder as it is, None for the folder's default.
    #[serde(default)]
    pub worktree: Option<bool>,
}

pub const SUGGESTION_TOOL: &str = "session_suggestion";
pub const MAX_TITLE: usize = 120;
pub const MAX_SUMMARY: usize = 400;
pub const MAX_PROMPT_BYTES: usize = 64 * 1024;

/// The answer `session_suggest` gives the agent.
pub const SUGGESTION_ANSWER: &str = "Shown to the user as a suggested new session in your timeline. They decide: start it beside you, have you do it here (it then arrives as their next message), open it in the new-session composer, or dismiss it. Do not wait for it and do not do the task yourself unless it comes back to you; carry on or end your turn.";

/// What you chose on the card.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SuggestionChoice {
    Start,
    Here,
    Options,
    Dismiss,
}

impl SessionSuggestion {
    pub fn parse(a: &Map<String, Value>) -> Result<SessionSuggestion, String> {
        let prompt = a.get("prompt").and_then(Value::as_str).map(str::trim).unwrap_or("").to_string();
        if prompt.is_empty() {
            return Err("Give prompt: the full task for the new session, which does not see this conversation.".into());
        }
        if prompt.len() > MAX_PROMPT_BYTES {
            return Err(format!("The prompt is too long (at most {} KB).", MAX_PROMPT_BYTES / 1024));
        }
        let title = text(a, "title").map(|t| one_line(&t)).unwrap_or_default();
        let shown = if title.is_empty() { one_line(&prompt).chars().take(60).collect() } else { title };
        Ok(SessionSuggestion {
            title: shown.chars().take(MAX_TITLE).collect(),
            prompt,
            summary: text(a, "summary").map(|s| one_line(&s)).unwrap_or_default().chars().take(MAX_SUMMARY).collect(),
            agent: text(a, "agent").unwrap_or_default(),
            worktree: a.get("worktree").and_then(Value::as_bool),
        })
    }

    pub fn event(&self) -> RunEvent {
        RunEvent::new(EventKind::System, self.title.clone())
            .with_tool(SUGGESTION_TOOL)
            .with_detail(serde_json::to_string(self).unwrap_or_default())
            .with_state(EventState::Pending)
    }

    /// The suggestion an event carries; None for any other event.
    pub fn from_event(event: &RunEvent) -> Option<SessionSuggestion> {
        if event.kind != EventKind::System || event.tool.as_deref() != Some(SUGGESTION_TOOL) {
            return None;
        }
        serde_json::from_str(event.detail.as_deref()?).ok()
    }
}

/// Where the card's state goes after a choice: done once started, allowed when done here, denied when dismissed;
/// Options keeps it pending (the composer may still be closed without starting).
pub fn state_after(choice: SuggestionChoice) -> Option<EventState> {
    match choice {
        SuggestionChoice::Start => Some(EventState::Done),
        SuggestionChoice::Here => Some(EventState::Allowed),
        SuggestionChoice::Dismiss => Some(EventState::Denied),
        SuggestionChoice::Options => None,
    }
}

// MARK: Rendered pages

pub const PAGE_TOOL: &str = "render_page";
pub const MAX_HTML_BYTES: usize = 512 * 1024;
pub const DEFAULT_HEIGHT: f64 = 360.0;
pub const MIN_HEIGHT: f64 = 80.0;
pub const MAX_HEIGHT: f64 = 1200.0;
/// How many pages one session keeps: enough for a few rounds of a chart, never an endless stream of files.
pub const MAX_PAGES_PER_RUN: usize = 24;

#[derive(Debug, Clone, PartialEq)]
pub struct PageRequest {
    pub html: String,
    /// None when the agent gave no title: a page from a file is then named after it.
    pub title: Option<String>,
    pub height: f64,
    /// An HTML file in the session's working directory to show instead of `html`.
    pub path: Option<String>,
}

pub fn clamp_height(height: Option<f64>) -> f64 {
    match height {
        Some(h) if h.is_finite() => h.clamp(MIN_HEIGHT, MAX_HEIGHT).round(),
        _ => DEFAULT_HEIGHT,
    }
}

pub fn parse_page(a: &Map<String, Value>) -> Result<PageRequest, String> {
    let title = text(a, "title").map(|t| one_line(&t).chars().take(MAX_TITLE).collect());
    let height = clamp_height(a.get("height").and_then(Value::as_f64));
    let html = a.get("html").and_then(Value::as_str).filter(|h| !h.trim().is_empty()).map(str::to_string);
    let path = text(a, "path");
    match (html, path) {
        (Some(_), Some(_)) => Err("Give either html or path, not both.".into()),
        (None, Some(path)) => Ok(PageRequest { html: String::new(), title, height, path: Some(path) }),
        (None, None) => {
            Err("Give the page as html (a complete HTML document or fragment) or as path (an HTML file in your working directory).".into())
        }
        (Some(html), None) => {
            if html.len() > MAX_HTML_BYTES {
                return Err(format!(
                    "The page is too large (at most {} KB). Inline less data, or draw it with fewer elements.",
                    MAX_HTML_BYTES / 1024
                ));
            }
            Ok(PageRequest { html, title, height, path: None })
        }
    }
}

/// The page file an agent names: an .html file inside its working directory, never a path outside it.
pub fn page_file(working_directory: &str, path: &str) -> Result<PathBuf, String> {
    let base = Path::new(working_directory);
    let joined = if Path::new(path).is_absolute() { PathBuf::from(path) } else { base.join(path) };
    let lower = joined.to_string_lossy().to_lowercase();
    if !(lower.ends_with(".html") || lower.ends_with(".htm")) {
        return Err("path must be an .html file.".into());
    }
    let real = joined.canonicalize().map_err(|_| format!("There is no file at {path}."))?;
    let root = base.canonicalize().map_err(|_| "Your working directory cannot be read.".to_string())?;
    if !real.starts_with(&root) {
        return Err("path must be inside your working directory.".into());
    }
    Ok(real)
}

/// Where a session's pages are kept: one folder per session, one file per page.
pub fn page_store(base: &Path, run: Uuid, page: Uuid) -> PathBuf {
    base.join("pages").join(run.to_string()).join(format!("{page}.html"))
}

/// The timeline's record of a page: its title, the file it is kept in and its height.
pub fn page_event(id: Uuid, title: &str, file: &str, height: f64) -> RunEvent {
    let mut event = RunEvent::new(EventKind::System, title).with_tool(PAGE_TOOL).with_detail(file);
    event.id = id;
    event.output = Some(format!("{}", clamp_height(Some(height)) as i64));
    event.state = None;
    event
}

/// The page shown in the timeline's frame: the agent's HTML behind a content policy that allows its own inline styles,
/// scripts and data, and nothing that reaches the network, submits a form or leaves the page.
pub fn sandboxed(html: &str) -> String {
    const POLICY: &str = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: blob:; media-src data: blob:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'; base-uri 'none'\">";
    let lower = html.to_lowercase();
    if let Some(head) = lower.find("<head") {
        if let Some(close) = lower[head..].find('>') {
            let at = head + close + 1;
            return format!("{}{POLICY}{}", &html[..at], &html[at..]);
        }
    }
    format!("<!doctype html><html><head>{POLICY}<meta charset=\"utf-8\"></head><body>{html}</body></html>")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn args(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn a_suggestion_needs_a_prompt_and_titles_itself() {
        assert!(SessionSuggestion::parse(&args(json!({"title": "x"}))).unwrap_err().contains("Give prompt"));
        let s = SessionSuggestion::parse(&args(
            json!({"prompt": "Fix the flaky\nlogin test in auth.spec.ts", "summary": "It fails\n one in five runs.", "worktree": true}),
        ))
        .unwrap();
        assert_eq!(s.title, "Fix the flaky login test in auth.spec.ts");
        assert_eq!(s.summary, "It fails one in five runs.");
        assert_eq!(s.worktree, Some(true));
        let long = "x".repeat(MAX_PROMPT_BYTES + 1);
        assert!(SessionSuggestion::parse(&args(json!({"prompt": long}))).unwrap_err().contains("too long"));
    }

    #[test]
    fn a_suggestion_lives_in_its_event() {
        let s = SessionSuggestion::parse(&args(json!({"prompt": "p", "title": "T", "agent": "codex"}))).unwrap();
        let e = s.event();
        assert_eq!(e.state, Some(EventState::Pending));
        assert_eq!(SessionSuggestion::from_event(&e), Some(s));
        assert_eq!(SessionSuggestion::from_event(&RunEvent::new(EventKind::System, "x")), None);
        assert_eq!(state_after(SuggestionChoice::Start), Some(EventState::Done));
        assert_eq!(state_after(SuggestionChoice::Here), Some(EventState::Allowed));
        assert_eq!(state_after(SuggestionChoice::Dismiss), Some(EventState::Denied));
        assert_eq!(state_after(SuggestionChoice::Options), None);
    }

    #[test]
    fn a_page_is_html_or_a_file_never_both() {
        assert!(parse_page(&args(json!({"html": "<p>a</p>", "path": "a.html"}))).unwrap_err().contains("not both"));
        assert!(parse_page(&args(json!({}))).is_err());
        let p = parse_page(&args(json!({"html": "<p>a</p>", "height": 5000, "title": "Chart\nQ1"}))).unwrap();
        assert_eq!(p.height, MAX_HEIGHT);
        assert_eq!(p.title.as_deref(), Some("Chart Q1"));
        assert_eq!(parse_page(&args(json!({"path": "a.html"}))).unwrap().height, DEFAULT_HEIGHT);
        assert_eq!(clamp_height(Some(10.0)), MIN_HEIGHT);
        let big = "a".repeat(MAX_HTML_BYTES + 1);
        assert!(parse_page(&args(json!({"html": big}))).unwrap_err().contains("too large"));
    }

    #[test]
    fn a_page_file_stays_in_the_working_directory() {
        let dir = std::env::temp_dir().join(format!("nook-pages-{}", Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("out")).unwrap();
        std::fs::write(dir.join("out/chart.html"), "<p>x</p>").unwrap();
        std::fs::write(dir.join("notes.txt"), "x").unwrap();
        let base = dir.to_string_lossy().to_string();
        assert!(page_file(&base, "out/chart.html").is_ok());
        assert!(page_file(&base, "notes.txt").unwrap_err().contains(".html"));
        assert!(page_file(&base, "missing.html").unwrap_err().contains("no file"));
        assert!(page_file(&base, "../outside.html").is_err());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_page_gets_a_policy_without_network() {
        let doc = sandboxed("<html><head><title>x</title></head><body>a</body></html>");
        assert!(doc.contains("<head><meta http-equiv=\"Content-Security-Policy\""));
        assert!(doc.contains("connect-src 'none'"));
        let frag = sandboxed("<svg></svg>");
        assert!(frag.starts_with("<!doctype html>") && frag.contains("<body><svg></svg></body>"));
        let e = page_event(Uuid::new_v4(), "Chart", "/p.html", 9999.0);
        assert_eq!(e.output.as_deref(), Some("1200"));
        assert_eq!(e.tool.as_deref(), Some(PAGE_TOOL));
    }
}
