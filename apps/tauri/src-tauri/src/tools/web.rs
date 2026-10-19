//! Het web als bron: zoeken (DuckDuckGo), een webpagina lezen en het weer (Open-Meteo), voor elk brein. Claude via de
//! API zoekt met zijn eigen zoektool; die krijgt `search_web` dan niet. `read_webpage` opent alleen adressen die al
//! eerder voorkwamen, zodat tekst op een pagina het brein niet naar een willekeurig adres kan sturen.

use nook_core::brain::retrieval::reference_line;
use nook_core::brain::web as webtools;
use nook_core::brain::{weather, LoopTool};
use nook_core::provider::AIProvider;
use serde_json::{json, Value};
use tauri::Manager;

use super::{ToolCtx, ToolSource};
use crate::brain::BrainState;

pub struct Web;

#[async_trait::async_trait]
impl ToolSource for Web {
    fn id(&self) -> &'static str {
        "web"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let urls = ctx.app.state::<BrainState>().urls.clone();
        let mut list = vec![];
        if !(ctx.settings.provider == AIProvider::Claude && ctx.settings.web_search) {
            let known = urls.clone();
            list.push(LoopTool::read(
                "search_web",
                "Searches the web (DuckDuckGo) and returns top results with title, URL, and snippet. Use for current info outside the computer: news, opening hours, prices, results, documentation. Follow up with read_webpage if more detail is needed.",
                json!({"type": "object", "properties": {"query": {"type": "string", "description": "Search query."}}, "required": ["query"]}),
                move |input: Value| {
                    let known = known.clone();
                    async move {
                        let query = input["query"].as_str().unwrap_or("").trim().to_string();
                        if query.is_empty() {
                            return Err(nook_core::NookError::new("De zoekopdracht ontbreekt."));
                        }
                        let results = webtools::search(&query).await?;
                        if results.is_empty() {
                            return Ok(format!("No results for \"{query}\"."));
                        }
                        let mut lines = vec![];
                        for result in results.iter().take(8) {
                            known.remember(&result.url);
                            lines.push(format!("### {}\n{}\n{}\n{}", result.title, result.url, result.snippet, reference_line(&result.title, Some(&result.url), "")));
                        }
                        Ok(lines.join("\n\n"))
                    }
                },
            ));
        }
        let timezone = crate::brain::timezone().unwrap_or_default();
        let language = ctx.settings.app_language.clone();
        list.push(LoopTool::read(
            "get_weather",
            "Current weather and the forecast for up to 7 days (temperature, rain chance, wind) from Open-Meteo. Use this for any weather question instead of searching the web. Without a place it uses the user's home town.",
            json!({"type": "object", "properties": {
                "place": {"type": "string", "description": "Town or city, e.g. Utrecht. Leave empty for the user's home town."},
                "days": {"type": "integer", "description": "Number of days, 1 to 7 (default 3)."}
            }}),
            move |input: Value| {
                let (timezone, language) = (timezone.clone(), language.clone());
                async move {
                    let place = input["place"].as_str().unwrap_or("").to_string();
                    let days = input["days"].as_i64().or_else(|| input["days"].as_str().and_then(|d| d.parse().ok())).unwrap_or(3);
                    weather::forecast(&place, days, &timezone, &language).await
                }
            },
        ));
        list.push(LoopTool::read(
            "read_webpage",
            "Reads the text of a webpage. Only for URLs that have already appeared: in the request, on screen, in browser tabs, or in search results.",
            json!({"type": "object", "properties": {"url": {"type": "string", "description": "The full address (https://…)."}}, "required": ["url"]}),
            move |input: Value| {
                let urls = urls.clone();
                async move {
                    let raw = input["url"].as_str().unwrap_or("").trim().to_string();
                    let valid = url::Url::parse(&raw).ok().is_some_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some());
                    if !valid {
                        return Err(nook_core::NookError::new("Ongeldig webadres."));
                    }
                    if !urls.is_known(&raw) {
                        return Err(nook_core::NookError::new("This address was not seen in context; look it up first using search_web."));
                    }
                    let text = webtools::read(&raw).await?;
                    Ok(format!("{text}\n{}", reference_line(&raw, Some(&raw), "")))
                }
            },
        ));
        list
    }
}
