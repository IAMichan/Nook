//! The cards an agent put in its timeline (`session_suggest`, `render_page`): what you chose on a suggestion, and the
//! page a page card shows.

use nook_core::workspace::models::EventState;
use nook_core::workspace::session_cards::{self as cards, SuggestionChoice};
use tauri::State;
use uuid::Uuid;

use crate::workspace::WorkspaceState;

type Res<T> = Result<T, String>;

fn id(raw: &str) -> Res<Uuid> {
    Uuid::parse_str(raw).map_err(|_| "Unknown session.".to_string())
}

/// Keeps what you chose on a suggested session (`SessionSuggestion.state(after:)`): Start with the new session's id,
/// Do it here, or ×. Options changes nothing until a session starts from the composer.
#[tauri::command]
pub fn workspace_suggestion_chosen(
    state: State<'_, WorkspaceState>,
    run: String,
    event: String,
    choice: SuggestionChoice,
    session: Option<String>,
) -> Res<()> {
    let (run, event) = (id(&run)?, id(&event)?);
    let Some(next) = cards::state_after(choice) else { return Ok(()) };
    let changed = state.manager.change_event(run, event, |e| {
        e.state = Some(next);
        if next == EventState::Done {
            e.output = session.clone();
        }
    });
    if changed {
        Ok(())
    } else {
        Err("That card is gone.".into())
    }
}

/// The page a `render_page` card shows, behind its content policy.
#[tauri::command]
pub fn workspace_page_html(state: State<'_, WorkspaceState>, run: String, event: String) -> Res<String> {
    let (run, event) = (id(&run)?, id(&event)?);
    let e = state.manager.event(run, event).ok_or("The page is gone.")?;
    if e.tool.as_deref() != Some(cards::PAGE_TOOL) {
        return Err("Not a page.".into());
    }
    page_html(run, e.detail.as_deref().unwrap_or(""))
}

/// The page an event shows, behind its content policy; only from Nook's own page folder.
fn page_html(run: Uuid, event_file: &str) -> Result<String, String> {
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
