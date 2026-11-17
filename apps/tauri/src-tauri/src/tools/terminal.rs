//! Nook's terminal as a tool for Nook Chat (`TerminalStore.tools` on the Mac): `run_command` proposes a shell command,
//! the user approves the full command in the plan, and it opens in a visible terminal beside the chat.

use nook_core::brain::LoopTool;
use serde_json::{json, Value};

use super::{text, ToolCtx, ToolSource};

pub struct Terminal;

#[async_trait::async_trait]
impl ToolSource for Terminal {
    fn id(&self) -> &'static str {
        "terminal"
    }

    #[cfg(desktop)]
    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        use tauri::Manager;
        if ctx.app.try_state::<crate::workspace::WorkspaceState>().is_none() || !crate::platform::capabilities().terminals {
            return vec![];
        }
        vec![LoopTool::action(
            "run_command",
            "Runs a shell command in a visible terminal of Nook, next to the chat, in an optional folder. Use it only when the user asks for something that needs a command line; the user approves the exact command first and sees its output in the terminal.",
            json!({
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The complete shell command."},
                    "folder": {"type": "string", "description": "Folder to run it in. Defaults to the home folder."}
                },
                "required": ["command"]
            }),
        )]
    }

    #[cfg(not(desktop))]
    fn tools(&self, _ctx: &ToolCtx) -> Vec<LoopTool> {
        vec![]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            // The whole command, never shortened: what is approved must be what is shown.
            "run_command" => Some(format!("Terminal: {}", text(input, "command"))),
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        if tool != "run_command" {
            return None;
        }
        #[cfg(desktop)]
        {
            Some(execute_run_command(ctx, input))
        }
        #[cfg(not(desktop))]
        {
            let _ = (ctx, input);
            Some(Err(nook_core::i18n::tr(
                "Terminals draaien op je computer, niet op je telefoon.",
                "Terminals run on your computer, not on your phone.",
            )
            .into()))
        }
    }
}

#[cfg(desktop)]
fn execute_run_command(ctx: &ToolCtx, input: &Value) -> Result<String, String> {
    use nook_core::i18n::{tr, trf};
    use nook_core::workspace::terminal::command_request;
    use tauri::Manager;

    let home = nook_core::agents::home_dir().to_string_lossy().into_owned();
    let req = command_request(&text(input, "command"), &text(input, "folder"), &home)?;
    if !std::path::Path::new(&req.folder).is_dir() {
        return Err(trf("De map bestaat niet: {folder}", "The folder does not exist: {folder}", &[("folder", &req.folder)]));
    }
    let Some(ws) = ctx.app.try_state::<crate::workspace::WorkspaceState>() else {
        return Err(
            tr("Terminals draaien op je computer, niet op je telefoon.", "Terminals run on your computer, not on your phone.").into()
        );
    };
    let info = ws.terminals.open(&ctx.app, &req.folder, Some(&req.command), Some(&req.title), None)?;
    crate::platform::desktop::open_terminal_beside_chat(&ctx.app, &req.folder, &info.id, ctx.nook.as_deref());
    Ok(trf(
        "Gestart in de terminal van Nook: {command}. De uitvoer staat daar.",
        "Started in Nook's terminal: {command}. The output is there.",
        &[("command", &req.command)],
    ))
}
