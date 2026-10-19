//! Kleine systeemacties: een link of een app openen. Muziek en volume komen van de platformlaag
//! (`nook_core::platform::MediaControl`), als die er is.

use std::path::PathBuf;
use std::sync::Arc;

use nook_core::brain::{fuzzy, LoopTool};
use nook_core::platform::{MediaCommand, MediaControl, SystemControl};
use serde_json::{json, Value};
use tauri::Manager;
use tauri_plugin_opener::OpenerExt;

use super::{text, ToolCtx, ToolSource};

pub struct System;

/// Een app die op deze computer staat: de naam die je ziet en hoe hij start.
#[derive(Debug, Clone)]
pub struct InstalledApp {
    pub name: String,
    /// Linux: het .desktop-bestand; Windows: de snelkoppeling in het startmenu.
    pub launcher: PathBuf,
}

/// De apps in het menu van deze computer.
pub fn installed_apps() -> Vec<InstalledApp> {
    let mut apps = vec![];
    #[cfg(target_os = "linux")]
    {
        let mut dirs = vec![
            PathBuf::from("/usr/share/applications"),
            PathBuf::from("/usr/local/share/applications"),
            PathBuf::from("/var/lib/flatpak/exports/share/applications"),
        ];
        if let Some(data) = dirs::data_dir() {
            dirs.push(data.join("applications"));
        }
        for dir in dirs {
            let Ok(entries) = std::fs::read_dir(dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                    continue;
                }
                let Ok(content) = std::fs::read_to_string(&path) else { continue };
                if content.lines().any(|l| l.trim() == "NoDisplay=true" || l.trim() == "Hidden=true") {
                    continue;
                }
                if let Some(name) = content.lines().find_map(|l| l.strip_prefix("Name=")) {
                    apps.push(InstalledApp { name: name.trim().to_string(), launcher: path.clone() });
                }
            }
        }
    }
    #[cfg(target_os = "windows")]
    {
        let mut dirs = vec![];
        if let Some(program_data) = std::env::var_os("ProgramData") {
            dirs.push(PathBuf::from(program_data).join("Microsoft\\Windows\\Start Menu\\Programs"));
        }
        if let Some(appdata) = std::env::var_os("APPDATA") {
            dirs.push(PathBuf::from(appdata).join("Microsoft\\Windows\\Start Menu\\Programs"));
        }
        fn walk(dir: &std::path::Path, apps: &mut Vec<InstalledApp>, depth: u8) {
            let Ok(entries) = std::fs::read_dir(dir) else { return };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() && depth < 3 {
                    walk(&path, apps, depth + 1);
                } else if path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("lnk")) {
                    if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                        if !stem.to_lowercase().contains("uninstall") {
                            apps.push(InstalledApp { name: stem.to_string(), launcher: path.clone() });
                        }
                    }
                }
            }
        }
        for dir in dirs {
            walk(&dir, &mut apps, 0);
        }
    }
    apps
}

/// De app die met deze naam bedoeld is (ook met een typefout), of niets.
pub fn find_app(name: &str) -> Option<InstalledApp> {
    let apps = installed_apps();
    let names: Vec<String> = apps.iter().map(|a| a.name.clone()).collect();
    let best = fuzzy::best(name, &names)?;
    apps.into_iter().find(|a| a.name == best)
}

/// Start een app. Een platformlaag die `SystemControl` levert, gaat voor.
pub fn open_app(app: &tauri::AppHandle, name: &str) -> Result<String, String> {
    if let Some(control) = app.try_state::<Arc<dyn SystemControl>>() {
        return control.open_app(name).map(|_| format!("Geopend: {name}"));
    }
    if cfg!(target_os = "android") {
        return Err("Apps openen kan nog niet op dit platform.".into());
    }
    let found = find_app(name).ok_or_else(|| format!("Ik vind geen app die {name} heet op deze computer."))?;
    launch(app, &found).map(|_| format!("Geopend: {}", found.name))
}

