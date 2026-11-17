//! Nook's own browser (`read_nook_browser`, `open_in_nook_browser`, matching `BrowserView.tools` on the Mac). Reading
//! the currently open page runs directly in the loop without launching the browser if nothing is open; opening a new
//! `https://` address waits for user approval in the chat's plan.

use nook_core::brain::LoopTool;
use nook_core::i18n::{tr, trf};
use nook_core::NookError;
use serde_json::{json, Value};
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};

pub struct NookBrowser;

#[async_trait::async_trait]
impl ToolSource for NookBrowser {
    fn id(&self) -> &'static str {
        "browser"
    }

    #[cfg(desktop)]
    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        use nook_core::workspace::browser::format_page;
        if ctx.app.try_state::<crate::workspace::WorkspaceState>().is_none() || !crate::platform::capabilities().terminals {
            return vec![];
        }
        let app = ctx.app.clone();
        vec![
            LoopTool::read(
                "read_nook_browser",
                "Reads the text of the page open in Nook's own browser (Agents › Browser), with its title and address.",
                json!({"type": "object", "properties": {}, "required": []}),
                move |_| {
                    let app = app.clone();
                    async move {
                        let ws = app.try_state::<crate::workspace::WorkspaceState>().ok_or_else(|| NookError::new("Nook is not ready."))?;
                        // Never opened: nothing to read, and no reason to start the browser for that.
                        let state = ws.browser.state();
                        if !state.open || state.url.is_empty() {
                            return Err(NookError(
                                tr("Er staat geen pagina open in de browser van Nook.", "No page is open in Nook's browser.").into(),
                            ));
                        }
                        let page = ws.browser.page_text(&app).await.map_err(NookError)?;
                        if let Some(brain) = app.try_state::<crate::brain::BrainState>() {
                            brain.urls.remember(&page.url);
                        }
                        Ok(format_page(&page.title, &page.url, &page.text))
                    }
                },
            ),
            LoopTool::action(
                "open_in_nook_browser",
                "Opens a web address in Nook's own browser so the user can look at it together with Nook. Only https addresses.",
                json!({"type": "object", "properties": {"url": {"type": "string", "description": "The full https address."}}, "required": ["url"]}),
            ),
        ]
    }

    #[cfg(not(desktop))]
    fn tools(&self, _ctx: &ToolCtx) -> Vec<LoopTool> {
        vec![]
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            "open_in_nook_browser" => Some(format!("Browser: open {}", text(input, "url"))),
            _ => None,
        }
    }

    #[cfg(desktop)]
    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        if tool != "open_in_nook_browser" {
            return None;
        }
        let url = match nook_core::workspace::browser::https_url(&text(input, "url")) {
            Ok(url) => url,
            Err(err) => return Some(Err(err)),
        };
        let Some(ws) = ctx.app.try_state::<crate::workspace::WorkspaceState>() else {
            return Some(Err("Nook is not ready.".into()));
        };
        Some(
            ws.browser
                .go(&ctx.app, &url, None)
                .map(|()| trf("Geopend in de browser van Nook: {url}", "Opened {url} in Nook's browser", &[("url", &url)])),
        )
    }

    #[cfg(not(desktop))]
    async fn execute(&self, _ctx: &ToolCtx, tool: &str, _input: &Value) -> Option<Result<String, String>> {
        if tool != "open_in_nook_browser" {
            return None;
        }
        Some(Err(
            tr("De browser draait op je computer, niet op je telefoon.", "The browser runs on your computer, not on your phone.").into()
        ))
    }
}
