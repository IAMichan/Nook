//! Kleine systeemacties: een link of app openen, muziek bedienen en het volume zetten, en kijken wat er speelt.
//! Acties gebeuren pas na Uitvoeren; de platformlaag doet het werk.

use nook_core::brain::system_report::{fetch_public_address, NetworkAddress, NetworkReport, SystemReport};
use nook_core::brain::LoopTool;
use nook_core::i18n::tr;
use nook_core::platform::MediaCommand;
use serde_json::{json, Value};
use tauri::Manager;
use tauri_plugin_opener::OpenerExt;

use super::{text, ToolCtx, ToolSource};
use crate::services::Services;

pub struct System;

fn level(input: &Value) -> Option<u8> {
    input
        .get("level")
        .and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().trim_end_matches('%').parse().ok())))
        .map(|l| l.clamp(0.0, 100.0) as u8)
}

fn local_addresses() -> Vec<NetworkAddress> {
    let mut found: Vec<_> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() {
            std::net::IpAddr::V4(v4) if !v4.is_unspecified() => Some(NetworkAddress { interface: i.name, address: v4.to_string() }),
            _ => None,
        })
        .collect();
    found.sort_by(|a, b| a.interface.cmp(&b.interface).then_with(|| a.address.cmp(&b.address)));
    found.dedup();
    found
}

