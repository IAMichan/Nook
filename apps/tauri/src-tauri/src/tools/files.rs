//! Bestanden als bron: zoeken (Windows Search, `locate`, of een begrensde zoektocht in je thuismap) en lezen (tekst,
//! Word, OpenDocument, PDF). Nooit buiten je thuismap, in verborgen mappen, sleutels of wachtwoordexports.

use std::path::PathBuf;

use nook_core::brain::LoopTool;
use nook_core::services::files;
use serde_json::json;
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::services::Services;

pub struct Files;

fn err(e: impl ToString) -> nook_core::NookError {
    nook_core::NookError(e.to_string())
}

#[async_trait::async_trait]
impl ToolSource for Files {
    fn id(&self) -> &'static str {
        "files"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(services) = ctx.app.try_state::<Services>() else { return vec![] };
        if !services.prefs().files || !crate::platform::capabilities().files {
            return vec![];
        }
        let (search_app, read_app) = (ctx.app.clone(), ctx.app.clone());
        vec![
            LoopTool::read(
                "search_files",
                "Searches the user's files (name and content, in their home folder) and returns paths of the best matches.",
                json!({"type": "object", "properties": {"query": {"type": "string", "description": "Search terms."}}, "required": ["query"]}),
                move |input| {
                    let app = search_app.clone();
                    async move {
                        let query = text(&input, "query");
                        if query.is_empty() {
                            return Err(err("De zoekopdracht ontbreekt."));
                        }
                        let q = query.clone();
                        let hits = tauri::async_runtime::spawn_blocking(move || search(&app, &q)).await.map_err(err)?;
                        if hits.is_empty() {
                            return Ok(format!("Nothing found for \"{query}\"."));
                        }
                        let home = dirs::home_dir().unwrap_or_default();
                        Ok(hits.iter().map(|p| files::tilde(p, &home)).collect::<Vec<_>>().join("\n"))
                    }
                },
            ),
            LoopTool::read(
                "read_file",
                "Reads the text of a user document (plain text, PDF, Word, OpenDocument). Provide a path from search_files or from the recent files list.",
                json!({"type": "object", "properties": {"path": {"type": "string", "description": "Path, may start with ~."}}, "required": ["path"]}),
                move |input| {
                    let app = read_app.clone();
                    async move {
                        let raw = text(&input, "path");
                        tauri::async_runtime::spawn_blocking(move || read(&app, &raw)).await.map_err(err)?.map_err(err)
                    }
                },
            ),
        ]
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let services = ctx.app.try_state::<Services>()?;
        if !services.prefs().files {
            return None;
        }
        let system = services.platform.system.clone();
        let recent = tauri::async_runtime::spawn_blocking(move || system.recent_files(10)).await.ok()?;
        let home = dirs::home_dir()?;
        (!recent.is_empty()).then(|| {
            let mut lines = vec!["Recently used files:".to_string()];
            lines.extend(recent.iter().map(|p| format!("- {}", files::tilde(p, &home))));
            lines.join("\n")
        })
    }
}

/// Eerst de index van het systeem, anders (of als die niets vindt) zelf zoeken met grenzen.
fn search(app: &tauri::AppHandle, query: &str) -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let services = app.state::<Services>();
    let mut hits = services.platform.system.search_index(query, 30).unwrap_or_default();
    if hits.is_empty() {
        hits = files::walk_search(&home, query, files::WalkLimits::default());
    }
    hits.retain(|p| files::is_allowed(p, &home));
    hits.dedup();
    let ranked = files::rank_files(&hits.iter().map(|p| p.to_string_lossy().to_string()).collect::<Vec<_>>(), files::is_code_query(query));
    ranked.into_iter().take(20).map(PathBuf::from).collect()
}

fn read(app: &tauri::AppHandle, raw: &str) -> Result<String, String> {
    let home = dirs::home_dir().ok_or("Geen thuismap.")?;
    let path = files::expand(raw, &home);
    if !files::is_allowed(&path, &home) {
        return Err("Nook mag dat bestand niet lezen.".into());
    }
    let is_pdf = path.extension().is_some_and(|e| e.eq_ignore_ascii_case("pdf"));
    let text = if is_pdf {
        app.state::<Services>().platform.system.pdf_text(&path)?
    } else {
        files::read_text(&path, 5_000_000).map_err(|e| e.0)?
    };
    let total = text.chars().count();
    let mut out: String = text.chars().take(15_000).collect();
    if total > 15_000 {
        out.push_str(&format!("\n… (truncated: the first 15,000 characters of {total})"));
    }
    Ok(format!("{}\n\n{}", files::tilde(&path, &home), out))
}
