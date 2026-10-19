//! Koppelt Nook aan je agents door hun instellingenbestand aan te passen, maar pas na jouw OK
//! (`AgentConfigInstaller` op de Mac): Nook leest het bestand, laat precies zien wat er verandert, maakt een backup met
//! datum en schrijft alleen als het bestand sinds de preview niet veranderde. Bestaande instellingen blijven staan.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use super::line_diff::{self, DiffKind, DiffLine};
use super::plugins;
use super::{home_dir, tilde};
use crate::{nook_err, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Target {
    ClaudeHooks,
    ClaudeStatusLine,
    Codex,
    Gemini,
    Antigravity,
    Cursor,
    Copilot,
    Muse,
    OpenCode,
    Amp,
    Hermes,
}

impl Target {
    pub const ALL: [Target; 11] = [
        Self::ClaudeHooks,
        Self::ClaudeStatusLine,
        Self::Codex,
        Self::Gemini,
        Self::Antigravity,
        Self::Cursor,
        Self::Copilot,
        Self::Muse,
        Self::OpenCode,
        Self::Amp,
        Self::Hermes,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::ClaudeHooks => "Claude Code",
            Self::ClaudeStatusLine => "Claude-abonnement in de balk",
            Self::Codex => "Codex",
            Self::Gemini => "Gemini CLI",
            Self::Antigravity => "Antigravity",
            Self::Cursor => "Cursor",
            Self::Copilot => "Copilot CLI",
            Self::Muse => "Muse Code",
            Self::OpenCode => "OpenCode",
            Self::Amp => "Amp",
            Self::Hermes => "Hermes",
        }
    }

    pub fn detail(self) -> &'static str {
        match self {
            Self::ClaudeHooks => "Voortgang, toestemming en vragen in de balk",
            Self::ClaudeStatusLine => "Je 5-uurs- en weeklimiet (Pro/Max), via de statusregel",
            Self::Codex => "Voortgang en toestemming in de balk",
            Self::Gemini | Self::Antigravity | Self::Cursor | Self::Copilot | Self::Muse => "Voortgang in de balk",
            Self::OpenCode | Self::Amp => "Voortgang in de balk, via een kleine plugin",
            Self::Hermes => "Voortgang in de balk, via een plugin. Zet hem daarna aan met: hermes plugins enable nook",
        }
    }

    /// Het (eerste) bestand dat Nook aanpast of maakt.
    pub fn file(self) -> PathBuf {
        let home = home_dir();
        match self {
            Self::ClaudeHooks | Self::ClaudeStatusLine => home.join(".claude").join("settings.json"),
            Self::Codex => home.join(".codex").join("hooks.json"),
            Self::Gemini => home.join(".gemini").join("settings.json"),
            Self::Antigravity => home.join(".gemini").join("config").join("hooks.json"),
            Self::Cursor => home.join(".cursor").join("hooks.json"),
            Self::Copilot => home.join(".copilot").join("hooks").join("nook.json"),
            Self::Muse => home.join(".config").join("muse").join("settings.json"),
            Self::OpenCode => home.join(".config").join("opencode").join("plugins").join("nook.js"),
            Self::Amp => home.join(".config").join("amp").join("plugins").join("nook.ts"),
            Self::Hermes => home.join(".hermes").join("plugins").join("nook").join("__init__.py"),
        }
    }

    /// Het bestand voor een account met een eigen map (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
    pub fn file_for(self, home: Option<&Path>) -> PathBuf {
        match (self, home) {
            (Self::ClaudeHooks | Self::ClaudeStatusLine, Some(h)) => h.join("settings.json"),
            (Self::Codex, Some(h)) => h.join("hooks.json"),
            _ => self.file(),
        }
    }

    pub fn display_path(self, home: Option<&Path>) -> String {
        let path = self.file_for(home);
        let shown = if self == Self::Hermes { path.parent().map(Path::to_path_buf).unwrap_or(path) } else { path };
        tilde(&shown.to_string_lossy())
    }

    pub fn for_agent(name: &str) -> Option<Self> {
        Some(match name {
            "Claude Code" => Self::ClaudeHooks,
            "Codex" => Self::Codex,
            "Gemini CLI" => Self::Gemini,
            "Antigravity" => Self::Antigravity,
            "Cursor" => Self::Cursor,
            "Copilot CLI" => Self::Copilot,
            "Muse Code" => Self::Muse,
            "OpenCode" => Self::OpenCode,
            "Amp" => Self::Amp,
            "Hermes" => Self::Hermes,
            _ => return None,
        })
    }

    pub fn is_plugin(self) -> bool {
        matches!(self, Self::OpenCode | Self::Amp | Self::Hermes)
    }

    /// Pluginbestanden en hun inhoud; leeg voor agents met JSON-instellingen.
    pub fn plugin_files(self) -> Vec<(PathBuf, String)> {
        let hook = hook_path_text();
        match self {
            Self::OpenCode => vec![(self.file(), plugins::open_code(&hook))],
            Self::Amp => vec![(self.file(), plugins::amp(&hook))],
            Self::Hermes => {
                let manifest = self.file().with_file_name("plugin.yaml");
                vec![(self.file(), plugins::hermes_init(&hook)), (manifest, plugins::HERMES_MANIFEST.into())]
            }
            _ => vec![],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "detail", rename_all = "camelCase")]