#[async_trait::async_trait]
impl ToolSource for System {
    fn id(&self) -> &'static str {
        "system"
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let status_app = ctx.app.clone();
        let mut tools = vec![
            LoopTool::action(
                "open_url",
                "Opens a web address in the user's browser.",
                json!({"type": "object", "properties": {"url": {"type": "string", "description": "https address"}}, "required": ["url"]}),
            ),
            LoopTool::read(
                "system_status",
                "How this computer is doing right now: processor load, memory, temperature (slowed down or not), battery, free disk space, time since restart, and the apps using the most processor and memory. Use for \"why is my computer slow\", \"what drains my battery\", \"how full is my disk\".",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let app = status_app.clone();
                    async move {
                        let (battery, hot) = app
                            .try_state::<Services>()
                            .map(|s| (s.platform.power.battery(), s.platform.power.signals().hot))
                            .unwrap_or((None, false));
                        let report = tauri::async_runtime::spawn_blocking(move || SystemReport::collect(battery, hot))
                            .await
                            .map_err(|e| nook_core::NookError(e.to_string()))?;
                        Ok(report.format())
                    }
                },
            ),
            LoopTool::read(
                "network_status",
                "The IP addresses of this computer right now: the public address the internet sees and the local address per network interface. Use for \"wat is mijn IP-adres\", \"what is my IP\". Reading the public address asks Cloudflare once.",
                json!({"type": "object", "properties": {}}),
                move |_| async move {
                    let addresses = tauri::async_runtime::spawn_blocking(local_addresses).await.unwrap_or_default();
                    let public_address = fetch_public_address().await;
                    Ok(NetworkReport { addresses, public_address }.format())
                },
            ),
        ];
        let Some(services) = ctx.app.try_state::<Services>() else { return tools };
        let caps = crate::platform::capabilities();
        if caps.open_apps {
            tools.push(LoopTool::action(
                "open_app",
                "Opens an application on the user's computer, e.g. \"Firefox\" or \"Rekenmachine\".",
                json!({"type": "object", "properties": {"name": {"type": "string", "description": "Name of the app."}}, "required": ["name"]}),
            ));
        }
        if caps.media {
            tools.push(LoopTool::action(
                "media_control",
                "Controls music or video that is playing (Spotify, a browser, any player the system knows): play_pause, next, or previous.",
                json!({"type": "object", "properties": {"action": {"type": "string", "enum": ["play_pause", "next", "previous"], "description": "Action to perform."}}, "required": ["action"]}),
            ));
            let app = ctx.app.clone();
            tools.push(LoopTool::read(
                "now_playing",
                "Tells which song or video is playing now (title, artist, app, paused or playing).",
                json!({"type": "object", "properties": {}}),
                move |_| {
                    let app = app.clone();
                    async move {
                        let now = tauri::async_runtime::spawn_blocking(move || app.state::<Services>().platform.media.now_playing())
                            .await
                            .ok()
                            .flatten();
                        Ok(match now {
                            Some(n) => format!(
                                "{} \"{}\"{}{} in {}.",
                                if n.playing { "Playing" } else { "Paused" },
                                n.title,
                                if n.artist.is_empty() { String::new() } else { format!(" by {}", n.artist) },
                                if n.album.is_empty() { String::new() } else { format!(" (album {})", n.album) },
                                n.app
                            ),
                            None => "Nothing is playing.".into(),
                        })
                    }
                },
            ));
        }
        if caps.volume {
            tools.push(LoopTool::action(
                "set_volume",
                "Sets the system output volume on the user's computer to a level between 0 and 100.",
                json!({"type": "object", "properties": {"level": {"type": "integer", "description": "Volume 0–100."}}, "required": ["level"]}),
            ));
        }
        let _ = services;
        tools
    }

    async fn context(&self, ctx: &ToolCtx) -> Option<String> {
        let services = ctx.app.try_state::<Services>()?;
        if !crate::platform::capabilities().media {
            return None;
        }
        let media = services.platform.media.clone();
        let now = tauri::async_runtime::spawn_blocking(move || media.now_playing()).await.ok().flatten()?;
        now.playing.then(|| {
            format!(
                "Now playing: \"{}\"{} ({})",
                now.title,
                if now.artist.is_empty() { String::new() } else { format!(" by {}", now.artist) },
                now.app
            )
        })
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            "open_url" => Some(format!("Open {}", text(input, "url"))),
            "open_app" => Some(format!("Open {}", text(input, "name"))),
            "system_status" => Some(tr("Status van deze computer", "This computer's status").into()),
            "network_status" => Some(tr("IP-adressen van deze computer", "IP addresses of this computer").into()),
            "media_control" => Some(
                match text(input, "action").as_str() {
                    "next" => "Volgend nummer",
                    "previous" => "Vorig nummer",
                    _ => "Muziek pauzeren of hervatten",
                }
                .into(),
            ),
            "set_volume" => Some(format!("Volume op {}%", level(input).unwrap_or(0))),
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            "open_url" => {
                let url = text(input, "url");
                if !(url.starts_with("https://") || url.starts_with("http://") || url.starts_with("mailto:")) {
                    return Some(Err("Alleen web- en mailadressen kunnen geopend worden.".into()));
                }
                Some(ctx.app.opener().open_url(&url, None::<&str>).map(|_| format!("Geopend: {url}")).map_err(|e| e.to_string()))
            }
            "open_app" => {
                let name = text(input, "name");
                if name.is_empty() {
                    return Some(Err("De appnaam ontbreekt.".into()));
                }
                let system = ctx.app.state::<Services>().platform.system.clone();
                let target = name.clone();
                Some(
                    tauri::async_runtime::spawn_blocking(move || system.open_app(&target))
                        .await
                        .unwrap_or_else(|e| Err(e.to_string()))
                        .map(|_| format!("{name} geopend")),
                )
            }
            "media_control" => {
                let command = match text(input, "action").as_str() {
                    "next" => MediaCommand::Next,
                    "previous" => MediaCommand::Previous,
                    _ => MediaCommand::PlayPause,
                };
                let media = ctx.app.state::<Services>().platform.media.clone();
                let result = tauri::async_runtime::spawn_blocking(move || media.send(command)).await.unwrap_or_else(|e| Err(e.to_string()));
                crate::services::media::refresh_soon(&ctx.app);
                Some(result.map(|_| "Gedaan".into()))
            }
            "set_volume" => {
                let Some(percent) = level(input) else { return Some(Err("Het volume ontbreekt.".into())) };
                let media = ctx.app.state::<Services>().platform.media.clone();
                Some(
                    tauri::async_runtime::spawn_blocking(move || media.set_volume(percent))
                        .await
                        .unwrap_or_else(|e| Err(e.to_string()))
                        .map(|_| format!("Volume op {percent}%")),
                )
            }
            _ => None,
        }
    }
}
