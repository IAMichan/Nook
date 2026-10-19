//! Het hook-commando dat agents bij elke gebeurtenis starten (`HookScript` op de Mac, daar een Perl-script). Hier is
//! het Nook zelf in een aparte stand: `~/.nook/nook-hook --agent <naam> [Gebeurtenis] [--wait|--ask|--statusline]`,
//! met de JSON van de gebeurtenis op stdin. Het levert één bericht af bij Nook en drukt het antwoord af. Draait Nook
//! niet of duurt het te lang, dan stopt het netjes en gaat de agent gewoon door.
//!
//! Hier staat de logica zonder in- en uitvoer (testbaar); `src-tauri/src/main.rs` koppelt hem aan stdin, stdout en de
//! verbinding met Nook voordat Tauri start.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::{json, Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Event,
    /// Wacht op een beslissing in de balk (toestemming).
    Permission,
    /// Een meerkeuzevraag beantwoorden in de balk (AskUserQuestion).
    Ask,
    /// Het abonnementsgebruik doorgeven en de statusregel tekenen.
    Statusline,
}

impl Mode {
    pub fn id(self) -> &'static str {
        match self {
            Self::Event => "event",
            Self::Permission => "permission",
            Self::Ask => "ask",
            Self::Statusline => "statusline",
        }
    }

    /// Hoe lang er op Nook gewacht wordt (binnen de hook-limiet van de agent).
    pub fn timeout(self) -> Duration {
        match self {
            Self::Permission => Duration::from_secs(115),
            Self::Ask => Duration::from_secs(125),
            _ => Duration::from_secs(3),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookArgs {
    pub agent: String,
    pub agent_given: bool,
    pub mode: Mode,
    /// JSON die als argument werd meegegeven in plaats van op stdin.
    pub payload: Option<String>,
    pub event_name: String,
}

pub fn parse_args(args: &[String]) -> HookArgs {
    let mut parsed =
        HookArgs { agent: "claude-code".into(), agent_given: false, mode: Mode::Event, payload: None, event_name: String::new() };
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--hook" => {}
            "--agent" => {
                if let Some(next) = iter.next() {
                    parsed.agent = next.clone();
                    parsed.agent_given = true;
                }
            }
            "--wait" => parsed.mode = Mode::Permission,
            "--ask" => parsed.mode = Mode::Ask,
            "--statusline" => parsed.mode = Mode::Statusline,
            a if a.trim_start().starts_with('{') => parsed.payload = Some(a.to_string()),
            a if parsed.event_name.is_empty() && !a.starts_with("--") => parsed.event_name = a.to_string(),
            _ => {}
        }
    }
    parsed
}

/// Omgevingsvariabelen die Nook meekrijgt: welke terminal, welk account, of Nook de sessie zelf draait.
pub const ENV_KEYS: &[&str] = &[
    "TERM_PROGRAM",
    "__CFBundleIdentifier",
    "ITERM_SESSION_ID",
    "TERM_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CONFIG_DIR",
    "CODEX_HOME",
    "NOOK_RUN_ID",
    "ANTIGRAVITY_CONVERSATION_ID",
    "ANTIGRAVITY_APP_DATA_DIR",
    "WT_SESSION",
    "WINDOWID",
    "TERMINAL_EMULATOR",
    "KONSOLE_VERSION",
    "KITTY_WINDOW_ID",
    "WEZTERM_PANE",
    "TMUX",
    "VSCODE_PID",
];

fn first_text<'a>(values: &[Option<&'a Value>]) -> Option<&'a str> {
    values.iter().flatten().find_map(|v| v.as_str().filter(|s| !s.is_empty()))
}

/// Een geldige agentnaam: kleine letters, cijfers, `-` en `_`, hooguit 32 tekens.
pub fn valid_agent_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else { return false };
    (first.is_ascii_lowercase() || first.is_ascii_digit())
        && name.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

/// De berichten voor Nook (meestal één; twee bij `nook_show_step`), en de definitieve agent en stand.
pub fn messages(args: &HookArgs, payload: &str, env: &dyn Fn(&str) -> Option<String>) -> (Vec<String>, String, Mode) {
    let mut event: Value = serde_json::from_str(payload).ok().filter(Value::is_object).unwrap_or(json!({}));
    let mut agent = args.agent.clone();
    let mut mode = args.mode;
    if !args.event_name.is_empty() && event.get("hook_event_name").is_none() {
        event["hook_event_name"] = json!(args.event_name);
    }
    if !args.agent_given {
        if let Some(tag) = first_text(&[event.get("nook_agent")]) {
            if valid_agent_name(tag) {
                agent = tag.to_string();
            }
        }
    }
    if mode != Mode::Statusline {
        fill_fields(&mut event, &agent, env);
    }
    let name = first_text(&[event.get("hook_event_name")]).unwrap_or("").to_string();
    if name == "PermissionRequest" || name == "permissionRequest" {
        mode = Mode::Permission;
    }
    let mut environment = Map::new();
    for key in ENV_KEYS {
        environment.insert((*key).into(), json!(env(key).unwrap_or_default()));
    }
    // nook_show_step: een stap (eerst Pre, dan Post) voor agents die alleen melden dat een tool klaar is.
    let mut events = vec![];
    if mode == Mode::Event && event.get("nook_show_step").is_some_and(|v| v.as_bool().unwrap_or(false) || v.as_i64() == Some(1)) {
        let mut before = event.clone();
        before["hook_event_name"] = json!("PreToolUse");
        event["hook_event_name"] = json!("PostToolUse");
        events.push(before);
    }
    events.push(event);
    let lines = events
        .into_iter()
        .map(|mut e| {
            if let Some(o) = e.as_object_mut() {
                o.remove("nook_show_step");
            }
            json!({"agent": agent, "mode": mode.id(), "env": environment, "event": e}).to_string() + "\n"
        })
        .collect();
    (lines, agent, mode)
}

