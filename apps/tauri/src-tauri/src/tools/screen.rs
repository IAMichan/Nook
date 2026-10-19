//! Het scherm als bron: de tekst van alle vensters, één app lezen, welke apps er draaien en welke voor staat.

use nook_core::brain::LoopTool;
use nook_core::services::screen as rules;

use serde_json::json;
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::services::Services;

pub struct Screen;

#[async_trait::async_trait]
impl ToolSource for Screen {
    fn id(&self) -> &'static str {
        "screen"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(services) = ctx.app.try_state::<Services>() else { return vec![] };
        if !services.platform.screen.available() {
            return vec![];
        }
        let (a, b, c, d) = (ctx.app.clone(), ctx.app.clone(), ctx.app.clone(), ctx.app.clone());
        vec![
            LoopTool::read(
                "read_screen",
                "Reads visible text across all windows on all displays of the user's computer, frontmost window first (locally, through the accessibility layer or OCR). Determine yourself which window holds the relevant context. Use this IMMEDIATELY, without asking first what is on screen, whenever the user refers to something visible or recently read: 'here', 'this', 'that', 'that email', 'schedule this', 'put that on my calendar'. Extract title, date, time, location, and attendees from the text.",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let app = a.clone();
                    async move {
                        let snap = tauri::async_runtime::spawn_blocking(move || crate::services::screen::snapshot(&app, false))
                            .await
                            .map_err(|e| nook_core::NookError(e.to_string()))?
                            .map_err(nook_core::NookError)?;
                        Ok(format!("Screen ({} — {}):\n{}", snap.app_name, snap.window_title, snap.text))
                    }
                },
            ),
            LoopTool::read(
                "read_app",
                "Reads what is in an open app (locally, through the accessibility layer), even if that app is behind other windows. Use this for questions about an app without its own connector (Slack, Teams, WhatsApp, a document, a browser tab…) or to look inside a specific app. Open apps are listed in the context under \"Open apps\".",
                json!({"type": "object", "properties": {"app": {"type": "string", "description": "Name of the app, for example \"Slack\" or \"Firefox\"."}}, "required": ["app"]}),
                move |input| {
                    let app = b.clone();
                    async move {
                        let name = text(&input, "app");
                        let services = app.state::<Services>();
                        let screen = services.platform.screen.clone();
                        let query = name.clone();
                        let sections = tauri::async_runtime::spawn_blocking(move || screen.read_app(&query, 8000))
                            .await
                            .map_err(|e| nook_core::NookError(e.to_string()))?
                            .map_err(nook_core::NookError)?;
                        let snap = rules::app_snapshot(&name, &sections);
                        Ok(snap.text)
                    }
                },
            ),
            LoopTool::read(
                "list_running_apps",
                "Lists the apps that are open on the user's computer now, including which one is in front. Use for questions like 'which apps are open' or to see what the user is working in.",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let app = c.clone();
                    async move {
                        let apps = tauri::async_runtime::spawn_blocking(move || app.state::<Services>().platform.screen.running_apps())
                            .await
                            .unwrap_or_default();
                        if apps.is_empty() {
                            return Ok("Geen geopende apps gevonden.".to_string());
                        }
                        let lines: Vec<String> =
                            apps.iter().map(|a| format!("- {}{}{}", a.name, if a.frontmost { " (actief venster)" } else { "" }, if a.id != a.name { format!(" [{}]", a.id) } else { String::new() })).collect();
                        Ok(format!("Geopende apps op deze computer:\n{}", lines.join("\n")))
                    }
                },
            ),
            LoopTool::read(
                "get_active_app",
                "Tells which app and window the user has in front of them right now.",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let app = d.clone();
                    async move {
                        let front = tauri::async_runtime::spawn_blocking(move || app.state::<Services>().platform.screen.active_app()).await.ok().flatten();
                        Ok(match front {
                            Some(f) => format!("Voorste app: {} ({}){}", f.name, f.id, if f.title.is_empty() { String::new() } else { format!(", venster: {}", f.title) }),
                            None => "Geen actieve app gevonden.".into(),
                        })
                    }
                },
            ),
        ]
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let services = ctx.app.try_state::<Services>()?;
        if !services.platform.screen.available() {
            return None;
        }
        let app = ctx.app.clone();
        let apps = tauri::async_runtime::spawn_blocking(move || app.state::<Services>().platform.screen.running_apps()).await.ok()?;
        (!apps.is_empty()).then(|| {
            let names: Vec<String> =
                apps.iter().take(15).map(|a| if a.frontmost { format!("{} (front)", a.name) } else { a.name.clone() }).collect();
            format!("Open apps: {}", names.join(", "))
        })
    }
}
