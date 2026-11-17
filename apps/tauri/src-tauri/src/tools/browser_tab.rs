//! De geopende browser van de gebruiker als bron (`read_browser_tab`): leest de actieve of genoemde tab via
//! UI Automation (Windows) of AT-SPI (Linux); zodra CH-60 landt kan de browserextensie hier voorrang krijgen.

use nook_core::brain::open_browser_tab::{self, BrowserTabResult};
use nook_core::brain::LoopTool;
use nook_core::i18n::tr;
use serde_json::json;
use tauri::Manager;

use super::{text, ToolCtx, ToolSource};
use crate::services::Services;

pub struct Browser;

#[async_trait::async_trait]
impl ToolSource for Browser {
    fn id(&self) -> &'static str {
        "browser"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let Some(services) = ctx.app.try_state::<Services>() else {
            return vec![];
        };
        if !services.platform.screen.available() {
            return vec![];
        }
        let app = ctx.app.clone();
        vec![LoopTool::read(
            "read_browser_tab",
            "Reads the web page open in the user's browser (Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox, Zen): its title, address and text, also while Nook's chat is in front. Without arguments it reads the page shown in the browser the user works in; with tab it finds the open tab whose title or address contains that text (\"FileSender\", \"bol.com\"). Use it when the user talks about a page, form or site that is open in their browser. A page it finds is open, even when its text cannot be read: never tell the user it is not open.",
            json!({
                "type": "object",
                "properties": {
                    "tab": {
                        "type": "string",
                        "description": "Part of the title or address of the tab to read, when the user names the site or page. Leave empty for the page shown now."
                    },
                    "browser": {
                        "type": "string",
                        "description": "Optional browser name (Google Chrome, Microsoft Edge, Brave, Arc, Vivaldi, Opera, Firefox, Zen)."
                    }
                }
            }),
            move |input| {
                let app = app.clone();
                async move {
                    let tab = text(&input, "tab");
                    let browser = text(&input, "browser");
                    let (_, tab_query) = open_browser_tab::parse_query(&tab, &browser);
                    let app_clone = app.clone();
                    let browser_arg = (!browser.trim().is_empty()).then_some(browser);
                    let tab_arg = (!tab.trim().is_empty()).then_some(tab);
                    let outcome = tauri::async_runtime::spawn_blocking(move || {
                        app_clone
                            .state::<Services>()
                            .platform
                            .screen
                            .read_browser_tab(browser_arg.as_deref(), tab_arg.as_deref())
                    })
                    .await
                    .map_err(|e| nook_core::NookError(e.to_string()))?
                    .map_err(nook_core::NookError)?;
                    match outcome {
                        BrowserTabResult::Found(found) => Ok(open_browser_tab::describe(&found)),
                        BrowserTabResult::NotFound { running } => {
                            Ok(open_browser_tab::no_browser_message(&running, tab_query.as_deref()))
                        }
                        BrowserTabResult::Unsupported => Err(nook_core::NookError::new(tr(
                            "Browsertabbladen lezen is niet beschikbaar op dit platform.",
                            "Reading browser tabs is not available on this platform.",
                        ))),
                    }
                }
            },
        )]
    }
}