/// Zet velden van andere agents (Copilot, Cursor, Antigravity, Gemini) om naar die van Claude Code. Wat er al staat,
/// blijft staan.
pub fn fill_fields(e: &mut Value, agent: &str, env: &dyn Fn(&str) -> Option<String>) {
    let call = e.get("toolCall").filter(|c| c.is_object()).cloned().unwrap_or(json!({}));
    if e.get("tool_name").is_none() {
        if let Some(tool) = first_text(&[e.get("toolName"), call.get("name"), e.get("tool")]) {
            e["tool_name"] = json!(tool);
        }
    }
    if e.get("tool_input").is_none() {
        let mut args = e.get("toolArgs").cloned();
        if let Some(Value::String(text)) = &args {
            args = serde_json::from_str(text).ok();
        }
        if let Some(a) = args.filter(Value::is_object) {
            e["tool_input"] = a;
        } else if let Some(flat) = call.get("args").and_then(Value::as_object) {
            let mut flat = flat.clone();
            for (from, to) in [
                ("CommandLine", "command"),
                ("FilePath", "file_path"),
                ("Path", "path"),
                ("Url", "url"),
                ("Query", "query"),
                ("Pattern", "pattern"),
            ] {
                if let Some(v) = flat.get(from).cloned() {
                    flat.entry(to.to_string()).or_insert(v);
                }
            }
            e["tool_input"] = Value::Object(flat);
        }
    }
    if first_text(&[e.get("session_id")]).is_none() {
        let mut sid = first_text(&[e.get("conversationId"), e.get("sessionId"), e.get("conversation_id")]).map(str::to_string);
        if sid.is_none() && agent == "antigravity" {
            sid = env("ANTIGRAVITY_CONVERSATION_ID").filter(|s| !s.is_empty());
        }
        if sid.is_none() && (agent == "gemini" || agent == "antigravity") {
            sid = env("GEMINI_SESSION_ID").filter(|s| !s.is_empty());
        }
        if let Some(sid) = sid {
            e["session_id"] = json!(sid);
        }
    }
    if first_text(&[e.get("transcript_path")]).is_none() && agent == "antigravity" {
        let cid = first_text(&[e.get("session_id"), e.get("conversationId"), e.get("conversation_id")])
            .map(str::to_string)
            .or_else(|| env("ANTIGRAVITY_CONVERSATION_ID").filter(|s| !s.is_empty()));
        if let Some(cid) = cid {
            let app_data = env("ANTIGRAVITY_APP_DATA_DIR")
                .filter(|s| !s.is_empty())
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".gemini").join("antigravity"));
            let path = app_data.join("brain").join(cid).join(".system_generated").join("logs").join("transcript.jsonl");
            e["transcript_path"] = json!(path.to_string_lossy());
        }
    }
    if first_text(&[e.get("cwd")]).is_none() {
        let mut cwd = first_text(&[e.get("workdir")]).map(str::to_string);
        for key in ["workspacePaths", "workspace_roots"] {
            if cwd.is_some() {
                break;
            }
            cwd = e.get(key).and_then(|v| v.get(0)).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
        }
        if let Some(cwd) = cwd {
            e["cwd"] = json!(cwd);
        }
    }
    // Cursor meldt een mislukte stop met status "error".
    let stop = first_text(&[e.get("hook_event_name")]);
    if matches!(stop, Some("stop") | Some("Stop")) && first_text(&[e.get("status")]) == Some("error") {
        e["hook_event_name"] = json!("StopFailure");
    }
}

/// Wat het hook-commando afdrukt, gegeven het antwoord van Nook (leeg als er geen kwam).
pub fn output(agent: &str, mode: Mode, reply: &str) -> Option<String> {
    let reply = reply.trim_end_matches(['\n', '\r']);
    if agent == "copilot" && mode == Mode::Permission {
        return Some(copilot_decision(reply));
    }
    if !reply.is_empty() {
        return Some(reply.to_string());
    }
    // Deze agents willen altijd JSON; een leeg object betekent dat Nook niets beslist.
    if matches!(agent, "gemini" | "antigravity" | "copilot") {
        return Some("{}".into());
    }
    None
}