pub enum State {
    NotInstalled,
    Installed,
    /// Gekoppeld met een oudere versie van Nook: opnieuw koppelen geeft toestemming en vragen in de balk.
    Outdated,
    Unreadable(String),
}

/// Eén bestand in een wijziging. `updated == None`: het bestand gaat weg (alleen voor bestanden van Nook zelf).
#[derive(Debug, Clone)]
pub struct FileChange {
    pub path: PathBuf,
    pub original: Option<Vec<u8>>,
    pub updated: Option<Vec<u8>>,
}

/// Een voorgestelde wijziging. Alleen [`apply`] schrijft hem weg.
#[derive(Debug, Clone)]
pub struct Change {
    pub target: Target,
    pub install: bool,
    pub home: Option<PathBuf>,
    pub files: Vec<FileChange>,
    pub preview: Vec<DiffLine>,
    pub previous_status_line: Option<Vec<u8>>,
    pub remove_previous_status_line: bool,
}

const MARKER: &str = "nook-hook";
/// De groep van Nook in `~/.gemini/config/hooks.json` (Antigravity).
const ANTIGRAVITY_GROUP: &str = "nook";

/// Het hook-commando van Nook: `~/.nook/nook-hook` (Windows: `nook-hook.exe`). De app zet het daar bij de start.
pub fn hook_path() -> PathBuf {
    crate::paths::dot_nook().join(if cfg!(windows) { "nook-hook.exe" } else { "nook-hook" })
}

/// Het pad met `/` als scheidingsteken: werkt in bash (Git Bash, zoals Claude Code op Windows gebruikt), cmd en
/// PowerShell, waar `\` in bash een escape zou zijn.
pub fn hook_path_text() -> String {
    hook_path().to_string_lossy().replace('\\', "/")
}

/// De opdrachtregel voor een instellingenbestand, met aanhalingstekens als het pad een spatie heeft.
pub fn hook_command(arguments: &str) -> String {
    let path = hook_path_text();
    if path.contains(' ') {
        format!("\"{path}\" {arguments}")
    } else {
        format!("{path} {arguments}")
    }
}

/// Waar de eerdere statusregel van Claude Code bewaard wordt (het hook-commando roept hem zelf nog aan).
pub fn previous_status_line_file() -> PathBuf {
    crate::paths::dot_nook().join("statusline-previous.json")
}

struct Snapshot {
    object: Map<String, Value>,
    original: Option<Vec<u8>>,
}

/// Een ontbrekend bestand telt als leeg; een onleesbaar of ongeldig bestand nooit.
fn read(path: &Path) -> Result<Snapshot> {
    if !path.exists() {
        return Ok(Snapshot { object: Map::new(), original: None });
    }
    let data =
        std::fs::read(path).map_err(|_| nook_err!("{} is niet te lezen. Nook heeft niets aangeraakt.", tilde(&path.to_string_lossy())))?;
    if data.iter().all(|b| b.is_ascii_whitespace()) {
        return Ok(Snapshot { object: Map::new(), original: Some(data) });
    }
    match serde_json::from_slice::<Value>(&data) {
        Ok(Value::Object(object)) => Ok(Snapshot { object, original: Some(data) }),
        _ => Err(nook_err!("{} is geen geldige JSON (of bevat commentaar). Nook heeft niets aangeraakt.", tilde(&path.to_string_lossy()))),
    }
}

