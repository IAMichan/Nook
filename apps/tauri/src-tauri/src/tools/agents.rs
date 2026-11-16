//! The user's coding agent sessions as a source for Nook Chat (the Mac's `AppModel+AgentSessionTools`): the other half
//! of the bridge, where agents use Nook's tools. Nook Chat reads a session with the same summary an agent gets
//! (`session_list`, `session_read` in the bridge), and sending a message or starting a session is an action the user
//! approves in the chat's plan first. Every agent Nook runs is reachable the same way: nothing here depends on which
//! agent a session runs. Machines over SSH (the Mac's `list_remote_machines`) are not here: the Tauri app runs agents
//! on this computer only.

use nook_core::brain::sources::{SourceDescriptor, SourceKind};
use nook_core::brain::LoopTool;
use nook_core::i18n::tr;
use serde_json::{json, Value};

use super::{text, ToolCtx, ToolSource};

pub struct AgentSessions;

pub const ID: &str = "agents";

#[async_trait::async_trait]
impl ToolSource for AgentSessions {
    fn id(&self) -> &'static str {
        ID
    }

    fn descriptor(&self) -> Option<SourceDescriptor> {
        Some(SourceDescriptor { id: ID.into(), title: tr("Agentsessies", "Agent sessions").into(), kind: SourceKind::Nook })
    }

    fn aliases(&self) -> &'static [&'static str] {
        &[r"(coding[- ]?)?agents?|agentsessies?|agent sessions?|claude code|codex|gemini( cli)?|cursor|opencode|grok|antigravity"]
    }

    fn intents(&self) -> &'static [&'static str] {
        &[r"\b(sessies?|sessions?|agents?)\b"]
    }

    #[cfg(desktop)]
    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        use tauri::Manager;
        if ctx.app.try_state::<crate::workspace::WorkspaceState>().is_none() {
            return vec![];
        }
        let session_id = json!({"type": "string", "description": "The session id from list_agent_sessions."});
        let (a, b) = (ctx.app.clone(), ctx.app.clone());
        let agents: Vec<&str> = nook_core::workspace::models::RunProvider::ALL.iter().map(|p| p.id()).collect();
        vec![
            LoopTool::read(
                "list_agent_sessions",
                "Lists the user's coding agent sessions in Nook (Claude Code, Codex, Gemini CLI, Cursor and the others), most recent first: id, title, agent, status, folder and branch.",
                json!({"type": "object", "properties": {"limit": {"type": "integer", "description": "How many sessions (default 15, at most 50)."}}, "required": []}),
                move |input| {
                    let app = a.clone();
                    async move {
                        let args = input.as_object().cloned().unwrap_or_default();
                        let result = crate::workspace::bridge::session_list(&app, &args);
                        if result.is_error {
                            return Err(nook_core::NookError(result.text));
                        }
                        Ok(if result.text == "No sessions." { "No agent sessions.".into() } else { result.text })
                    }
                },
            ),
            LoopTool::read(
                "read_agent_session",
                "Reads what happened in one coding agent session: what was asked, what the agent answered, the commands it ran and the files it changed. Use it to follow up on an agent's work.",
                json!({"type": "object", "properties": {"session_id": session_id}, "required": ["session_id"]}),
                move |input| {
                    let app = b.clone();
                    async move {
                        let args = input.as_object().cloned().unwrap_or_default();
                        crate::workspace::bridge::session_read(&app, &args)
                            .map(|r| r.text)
                            .map_err(|_| nook_core::NookError("No such session. Use an id from list_agent_sessions.".into()))
                    }
                },
            ),
            LoopTool::action(
                "message_agent_session",
                "Sends a message to a coding agent session for the user: a follow-up, an answer to its question, or what it should do next. mode queue (default) starts a new turn, or waits in line when the agent is busy; steer takes it into the running turn when the agent can, else it waits in line.",
                json!({"type": "object", "properties": {
                    "session_id": session_id,
                    "message": {"type": "string", "description": "The complete message for the agent."},
                    "mode": {"type": "string", "enum": ["queue", "steer"], "description": "queue (default) or steer."}
                }, "required": ["session_id", "message"]}),
            ),
            LoopTool::action(
                "start_agent_session",
                "Starts a new coding agent session in Nook on a task, in one of the user's project folders, with the user's default account, model and rights for that agent. The session shows up in Nook's Agents tab.",
                json!({"type": "object", "properties": {
                    "task": {"type": "string", "description": "The complete task for the agent; it sees nothing of this chat."},
                    "agent": {"type": "string", "enum": agents, "description": "Which agent. Defaults to the one last used in that folder, else the user's default agent."},
                    "folder": {"type": "string", "description": "The project folder (a path or a folder name the user worked in before). Defaults to the most recent one."},
                    "plan": {"type": "boolean", "description": "Start in Plan mode (read-only). Default false."},
                    "title": {"type": "string", "description": "A name for the session. Default: made from the task."},
                    "worktree": {"type": "boolean", "description": "Work in a new git worktree on a branch of its own. Default false."},
                    "base": {"type": "string", "description": "With worktree: the branch it starts from, such as main. Default: the folder's current branch."}
                }, "required": ["task"]}),
            ),
        ]
    }

    #[cfg(not(desktop))]
    fn tools(&self, _ctx: &ToolCtx) -> Vec<LoopTool> {
        vec![]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        let short = |t: String| t.chars().take(80).collect::<String>();
        match tool {
            "message_agent_session" => {
                Some(format!("{}: {}", tr("Bericht aan agentsessie", "Message agent session"), short(text(input, "message"))))
            }
            "start_agent_session" => {
                let agent = text(input, "agent");
                let who = if agent.is_empty() { "agent".to_string() } else { agent };
                Some(format!("{} ({who}): {}", tr("Start agentsessie", "Start agent session"), short(text(input, "task"))))
            }
            _ => None,
        }
    }

    #[cfg(desktop)]
    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            "message_agent_session" => Some(message(ctx, input)),
            "start_agent_session" => Some(start(ctx, input).await),
            _ => None,
        }
    }
}

