//! De gesprekken die de Notetaker noteerde, als bron voor de chat: "wat spraken we af met Lisa?", "welke to-do's
//! kwamen uit de call van vanochtend?". Alleen lezen, alleen op deze computer.

use nook_core::brain::LoopTool;
use nook_core::services::notes;
use serde_json::json;
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::services::Services;

pub struct Calls;

#[async_trait::async_trait]
impl ToolSource for Calls {
    fn id(&self) -> &'static str {
        "callnotes"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(services) = ctx.app.try_state::<Services>() else { return vec![] };
        if !services.prefs().call_notes || services.notes.lock().unwrap_or_else(|e| e.into_inner()).notes.is_empty() {
            return vec![];
        }
        let (a, b) = (ctx.app.clone(), ctx.app.clone());
        vec![
            LoopTool::read(
                "search_call_notes",
                "Searches the calls and meetings Nook recorded and noted (title, summary, key points, to-dos and the full transcript). Without query: the most recent ones. Returns note ids; read one in full with read_call_note.",
                json!({"type": "object", "properties": {"query": {"type": "string", "description": "Keywords or a name. Optional."}}}),
                move |input| {
                    let app = a.clone();
                    async move {
                        let query = text(&input, "query");
                        let ready = app.state::<Services>().notes.lock().unwrap_or_else(|e| e.into_inner()).ready();
                        let found = notes::search(&ready, &query);
                        if found.is_empty() {
                            return Ok(format!("No noted calls found for \"{query}\"."));
                        }
                        Ok(found.iter().take(8).map(|n| notes::overview(n)).collect::<Vec<_>>().join("\n"))
                    }
                },
            ),
            LoopTool::read(
                "read_call_note",
                "Reads one noted call in full: summary, key points, to-dos and the transcript with who said what. Give the id from search_call_notes.",
                json!({"type": "object", "properties": {"id": {"type": "string", "description": "The note id."}}, "required": ["id"]}),
                move |input| {
                    let app = b.clone();
                    async move {
                        let id = text(&input, "id");
                        let store = app.state::<Services>().notes.lock().unwrap_or_else(|e| e.into_inner()).clone();
                        let note = store.get(&id).ok_or_else(|| nook_core::NookError("This note is not found. Search with search_call_notes first.".into()))?;
                        Ok(notes::markdown(note).chars().take(60_000).collect())
                    }
                },
            ),
        ]
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let services = ctx.app.try_state::<Services>()?;
        if !services.prefs().call_notes {
            return None;
        }
        let now = chrono::Utc::now();
        let recent: Vec<String> = services
            .notes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .ready()
            .iter()
            .filter(|n| (now - n.start).num_hours() < 72)
            .take(3)
            .map(notes::overview)
            .collect();
        (!recent.is_empty()).then(|| format!("Recent calls noted by Nook (read with read_call_note):\n{}", recent.join("\n")))
    }
}