/// De inhoud van een pluginbestand van Nook, of `None` als het er niet is. Onleesbaar of niet van Nook: nooit aanraken.
fn read_plugin(path: &Path) -> Result<Option<Vec<u8>>> {
    if !path.exists() {
        return Ok(None);
    }
    let data =
        std::fs::read(path).map_err(|_| nook_err!("{} is niet te lezen. Nook heeft niets aangeraakt.", tilde(&path.to_string_lossy())))?;
    if !String::from_utf8_lossy(&data).contains(plugins::MARKER) {
        return Err(nook_err!("{} bestaat al en is niet door Nook gemaakt. Nook heeft niets aangeraakt.", tilde(&path.to_string_lossy())));
    }
    Ok(Some(data))
}

fn contains_marker(value: &Value) -> bool {
    match value {
        Value::String(s) => s.contains(MARKER),
        Value::Array(a) => a.iter().any(contains_marker),
        Value::Object(o) => o.values().any(contains_marker),
        _ => false,
    }
}

/// `home`: de map van een extra account; `None` voor de standaardmap.
pub fn state(target: Target, home: Option<&Path>) -> State {
    if target.is_plugin() {
        return plugin_state(target);
    }
    let root = match read(&target.file_for(home)) {
        Ok(s) => s.object,
        Err(e) => return State::Unreadable(e.0),
    };
    match target {
        Target::ClaudeStatusLine => {
            let command = root.get("statusLine").and_then(|s| s.get("command")).and_then(Value::as_str).unwrap_or("");
            if command.contains(MARKER) {
                State::Installed
            } else {
                State::NotInstalled
            }
        }
        Target::Antigravity => match root.get(ANTIGRAVITY_GROUP) {
            Some(block) if contains_marker(block) => {
                // Oudere versies gebruikten een pad met aanhalingstekens en een PreToolUse-hook: opnieuw koppelen herstelt.
                if block.get("PreToolUse").is_some() || block.to_string().contains("\\\"") {
                    State::Outdated
                } else {
                    State::Installed
                }
            }
            _ => State::NotInstalled,
        },
        _ => {
            let hooks = root.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
            if !hooks.values().any(contains_marker) {
                return State::NotInstalled;
            }
            if target == Target::ClaudeHooks {
                let current = hooks.get("PermissionRequest").is_some_and(contains_marker);
                let asks = hooks.get("PreToolUse").and_then(Value::as_array).is_some_and(|groups| {
                    groups.iter().any(|g| g.get("matcher").and_then(Value::as_str) == Some("AskUserQuestion") && contains_marker(g))
                });
                return if current && asks { State::Installed } else { State::Outdated };
            }
            State::Installed
        }
    }
}

/// Een plugin is gekoppeld als al zijn bestanden er zijn en van Nook komen.
fn plugin_state(target: Target) -> State {
    let files = target.plugin_files();
    let mut present = 0;
    for (path, _) in &files {
        match read_plugin(path) {
            Ok(Some(_)) => present += 1,
            Ok(None) => {}
            Err(e) => return State::Unreadable(e.0),
        }
    }
    if present == files.len() && present > 0 {
        State::Installed
    } else {
        State::NotInstalled
    }
}

fn hooks_object(root: &Map<String, Value>) -> Result<Map<String, Value>> {
    match root.get("hooks") {
        None => Ok(Map::new()),
        Some(Value::Object(o)) => Ok(o.clone()),
        Some(_) => Err(nook_err!("\"hooks\" heeft een onverwachte vorm. Nook heeft niets aangeraakt.")),
    }
}

fn set_hooks(root: &mut Map<String, Value>, hooks: Map<String, Value>) {
    if hooks.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(hooks));
    }
}

fn group(command: &str, matcher: Option<&str>, timeout: u64) -> Value {
    let mut g = json!({"hooks": [{"type": "command", "command": command, "timeout": timeout}]});
    if let Some(m) = matcher {
        g["matcher"] = json!(m);
    }
    g
}

