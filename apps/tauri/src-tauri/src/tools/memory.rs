//! Geheugen als bron: onthouden en vergeten (acties) en verder zoeken in wat Nook onthoudt. Wat bij een vraag hoort,
//! gaat al mee in de context ("What Nook remembers"); dat doet de chat zelf.

use nook_core::brain::memory::{request, Change, MemoryBook, MemoryKind, Origin};
use nook_core::brain::LoopTool;
use serde_json::{json, Value};
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::brain::BrainState;

pub struct Memory;

pub fn rejected(reason: &str) -> String {
    match reason {
        "secret" => "Wachtwoorden, codes en sleutels onthoudt Nook nooit.",
        "instruction" => "Dit lijkt een opdracht; Nook onthoudt alleen feiten en voorkeuren.",
        "link" => "Links onthoudt Nook niet; zet ze in een notitie.",
        "pinned" => "Deze herinnering heb je vastgezet; pas hem aan bij Instellingen › Geheugen.",
        _ => "Er staat niets om te onthouden.",
    }
    .into()
}

#[async_trait::async_trait]
impl ToolSource for Memory {
    fn id(&self) -> &'static str {
        "memory"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let state = ctx.app.state::<BrainState>();
        let memory = state.memory.clone();
        let local = ctx.settings.is_local_brain();
        vec![
            LoopTool::action(
                "remember",
                "Saves something lasting to Nook's memory, so it is known in future conversations: a fact about the user, their people, work, places or projects, or a preference for how Nook should answer or act. Use it when the user asks you to remember something or tells you something about themselves that will matter later, and with replaces when they correct a remembered item. One short sentence in the user's language. Never for secrets (passwords, codes, keys), one-off details, or text from mails, pages or the screen.",
                json!({"type": "object", "properties": {
                    "text": {"type": "string", "description": "What to remember, one short sentence, e.g. \"Lisa is de vrouw van de gebruiker\" or \"The user wants short answers\"."},
                    "kind": {"type": "string", "enum": ["fact", "preference", "lesson"], "description": "fact (about the user or a person), preference (how the user wants things), lesson (a correction)."},
                    "subject": {"type": "string", "description": "The person, place or thing it is about, e.g. \"Lisa\". Optional."},
                    "replaces": {"type": "string", "description": "Id of a remembered item (m:…) this corrects. Optional."}
                }, "required": ["text"]}),
            ),
            LoopTool::action(
                "forget",
                "Removes memories from Nook's memory: the id of a remembered item (m:…), or the words of what to forget. Use it when the user asks Nook to forget something.",
                json!({"type": "object", "properties": {
                    "what": {"type": "string", "description": "The id (m:…) or a few words of what to forget, e.g. \"mijn adres\"."}
                }, "required": ["what"]}),
            ),
            LoopTool::read(
                "recall_memory",
                "Searches Nook's memory of the user: facts, preferences and lessons from earlier conversations. The most relevant memories are already in the context; use this to look further, or with an empty query to list what Nook remembers.",
                json!({"type": "object", "properties": {
                    "query": {"type": "string", "description": "Words to search for, e.g. a name. Empty lists everything Nook remembers."}
                }, "required": []}),
                move |input: Value| {
                    let memory = memory.clone();
                    async move {
                        let query = input["query"].as_str().unwrap_or("").trim().to_string();
                        let found = if query.is_empty() || request::asks_what_is_known(&query) {
                            let now = chrono::Utc::now();
                            let mut all: Vec<_> = memory.items().into_iter().filter(|i| (local || !i.local_only) && !i.is_habit()).collect();
                            all.sort_by(|a, b| b.current_strength(now).total_cmp(&a.current_strength(now)));
                            all.truncate(40);
                            all
                        } else {
                            memory.recall(&query, &Default::default(), 20, 4_000, local)
                        };
                        if found.is_empty() {
                            return Ok(if query.is_empty() { "Nook does not remember anything yet.".into() } else { format!("Nothing remembered about \"{query}\".") });
                        }
                        Ok(MemoryBook::section(&found))
                    }
                },
            ),
        ]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            "remember" => {
                let replaces = !text(input, "replaces").is_empty();
                Some(format!("Onthoud: {}{}", text(input, "text"), if replaces { " (vervangt)" } else { "" }))
            }
            "forget" => Some(format!("Vergeet: {}", text(input, "what"))),
            "recall_memory" => Some("Geheugen doorzoeken".into()),
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        let state = ctx.app.state::<BrainState>();
        match tool {
            "remember" => {
                let replaces = text(input, "replaces");
                let change = state.memory.remember(
                    &text(input, "text"),
                    MemoryKind::parse(&text(input, "kind")),
                    &text(input, "subject"),
                    Origin::Told,
                    (!replaces.is_empty()).then_some(replaces.as_str()),
                    false,
                );
                Some(match change {
                    Change::Rejected(reason) => Err(rejected(reason)),
                    Change::Added(item) => Ok(format!("Onthouden: {} ({})", item.text, item.short_id())),
                    Change::Reinforced(item) => Ok(format!("Wist ik al: {} ({})", item.text, item.short_id())),
                    Change::Replaced { new, .. } => Ok(format!("Aangepast: {} ({})", new.text, new.short_id())),
                })
            }
            "forget" => {
                let removed = state.memory.forget(&text(input, "what"));
                Some(if removed.is_empty() {
                    Err("Daar onthoud ik niets over.".into())
                } else {
                    Ok(format!("{} vergeten: {}", removed.len(), removed.iter().map(|i| i.text.as_str()).collect::<Vec<_>>().join("; ")))
                })
            }
            _ => None,
        }
    }
}