#[cfg(desktop)]
fn message(ctx: &ToolCtx, input: &Value) -> Result<String, String> {
    use nook_core::i18n::trf;
    use tauri::Manager;
    let ws = ctx.app.try_state::<crate::workspace::WorkspaceState>().ok_or("Nook is not ready.")?;
    let run = uuid::Uuid::parse_str(&text(input, "session_id")).ok().and_then(|id| ws.manager.run(id)).ok_or_else(|| {
        tr("Die sessie bestaat niet. Gebruik een id uit list_agent_sessions.", "No such session. Use an id from list_agent_sessions.")
            .to_string()
    })?;
    let message = text(input, "message");
    if message.is_empty() {
        return Err(tr("Geef het bericht voor de agent.", "Give the message for the agent.").into());
    }
    let title = run.title.clone();
    match text(input, "mode").as_str() {
        "" | "queue" => {
            let busy = ws.manager.is_running(run.id);
            ws.manager.send(run.id, &message)?;
            Ok(if busy {
                trf(
                    "In de wachtrij voor {title}: na de huidige beurt",
                    "Queued for {title}: it gets it after its current turn",
                    &[("title", &title)],
                )
            } else {
                trf("Verstuurd naar {title}", "Sent to {title}", &[("title", &title)])
            })
        }
        "steer" | "auto" => {
            if ws.manager.steer(run.id, &message) {
                Ok(trf("Meegenomen in de lopende beurt van {title}", "Taken into {title}'s running turn", &[("title", &title)]))
            } else {
                ws.manager.send(run.id, &message)?;
                Ok(trf("Verstuurd naar {title}", "Sent to {title}", &[("title", &title)]))
            }
        }
        other => Err(trf("Onbekende modus \"{mode}\": queue of steer.", "Unknown mode \"{mode}\": queue or steer.", &[("mode", &other)])),
    }
}

/// Starts a session the way the composer would (`bridge_nook::start_config`), only in a folder the user worked in.
#[cfg(desktop)]
async fn start(ctx: &ToolCtx, input: &Value) -> Result<String, String> {
    use nook_core::i18n::trf;
    use nook_core::workspace::models::IsolationMode;
    use tauri::Manager;
    let ws = ctx.app.try_state::<crate::workspace::WorkspaceState>().ok_or("Nook is not ready.")?;
    let settings = crate::agents::lock(&ws.settings).clone();
    let profiles = ctx.app.try_state::<crate::agents::AgentsState>();
    let profile = |p: nook_core::workspace::models::RunProvider| {
        profiles.as_ref().map(|a| crate::agents::lock(&a.profiles).preferred(p.kind()).id).unwrap_or_else(|| p.id().to_string())
    };
    let mut config = nook_core::workspace::bridge_nook::start_config(
        input,
        &settings,
        &|p| std::path::Path::new(p).is_dir(),
        &|p| nook_core::agents::find_executable(p.kind()).is_some(),
        &profile,
    )?;
    let manager = ws.manager.clone();
    let id = tauri::async_runtime::spawn_blocking(move || {
        if config.isolation == IsolationMode::Worktree && config.base_branch.is_empty() {
            config.base_branch = manager.git().and_then(|g| g.current_branch(&config.project_path)).unwrap_or_default();
        }
        let provider = config.provider;
        let folder = config.project_path.clone();
        manager.start(config, true).map(|id| (id, provider, folder))
    })
    .await
    .map_err(|e| e.to_string())??;
    let (id, provider, folder) = id;
    ws.manager.note(id, tr("Gestart vanuit Nook Chat", "Started from Nook Chat"));
    Ok(trf(
        "{agent} gestart in {folder} | sessie-id {id}",
        "Started {agent} in {folder} | session id {id}",
        &[("agent", &provider.display_name()), ("folder", &nook_core::agents::text::project_name(&folder)), ("id", &id)],
    ))
}