fn append(hooks: &mut Map<String, Value>, event: &str, group: Value) -> Result<()> {
    let entry = hooks.entry(event.to_string()).or_insert_with(|| json!([]));
    match entry.as_array_mut() {
        Some(list) => {
            list.push(group);
            Ok(())
        }
        None => Err(nook_err!("\"hooks\".{event} heeft een onverwachte vorm. Nook heeft niets aangeraakt.")),
    }
}

/// Haalt alleen de eigen regels van Nook weg; groepen die leeg worden ook.
fn without_nook(hooks: Map<String, Value>) -> Result<Map<String, Value>> {
    let mut result = Map::new();
    for (event, value) in hooks {
        let Value::Array(groups) = value else {
            if contains_marker(&value) {
                return Err(nook_err!("\"hooks\".{event} heeft een onverwachte vorm. Nook heeft niets aangeraakt."));
            }
            result.insert(event, value);
            continue;
        };
        let mut kept = vec![];
        for entry in groups {
            let Value::Object(mut g) = entry else {
                kept.push(entry);
                continue;
            };
            if g.get("command").and_then(Value::as_str).is_some_and(|c| c.contains(MARKER)) {
                continue;
            }
            // Een losse regel zonder "hooks" (Copilot: "bash") van Nook.
            if g.get("hooks").is_none() && contains_marker(&Value::Object(g.clone())) {
                continue;
            }
            if let Some(Value::Array(inner)) = g.get("hooks") {
                let filtered: Vec<Value> = inner.iter().filter(|h| !contains_marker(h)).cloned().collect();
                if filtered.is_empty() {
                    continue;
                }
                g.insert("hooks".into(), Value::Array(filtered));
            }
            kept.push(Value::Object(g));
        }
        if !kept.is_empty() {
            result.insert(event, Value::Array(kept));
        }
    }
    Ok(result)
}

fn pretty(object: &Map<String, Value>) -> Vec<u8> {
    serde_json::to_vec_pretty(object).unwrap_or_default()
}

