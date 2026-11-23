//! The bridge's card tools (`WorkspaceBridge+Suggest` and `WorkspaceBridge+Page` on the Mac): `session_suggest` puts a
//! suggested new session in the caller's own timeline, `render_page` a sandboxed page. Neither needs approval: nothing
//! happens until the user acts on the card, and the page cannot reach the network or send anything back. The rules are
//! in `core/src/workspace/session_cards.rs`.

use nook_core::workspace::bridge::{BridgeCaller, BridgeTool, ToolResult, Verdict};
use nook_core::workspace::models::RunProvider;
use nook_core::workspace::session_cards::{self as cards, SessionSuggestion};
use serde_json::{Map, Value};
use tauri::AppHandle;
use uuid::Uuid;

use super::{audit, check, refusal, workspace};

fn own_run(caller: &BridgeCaller) -> Option<Uuid> {
    caller.run.as_ref().and_then(|r| Uuid::parse_str(r).ok())
}

pub(super) fn session_suggest(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let Some(run) = own_run(caller).filter(|id| ws.manager.run(*id).is_some()) else {
        return Err("session_suggest shows a card in a session Nook runs; this session runs outside Nook. Use session_start, which asks the user first.".into());
    };
    if let Verdict::Refuse(reason) = check(app, BridgeTool::SessionSuggest, caller, None) {
        return Err(refusal(reason).into());
    }
    let suggestion = SessionSuggestion::parse(a)?;
    if !suggestion.agent.is_empty() && provider_named(&suggestion.agent).is_none() {
        return Err(format!("Unknown agent \"{}\". Call orchestrator_capabilities for the list, or leave agent out.", suggestion.agent));
    }
    ws.manager.append_event(run, suggestion.event());
    audit(app, BridgeTool::SessionSuggest, caller, &suggestion.title, "shown");
    Ok(ToolResult::text(cards::SUGGESTION_ANSWER.to_string()))
}

pub(super) fn provider_named(name: &str) -> Option<RunProvider> {
    let name = name.trim().to_lowercase();
    RunProvider::ALL.into_iter().find(|p| p.id() == name || p.display_name().to_lowercase() == name)
}

pub(super) fn render_page(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller) -> Result<ToolResult, String> {
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let Some(run) = own_run(caller).and_then(|id| ws.manager.run(id)) else {
        return Err("render_page shows the page in a session Nook runs; this session runs outside Nook.".into());
    };
    if let Verdict::Refuse(reason) = check(app, BridgeTool::RenderPage, caller, None) {
        return Err(refusal(reason).into());
    }
    let request = cards::parse_page(a)?;
    let (html, title) = match &request.path {
        Some(path) => {
            let file = cards::page_file(&run.working_directory, path)?;
            let html = std::fs::read_to_string(&file).map_err(|_| format!("{path} cannot be read as text."))?;
            if html.len() > cards::MAX_HTML_BYTES {
                return Err(format!("The page is too large (at most {} KB).", cards::MAX_HTML_BYTES / 1024));
            }
            let name = file.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "Page".into());
            (html, request.title.clone().unwrap_or(name))
        }
        None => (request.html.clone(), request.title.clone().unwrap_or_else(|| "Page".into())),
    };
    let base = nook_core::paths::dot_nook();
    let page = Uuid::new_v4();
    let file = cards::page_store(&base, run.id, page);
    // Only the newest pages of a session are kept.
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("Nook could not keep the page: {e}"))?;
        let mut old: Vec<_> = std::fs::read_dir(dir).map(|d| d.flatten().collect()).unwrap_or_default();
        if old.len() >= cards::MAX_PAGES_PER_RUN {
            old.sort_by_key(|e| e.metadata().and_then(|m| m.modified()).ok());
            for e in old.iter().take(old.len() + 1 - cards::MAX_PAGES_PER_RUN) {
                std::fs::remove_file(e.path()).ok();
            }
        }
    }
    std::fs::write(&file, html).map_err(|e| format!("Nook could not keep the page: {e}"))?;
    ws.manager.append_event(run.id, cards::page_event(page, &title, &file.to_string_lossy(), request.height));
    audit(app, BridgeTool::RenderPage, caller, &title, "shown");
    Ok(ToolResult::text(format!("Shown in your timeline as \"{title}\" ({} pt high). The user sees it; it cannot send anything back.", request.height as i64)))
}

/// The page an event shows, behind its content policy; only from Nook's own page folder.
pub fn page_html(run: Uuid, event_file: &str) -> Result<String, String> {
    let root = nook_core::paths::dot_nook().join("pages").join(run.to_string());
    let path = std::path::Path::new(event_file);
    let real = path.canonicalize().map_err(|_| "The page is gone.".to_string())?;
    let root = root.canonicalize().map_err(|_| "The page is gone.".to_string())?;
    if !real.starts_with(&root) {
        return Err("Not a page of this session.".into());
    }
    let html = std::fs::read_to_string(&real).map_err(|_| "The page is gone.".to_string())?;
    Ok(cards::sandboxed(&html))
}
