//! Het klembord als bron: wat je net kopieerde. Standaard uit (een klembord kan gevoelig zijn); wachtwoorden die een
//! wachtwoordbeheerder als geheim markeert slaat Nook altijd over.

use nook_core::brain::LoopTool;
use serde_json::json;
use tauri::Manager;

use super::{ToolCtx, ToolSource};
use crate::services::Services;

pub struct Clipboard;

const OFF: &str = "Het klembord staat uit. Zet het aan bij Instellingen › Assistent › Klembord.";

#[async_trait::async_trait]
impl ToolSource for Clipboard {
    fn id(&self) -> &'static str {
        "clipboard"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(services) = ctx.app.try_state::<Services>() else { return vec![] };
        if !services.prefs().clipboard || !crate::platform::capabilities().clipboard {
            return vec![];
        }
        let app = ctx.app.clone();
        vec![LoopTool::read(
            "read_clipboard",
            "Reads the text the user copied to the clipboard. Skips passwords and hidden clipboard content.",
            json!({"type": "object", "properties": {}}),
            move |_| {
                let app = app.clone();
                async move {
                    let services = app.state::<Services>();
                    if !services.prefs().clipboard {
                        return Err(nook_core::NookError(OFF.into()));
                    }
                    let system = services.platform.system.clone();
                    let text = tauri::async_runtime::spawn_blocking(move || system.clipboard_text())
                        .await
                        .map_err(|e| nook_core::NookError(e.to_string()))?
                        .map_err(nook_core::NookError)?;
                    Ok(match text {
                        Some(t) => {
                            let total = t.chars().count();
                            let cut: String = t.chars().take(4000).collect();
                            format!("Inhoud klembord:\n{cut}{}", if total > 4000 { "\n… (ingekort)" } else { "" })
                        }
                        None => "Het klembord is leeg of bevat geen leesbare tekst.".into(),
                    })
                }
            },
        )]
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let services = ctx.app.try_state::<Services>()?;
        if !services.prefs().clipboard {
            return None;
        }
        let system = services.platform.system.clone();
        let text = tauri::async_runtime::spawn_blocking(move || system.clipboard_text()).await.ok()?.ok()??;
        Some(format!("Clipboard (recently copied):\n{}", text.chars().take(1500).collect::<String>()))
    }
}