pub fn prepare(target: Target, install: bool, home: Option<&Path>) -> Result<Change> {
    if target.is_plugin() {
        return prepare_plugin(target, install);
    }
    let file = target.file_for(home);
    let snapshot = read(&file)?;
    let mut root = snapshot.object.clone();
    let mut previous = None;
    let mut remove_previous = false;
    let mut remove_file = false;

    match target {
        Target::ClaudeHooks => {
            let mut hooks = without_nook(hooks_object(&root)?)?;
            if install {
                let plain = hook_command("--agent claude-code");
                for event in [
                    "SessionStart",
                    "SessionEnd",
                    "UserPromptSubmit",
                    "PostToolUse",
                    "PostToolUseFailure",
                    "Notification",
                    "Stop",
                    "StopFailure",
                    "SubagentStart",
                    "SubagentStop",
                ] {
                    append(&mut hooks, event, group(&plain, None, 5))?;
                }
                append(&mut hooks, "PreToolUse", group(&plain, None, 5))?;
                append(&mut hooks, "PreToolUse", group(&hook_command("--agent claude-code --ask"), Some("AskUserQuestion"), 130))?;
                append(&mut hooks, "PermissionRequest", group(&hook_command("--agent claude-code --wait"), None, 120))?;
            }
            set_hooks(&mut root, hooks);
        }
        Target::Codex => {
            let mut hooks = without_nook(hooks_object(&root)?)?;
            if install {
                let plain = hook_command("--agent codex");
                for (event, timeout) in
                    [("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5), ("Stop", 5), ("SessionEnd", 3)]
                {
                    append(&mut hooks, event, group(&plain, None, timeout))?;
                }
                let mut waiting = group(&hook_command("--agent codex --wait"), None, 120);
                waiting["hooks"][0]["statusMessage"] = json!("Waiting for your response in Nook");
                append(&mut hooks, "PermissionRequest", waiting)?;
            }
            set_hooks(&mut root, hooks);
        }
        Target::Gemini => {
            let mut hooks = without_nook(hooks_object(&root)?)?;
            if install {
                // Gemini gebruikt eigen namen en milliseconden; Nook krijgt de gewone namen mee.
                for (event, name, timeout) in [
                    ("SessionStart", "SessionStart", 10_000),
                    ("SessionEnd", "SessionEnd", 10_000),
                    ("BeforeTool", "PreToolUse", 5_000),
                    ("AfterTool", "PostToolUse", 5_000),
                    ("BeforeAgent", "UserPromptSubmit", 5_000),
                    ("AfterAgent", "Stop", 5_000),
                ] {
                    append(&mut hooks, event, group(&hook_command(&format!("--agent gemini {name}")), Some("*"), timeout))?;
                }
            }
            set_hooks(&mut root, hooks);
        }
        Target::Antigravity => {
            if let Some(existing) = root.get(ANTIGRAVITY_GROUP) {
                if !contains_marker(existing) {
                    return Err(nook_err!(
                        "{} heeft al een groep \"{ANTIGRAVITY_GROUP}\" die niet van Nook is. Nook heeft niets veranderd.",
                        target.display_path(home)
                    ));
                }
            }
            root.remove(ANTIGRAVITY_GROUP);
            if install {
                // Geen PreToolUse: agy draait die voor elke tool en blokkeert op een falende hook, en Nook toont alleen
                // voortgang. Het pad zonder aanhalingstekens: agy splitst de opdrachtregel misschien zelf.
                let path = hook_path_text();
                let command = |args: &str| format!("{path} {args}");
                let mut block = Map::new();
                block.insert("PostToolUse".into(), json!([group(&command("--agent antigravity PostToolUse"), Some("*"), 10)]));
                for event in ["PreInvocation", "PostInvocation", "Stop"] {
                    block.insert(
                        event.into(),
                        json!([{"type": "command", "command": command(&format!("--agent antigravity {event}")), "timeout": 10}]),
                    );
                }
                root.insert(ANTIGRAVITY_GROUP.into(), Value::Object(block));
            }
        }
        Target::Cursor => {
            // {"version": 1, "hooks": {"stop": [{"command": …}]}}: Cursor zet de naam in de JSON en wacht nooit op
            // een antwoord, dus Nook beslist niets voor Cursor.
            let mut hooks = without_nook(hooks_object(&root)?)?;
            if install {
                for event in [
                    "sessionStart",
                    "sessionEnd",
                    "beforeSubmitPrompt",
                    "preToolUse",
                    "postToolUse",
                    "postToolUseFailure",
                    "subagentStart",
                    "subagentStop",
                    "stop",
                ] {
                    append(&mut hooks, event, json!({"command": hook_command(&format!("--agent cursor {event}"))}))?;
                }
                root.entry("version").or_insert(json!(1));
            }
            set_hooks(&mut root, hooks);
        }
        Target::Copilot => {
            // Een eigen bestand in de hooks-map van Copilot: camelCase, {"bash": …, "powershell": …, "timeoutSec": N}.
            let mut hooks = without_nook(hooks_object(&root)?)?;
            if install {
                for (event, timeout) in [
                    ("sessionStart", 10),
                    ("userPromptSubmitted", 10),
                    ("preToolUse", 10),
                    ("postToolUse", 10),
                    ("agentStop", 10),
                    ("sessionEnd", 3),
                    ("notification", 10),
                ] {
                    let command = hook_command(&format!("--agent copilot {event}"));
                    append(&mut hooks, event, json!({"type": "command", "bash": command, "powershell": command, "timeoutSec": timeout}))?;
                }
                root.insert("version".into(), json!(1));
            }
            set_hooks(&mut root, hooks);
            // Blijft er na ontkoppelen niets van een ander over, dan was het bestand van Nook en gaat het weg.
            if !install && root.keys().all(|k| k == "version") {
                remove_file = true;
            }
        }
        Target::Muse => {
            let mut hooks = without_nook(hooks_object(&root)?)?;
            if install {
                for (event, seconds) in
                    [("SessionStart", 10), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5), ("Stop", 5), ("SessionEnd", 3)]
                {
                    append(&mut hooks, event, group(&hook_command(&format!("--agent muse {event}")), Some("*"), seconds * 1_000))?;
                }
                if snapshot.original.is_none() {
                    root.insert("schema_version".into(), json!(1));
                }
            }
            set_hooks(&mut root, hooks);
        }
        Target::ClaudeStatusLine => {
            let current = root.get("statusLine").and_then(Value::as_object).cloned();
            let ours = current.as_ref().and_then(|c| c.get("command")).and_then(Value::as_str).is_some_and(|c| c.contains(MARKER));
            if install {
                let mut line = current.clone().unwrap_or_else(|| Map::from_iter([("type".to_string(), json!("command"))]));
                if let Some(cur) = current.filter(|_| !ours && home.is_none()) {
                    // De bestaande statusregel blijft zichtbaar: Nook roept hem zelf aan.
                    previous = serde_json::to_vec(&cur).ok();
                }
                line.insert("type".into(), json!("command"));
                line.insert("command".into(), json!(hook_command("--statusline")));
                root.insert("statusLine".into(), Value::Object(line));
            } else if ours {
                match std::fs::read(previous_status_line_file()).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
                    Some(saved) if saved.is_object() => {
                        root.insert("statusLine".into(), saved);
                    }
                    _ => {
                        root.remove("statusLine");
                    }
                }
                remove_previous = true;
            }
        }
        Target::OpenCode | Target::Amp | Target::Hermes => unreachable!(),
    }

    let updated = (!remove_file).then(|| pretty(&root));
    let before = snapshot.original.as_ref().map(|_| pretty(&snapshot.object)).unwrap_or_default();
    let (preview, _, _) =
        line_diff::text_diff(&String::from_utf8_lossy(&before), &String::from_utf8_lossy(updated.as_deref().unwrap_or(&[])), 2, 400, 200);
    // Een bestand dat er niet is en niet hoeft te komen: niets te doen.
    let files = if snapshot.original.is_none() && updated.is_none() {
        vec![]
    } else {
        vec![FileChange { path: file, original: snapshot.original, updated }]
    };
    Ok(Change {
        target,
        install,
        home: home.map(Path::to_path_buf),
        files,
        preview,
        previous_status_line: previous,
        remove_previous_status_line: remove_previous,
    })
}