/// Copilot CLI wil een geldige beslissing. Zonder antwoord uit de balk vraagt hij het zelf ("ask").
pub fn copilot_decision(reply: &str) -> String {
    let behavior = serde_json::from_str::<Value>(reply)
        .ok()
        .and_then(|a| a.pointer("/hookSpecificOutput/decision/behavior").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_default();
    match behavior.as_str() {
        "allow" => r#"{"permissionDecision":"allow"}"#.into(),
        "deny" => r#"{"permissionDecision":"deny"}"#.into(),
        _ => r#"{"permissionDecision":"ask"}"#.into(),
    }
}

/// Een korte statusregel als er geen eerdere is: "Opus · 5u 34% · week 12%".
pub fn fallback_statusline(payload: &str) -> String {
    let event: Value = serde_json::from_str(payload).unwrap_or(json!({}));
    let mut parts = vec![];
    if let Some(name) = event.pointer("/model/display_name").and_then(Value::as_str) {
        parts.push(name.to_string());
    }
    let windows: BTreeMap<&str, &str> = [("five_hour", "5u"), ("seven_day", "week")].into_iter().collect();
    for key in ["five_hour", "seven_day"] {
        if let Some(p) = event.pointer(&format!("/rate_limits/{key}/used_percentage")).and_then(Value::as_f64) {
            parts.push(format!("{} {}%", windows[key], p as i64));
        }
    }
    parts.join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn args(list: &[&str]) -> HookArgs {
        parse_args(&list.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn parses_arguments() {
        let a = args(&["--hook", "--agent", "codex", "--wait"]);
        assert_eq!((a.agent.as_str(), a.agent_given, a.mode), ("codex", true, Mode::Permission));
        let b = args(&["--agent", "gemini", "PreToolUse"]);
        assert_eq!(b.event_name, "PreToolUse");
        let c = args(&["{\"x\":1}"]);
        assert_eq!(c.payload.as_deref(), Some("{\"x\":1}"));
    }

    #[test]
    fn nook_agent_field_counts_without_flag() {
        let (lines, agent, _) =
            messages(&args(&[]), r#"{"hook_event_name":"UserPromptSubmit","nook_agent":"demo","prompt":"hallo"}"#, &no_env);
        assert_eq!(agent, "demo");
        let v: Value = serde_json::from_str(&lines[0]).unwrap();
        assert_eq!(v["agent"], "demo");
        let (_, agent, _) = messages(&args(&["--agent", "codex"]), r#"{"nook_agent":"demo"}"#, &no_env);
        assert_eq!(agent, "codex", "--agent wint");
        let (_, agent, _) = messages(&args(&[]), r#"{"nook_agent":"Ongeldig!"}"#, &no_env);
        assert_eq!(agent, "claude-code");
    }

    #[test]
    fn fills_fields_of_other_agents() {
        let mut e = json!({"toolCall": {"name": "run", "args": {"CommandLine": "ls"}}, "conversationId": "c1", "workspacePaths": ["/w"]});
        fill_fields(&mut e, "antigravity", &no_env);
        assert_eq!(e["tool_name"], "run");
        assert_eq!(e["tool_input"]["command"], "ls");
        assert_eq!(e["session_id"], "c1");
        assert_eq!(e["cwd"], "/w");
        assert!(e["transcript_path"].as_str().unwrap().ends_with("transcript.jsonl"));
        let mut f = json!({"toolArgs": "{\"path\":\"a\"}", "hook_event_name": "stop", "status": "error"});
        fill_fields(&mut f, "cursor", &no_env);
        assert_eq!(f["tool_input"]["path"], "a");
        assert_eq!(f["hook_event_name"], "StopFailure");
    }

    #[test]
    fn show_step_becomes_two_events_and_permission_mode() {
        let (lines, _, _) = messages(&args(&["--agent", "amp"]), r#"{"hook_event_name":"PostToolUse","nook_show_step":true}"#, &no_env);
        assert_eq!(lines.len(), 2);
        let first: Value = serde_json::from_str(&lines[0]).unwrap();
        assert_eq!(first["event"]["hook_event_name"], "PreToolUse");
        assert!(first["event"].get("nook_show_step").is_none());
        let (_, _, mode) = messages(&args(&[]), r#"{"hook_event_name":"PermissionRequest"}"#, &no_env);
        assert_eq!(mode, Mode::Permission);
    }

    #[test]
    fn outputs() {
        assert_eq!(output("gemini", Mode::Event, ""), Some("{}".into()));
        assert_eq!(output("claude-code", Mode::Event, ""), None);
        let allow = r#"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#;
        assert_eq!(output("copilot", Mode::Permission, allow).unwrap(), r#"{"permissionDecision":"allow"}"#);
        assert_eq!(output("copilot", Mode::Permission, "").unwrap(), r#"{"permissionDecision":"ask"}"#);
        assert_eq!(
            fallback_statusline(r#"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":34.6}}}"#),
            "Opus · 5u 34%"
        );
    }
}