#[cfg(target_os = "linux")]
fn launch(_app: &tauri::AppHandle, found: &InstalledApp) -> Result<(), String> {
    let id = found.launcher.file_name().and_then(|f| f.to_str()).unwrap_or("").to_string();
    if std::process::Command::new("gtk-launch").arg(&id).spawn().is_ok() {
        return Ok(());
    }
    let content = std::fs::read_to_string(&found.launcher).map_err(|e| e.to_string())?;
    let exec = content.lines().find_map(|l| l.strip_prefix("Exec=")).ok_or("Deze app heeft geen startopdracht.")?;
    // Veldcodes (%U, %f, …) vallen weg; de rest start zonder shell.
    let words: Vec<String> = exec.split_whitespace().filter(|w| !w.starts_with('%')).map(|w| w.trim_matches('"').to_string()).collect();
    let (program, args) = words.split_first().ok_or("Deze app heeft geen startopdracht.")?;
    std::process::Command::new(program).args(args).spawn().map(|_| ()).map_err(|e| format!("{} kon niet starten: {e}", found.name))
}

#[cfg(not(target_os = "linux"))]
fn launch(app: &tauri::AppHandle, found: &InstalledApp) -> Result<(), String> {
    app.opener().open_path(found.launcher.to_string_lossy(), None::<&str>).map_err(|e| format!("{} kon niet starten: {e}", found.name))
}

#[async_trait::async_trait]
impl ToolSource for System {
    fn id(&self) -> &'static str {
        "device"
    }

    fn is_source(&self) -> bool {
        false
    }

    fn tools(&self, ctx: &ToolCtx) -> Vec<LoopTool> {
        let mut list = vec![];
        if ctx.app.try_state::<Arc<dyn MediaControl>>().is_some() {
            list.push(LoopTool::action(
                "media_control",
                "Controls the music that is playing: play_pause, next or previous.",
                json!({"type": "object", "properties": {"action": {"type": "string", "enum": ["play_pause", "next", "previous"]}}, "required": ["action"]}),
            ));
            list.push(LoopTool::action(
                "set_volume",
                "Sets the output volume of the computer, 0 to 100.",
                json!({"type": "object", "properties": {"level": {"type": "integer", "description": "Volume 0-100."}}, "required": ["level"]}),
            ));
        }
        list.push(LoopTool::action(
            "open_url",
            "Opens a web address in the user's browser.",
            json!({"type": "object", "properties": {"url": {"type": "string", "description": "https address"}}, "required": ["url"]}),
        ));
        if !cfg!(target_os = "android") {
            list.push(LoopTool::action(
                "open_app",
                "Opens an app on the user's computer by name.",
                json!({"type": "object", "properties": {"name": {"type": "string", "description": "Name of the app, e.g. Firefox."}}, "required": ["name"]}),
            ));
        }
        list
    }

    fn summarize(&self, tool: &str, input: &Value) -> Option<String> {
        match tool {
            "open_url" => Some(format!("Open {}", text(input, "url"))),
            "open_app" => Some(format!("Open de app {}", text(input, "name"))),
            "media_control" => Some(match text(input, "action").as_str() {
                "next" => "Volgend nummer".into(),
                "previous" => "Vorig nummer".into(),
                _ => "Muziek afspelen of pauzeren".into(),
            }),
            "set_volume" => Some(format!("Volume op {}%", input["level"].as_i64().unwrap_or(0))),
            _ => None,
        }
    }

    async fn execute(&self, ctx: &ToolCtx, tool: &str, input: &Value) -> Option<Result<String, String>> {
        match tool {
            "open_url" => {
                let url = text(input, "url");
                if !(url.starts_with("https://") || url.starts_with("http://")) {
                    return Some(Err("Alleen http- en https-adressen.".into()));
                }
                Some(ctx.app.opener().open_url(&url, None::<&str>).map(|_| format!("Geopend: {url}")).map_err(|e| e.to_string()))
            }
            "open_app" => Some(open_app(&ctx.app, &text(input, "name"))),
            "media_control" | "set_volume" => {
                let Some(media) = ctx.app.try_state::<Arc<dyn MediaControl>>() else {
                    return Some(Err("Muziek en volume regelen kan nog niet op dit platform.".into()));
                };
                Some(if tool == "set_volume" {
                    let level = input["level"].as_i64().unwrap_or(50).clamp(0, 100) as u8;
                    media.set_volume(level).map(|_| format!("Volume op {level}%"))
                } else {
                    let command = match text(input, "action").as_str() {
                        "next" => MediaCommand::Next,
                        "previous" => MediaCommand::Previous,
                        _ => MediaCommand::PlayPause,
                    };
                    media.send(command).map(|_| "Gedaan".to_string())
                })
            }
            _ => None,
        }
    }
}