/// Een plugin is Nooks eigen bestand: koppelen schrijft hem (opnieuw), ontkoppelen haalt hem weg.
fn prepare_plugin(target: Target, install: bool) -> Result<Change> {
    let files_in = target.plugin_files();
    let several = files_in.len() > 1;
    let mut files = vec![];
    let mut preview = vec![];
    for (path, contents) in files_in {
        let original = read_plugin(&path)?;
        let updated = install.then(|| contents.into_bytes());
        if original.is_none() && updated.is_none() {
            continue;
        }
        if several {
            preview
                .push(DiffLine {
                    kind: DiffKind::Context, text: format!("── {}", path.file_name().unwrap_or_default().to_string_lossy())
                });
        }
        let (lines, _, _) = line_diff::text_diff(
            &String::from_utf8_lossy(original.as_deref().unwrap_or(&[])),
            &String::from_utf8_lossy(updated.as_deref().unwrap_or(&[])),
            2,
            400,
            200,
        );
        preview.extend(lines);
        files.push(FileChange { path, original, updated });
    }
    Ok(Change { target, install, home: None, files, preview, previous_status_line: None, remove_previous_status_line: false })
}

/// Schrijft de wijziging na een backup. Is een bestand sinds de preview veranderd, dan wordt er niets geschreven.
/// Geeft het pad van de (eerste) backup terug.
pub fn apply(change: &Change) -> Result<Option<PathBuf>> {
    let shown = change.target.display_path(change.home.as_deref());
    for file in &change.files {
        let current = if file.path.exists() { std::fs::read(&file.path).ok() } else { None };
        if current != file.original {
            return Err(nook_err!("{shown} is veranderd sinds de preview. Er is niets geschreven; bekijk het opnieuw."));
        }
    }
    let pending: Vec<&FileChange> = change.files.iter().filter(|f| f.original != f.updated).collect();
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let mut backup = None;
    for file in pending.iter().filter(|f| f.original.is_some()) {
        let name = file.path.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let target = file.path.with_file_name(format!("{name}.nook-backup-{stamp}"));
        std::fs::copy(&file.path, &target).map_err(|_| nook_err!("Kon geen backup maken van {shown}. Er is niets geschreven."))?;
        backup.get_or_insert(target);
    }
    for file in pending {
        let result = match &file.updated {
            Some(data) => file.path.parent().map(std::fs::create_dir_all).transpose().and_then(|_| write_keeping(&file.path, data)),
            None if file.path.exists() => std::fs::remove_file(&file.path),
            None => Ok(()),
        };
        result.map_err(|e| nook_err!("Kon {shown} niet schrijven: {e}. De backup staat ernaast."))?;
    }
    if let Some(previous) = &change.previous_status_line {
        let _ = crate::paths::write_atomic(&previous_status_line_file(), previous);
    }
    if change.remove_previous_status_line {
        let _ = std::fs::remove_file(previous_status_line_file());
    }
    Ok(backup)
}

/// Schrijft via een tijdelijk bestand en houdt de rechten van het bestaande bestand.
fn write_keeping(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let permissions = std::fs::metadata(path).ok().map(|m| m.permissions());
    let tmp = path.with_extension("nook-tmp");
    std::fs::write(&tmp, data)?;
    if let Some(p) = permissions {
        let _ = std::fs::set_permissions(&tmp, p);
    }
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-installer-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn claude_hooks_keep_existing_and_round_trip() {
        let home = temp();
        let file = home.join("settings.json");
        std::fs::write(&file, r#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say klaar"}]}]}}"#).unwrap();
        assert_eq!(state(Target::ClaudeHooks, Some(&home)), State::NotInstalled);
        let change = prepare(Target::ClaudeHooks, true, Some(&home)).unwrap();
        assert!(change.preview.iter().any(|l| l.kind == DiffKind::Add && l.text.contains("nook-hook")));
        let backup = apply(&change).unwrap().unwrap();
        assert!(backup.to_string_lossy().contains(".nook-backup-"));
        assert_eq!(state(Target::ClaudeHooks, Some(&home)), State::Installed);
        let v: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(v["model"], "opus");
        assert_eq!(v["hooks"]["Stop"].as_array().unwrap().len(), 2, "eigen hook blijft staan");
        let undo = prepare(Target::ClaudeHooks, false, Some(&home)).unwrap();
        apply(&undo).unwrap();
        let v: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(v["hooks"]["Stop"][0]["hooks"][0]["command"], "say klaar");
        assert!(v["hooks"].get("PermissionRequest").is_none());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn invalid_json_is_never_touched() {
        let home = temp();
        std::fs::write(home.join("settings.json"), "{ // commentaar\n}").unwrap();
        assert!(prepare(Target::ClaudeHooks, true, Some(&home)).is_err());
        assert!(matches!(state(Target::ClaudeHooks, Some(&home)), State::Unreadable(_)));
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn changed_since_preview_writes_nothing() {
        let home = temp();
        let file = home.join("hooks.json");
        let change = prepare(Target::Codex, true, Some(&home)).unwrap();
        std::fs::write(&file, "{}").unwrap();
        assert!(apply(&change).is_err());
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "{}");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn codex_waits_with_status_message() {
        let home = temp();
        let change = prepare(Target::Codex, true, Some(&home)).unwrap();
        apply(&change).unwrap();
        let v: Value = serde_json::from_slice(&std::fs::read(home.join("hooks.json")).unwrap()).unwrap();
        let wait = &v["hooks"]["PermissionRequest"][0]["hooks"][0];
        assert!(wait["command"].as_str().unwrap().ends_with("--agent codex --wait"));
        assert_eq!(wait["timeout"], 120);
        assert!(!wait["command"].as_str().unwrap().contains('\\'));
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn helpers() {
        assert!(hook_command("--agent x").contains("nook-hook"));
        let mut hooks = Map::new();
        hooks.insert(
            "Stop".into(),
            json!([{"hooks": [{"command": "a"}, {"command": "/x/nook-hook --agent y"}]}, {"command": "z nook-hook"}]),
        );
        let cleaned = without_nook(hooks).unwrap();
        assert_eq!(cleaned["Stop"], json!([{"hooks": [{"command": "a"}]}]));
    }
}
