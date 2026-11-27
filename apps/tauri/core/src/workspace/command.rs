//! Hoe Nook een agent start (`AgentCommand` en `LaunchSpec` op de Mac): programma, argumenten (als lijst, nooit via een
//! shell), omgeving en map. Hier draait niets; alleen de opdracht wordt opgebouwd.

use std::collections::BTreeMap;

use super::bridge::{self, BridgeLaunch};
use super::models::{ExecutionMode, PermissionPolicy, RunProvider};
use super::parsers::claude_user_message;
use crate::services::telemetry::{OtlpConfig, OtlpHeader, OtlpProtocol, OtlpSignal, BASE_ENDPOINT_ENV, HEADERS_ENV, PROTOCOL_ENV};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchSpec {
    pub executable: String,
    pub arguments: Vec<String>,
    /// Alleen wat Nook aan je omgeving toevoegt (accountmap, NOOK_RUN_ID).
    pub extra_environment: BTreeMap<String, String>,
    pub working_directory: String,
    /// Regels die meteen naar stdin gaan.
    pub initial_input: Vec<String>,
    /// Blijft stdin open (voor toestemming en onderbreken)? Anders krijgt de agent een lege invoer.
    pub keeps_input_open: bool,
}

impl LaunchSpec {
    /// Voor weergave: zonder omgeving en met lange argumenten ingekort, zodat er nooit iets gevoeligs te zien is.
    pub fn display_command(&self) -> String {
        let program = std::path::Path::new(&self.executable).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let shown = self.arguments.iter().map(|a| {
            let short = if a.chars().count() > 48 { a.chars().take(45).collect::<String>() + "…" } else { a.clone() };
            if short.contains(' ') {
                format!("\"{short}\"")
            } else {
                short
            }
        });
        std::iter::once(program).chain(shown).collect::<Vec<_>>().join(" ")
    }
}

#[derive(Debug, Clone)]
pub struct CommandInput {
    pub provider: RunProvider,
    pub executable: String,
    pub prompt: String,
    pub model: String,
    pub mode: ExecutionMode,
    pub permission: PermissionPolicy,
    pub instructions: String,
    pub working_directory: String,
    /// Om verder te gaan met een eerdere sessie van de agent.
    pub resume_session_id: Option<String>,
    /// Claude Code: verder als kopie van het gesprek (`--fork-session`); het origineel blijft onaangeroerd.
    pub fork_session: bool,
    /// Claude Code: resume at this chain entry uuid (`--resume-session-at`), used for conversation rollback.
    pub resume_at: Option<String>,
    /// Codex: pending conversation rollback (`thread/rollback` or `thread/revert`) before starting the turn.
    pub pending_rollback: Option<super::rollback::PendingRollback>,
    /// `CLAUDE_CONFIG_DIR` of `CODEX_HOME` (en een API-sleutel) van het gekozen account.
    pub account_environment: BTreeMap<String, String>,
    pub run_id: String,
    /// The Nook account (`AgentProfile.id`): Antigravity keeps a profile folder per account.
    pub profile_id: String,
    /// De werkruimte-brug als MCP-server; `None` laat de agent zoals hij is.
    pub bridge: Option<BridgeLaunch>,
    /// Redeneerniveau ("low", "medium", "high"); alleen Codex kent het.
    pub effort: Option<String>,
    /// Claude Code's `ENABLE_TOOL_SEARCH` override (`ClaudeToolSearch`, AG-32).
    pub tool_search: Option<String>,
    /// Applied token-tuning overrides for sessions Nook starts (`AgentTuning.Applied`, AG-32).
    pub tuning: super::tuning::AppliedTuning,
    /// Whether to omit Claude Code commit/PR co-author attribution via `--settings`.
    pub omit_agent_credits: bool,
}

/// Builds Claude Code's `--settings` JSON (`AgentCredits.claudeSettings` on macOS): thinking summaries, optional
/// no-attribution flags, `ENABLE_TOOL_SEARCH` environment override, and applied token-tuning overrides.
pub fn claude_settings(
    omit_agent_credits: bool,
    env: &BTreeMap<String, String>,
    extra: &serde_json::Map<String, serde_json::Value>,
) -> String {
    let mut map: BTreeMap<String, serde_json::Value> = extra.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    map.insert("showThinkingSummaries".into(), serde_json::Value::Bool(true));
    if omit_agent_credits {
        map.insert("includeCoAuthoredBy".into(), serde_json::Value::Bool(false));
        map.insert("attribution".into(), serde_json::json!({ "commit": "", "pr": "" }));
    }
    if !env.is_empty() {
        let env_obj: serde_json::Map<String, serde_json::Value> =
            env.iter().map(|(k, v)| (k.clone(), serde_json::Value::String(v.clone()))).collect();
        map.insert("env".into(), serde_json::Value::Object(env_obj));
    }
    serde_json::to_string(&map).unwrap_or_else(|_| r#"{"showThinkingSummaries":true}"#.into())
}

pub fn spec(input: &CommandInput) -> LaunchSpec {
    let mut environment = input.account_environment.clone();
    environment.insert("NOOK_RUN_ID".into(), input.run_id.clone());
    let instructions = {
        let own = input.instructions.trim().to_string();
        if input.bridge.is_some() {
            [own, bridge::INSTRUCTIONS.to_string()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n\n")
        } else {
            own
        }
    };
    let resume = input.resume_session_id.clone().filter(|s| !s.is_empty());
    match input.provider {
        RunProvider::Claude => {
            let mut settings_env = BTreeMap::new();
            if let Some(ts) = input.tool_search.as_ref().filter(|s| !s.is_empty()) {
                settings_env.insert("ENABLE_TOOL_SEARCH".into(), ts.clone());
            }
            let settings_json = claude_settings(input.omit_agent_credits, &settings_env, &input.tuning.claude_settings());
            let mut args: Vec<String> = vec![
                "-p".into(),
                "--input-format".into(),
                "stream-json".into(),
                "--output-format".into(),
                "stream-json".into(),
                "--verbose".into(),
                "--include-partial-messages".into(),
                // Toestemmingsvragen komen als control_request op stdout; Nook antwoordt via stdin.
                "--permission-prompt-tool".into(),
                "stdio".into(),
                "--permission-mode".into(),
                claude_permission_mode(input.mode, input.permission).into(),
                // Nieuwere modellen laten hun denken leeg tenzij om samenvattingen gevraagd wordt.
                "--settings".into(),
                settings_json,
            ];
            if !input.model.is_empty() {
                args.extend(["--model".into(), input.model.clone()]);
            }
            // Claude Code's reasoning effort; without it the agent keeps its own default.
            if let Some(effort) = input.effort.as_ref().filter(|e| !e.is_empty()) {
                args.extend(["--effort".into(), effort.clone()]);
            }
            if let Some(r) = &resume {
                args.extend(["--resume".into(), r.clone()]);
                if let Some(at) = input.resume_at.as_ref().filter(|s| !s.is_empty()) {
                    args.extend(["--resume-session-at".into(), at.clone()]);
                }
                if input.fork_session {
                    args.push("--fork-session".into());
                }
            }
            if let Some(b) = &input.bridge {
                args.extend(b.claude_arguments(&input.run_id));
            }
            if !instructions.is_empty() {
                args.extend(["--append-system-prompt".into(), instructions]);
            }
            LaunchSpec {
                executable: input.executable.clone(),
                arguments: args,
                extra_environment: environment,
                working_directory: input.working_directory.clone(),
                initial_input: if input.prompt.is_empty() { vec![] } else { vec![claude_user_message(&input.prompt, false)] },
                keeps_input_open: true,
            }
        }
        RunProvider::Codex => {
            let mut args: Vec<String> = vec![
                "exec".into(),
                "--json".into(),
                "--skip-git-repo-check".into(),
                "--sandbox".into(),
                codex_sandbox(input.mode, input.permission).into(),
                "--cd".into(),
                input.working_directory.clone(),
            ];
            if !input.model.is_empty() {
                args.extend(["--model".into(), input.model.clone()]);
            }
            // Gedetailleerde redeneersamenvattingen, zodat de tijdlijn laat zien hoe Codex denkt.
            args.extend(["-c".into(), "model_reasoning_summary=\"detailed\"".into()]);
            if let Some(effort) = input.effort.as_ref().filter(|e| !e.is_empty()) {
                args.extend(["-c".into(), format!("model_reasoning_effort=\"{effort}\"")]);
            }
            if let Some(b) = &input.bridge {
                args.extend(b.codex_arguments(&input.run_id));
            }
            let mut prompt = input.prompt.clone();
            // Codex exec heeft geen aparte systeemprompt: de instructies gaan voor de eerste opdracht.
            if !instructions.is_empty() && resume.is_none() {
                prompt = format!("{instructions}\n\n{prompt}");
            }
            if input.mode == ExecutionMode::Plan && resume.is_none() {
                prompt = format!("Create a plan only; do not make any changes.\n\n{prompt}");
            }
            if let Some(r) = &resume {
                args.extend(["resume".into(), r.clone()]);
            }
            // "--" zodat een opdracht die met een streepje begint nooit als optie gelezen wordt.
            args.extend(["--".into(), prompt]);
            LaunchSpec {
                executable: input.executable.clone(),
                arguments: args,
                extra_environment: environment,
                working_directory: input.working_directory.clone(),
                initial_input: vec![],
                keeps_input_open: false,
            }
        }
        _ => {
            // Gemini CLI zonder ACP (zijn headless stand); de andere ACP-agents komen hier niet (zie de manager).
            let mut args = vec![
                "--output-format".to_string(),
                "stream-json".into(),
                "--approval-mode".into(),
                gemini_approval_mode(input.mode, input.permission).into(),
            ];
            if !input.model.is_empty() {
                args.extend(["--model".into(), input.model.clone()]);
            }
            if let Some(r) = &resume {
                args.extend(["--resume".into(), r.clone()]);
            }
            let mut prompt = input.prompt.clone();
            if !instructions.is_empty() && resume.is_none() {
                prompt = format!("{instructions}\n\n{prompt}");
            }
            // Eén argument met "=", zodat een opdracht met een streepje nooit als optie gelezen wordt.
            args.push(format!("--prompt={prompt}"));
            LaunchSpec {
                executable: input.executable.clone(),
                arguments: args,
                extra_environment: environment,
                working_directory: input.working_directory.clone(),
                initial_input: vec![],
                keeps_input_open: false,
            }
        }
    }
}

pub fn gemini_approval_mode(mode: ExecutionMode, permission: PermissionPolicy) -> &'static str {
    if mode == ExecutionMode::Plan {
        return "plan";
    }
    match permission {
        PermissionPolicy::Ask => "default",
        PermissionPolicy::AcceptEdits => "auto_edit",
        PermissionPolicy::Bypass => "yolo",
    }
}

pub fn claude_permission_mode(mode: ExecutionMode, permission: PermissionPolicy) -> &'static str {
    if mode == ExecutionMode::Plan {
        return "plan";
    }
    match permission {
        PermissionPolicy::Ask => "default",
        PermissionPolicy::AcceptEdits => "acceptEdits",
        PermissionPolicy::Bypass => "bypassPermissions",
    }
}

pub fn codex_sandbox(mode: ExecutionMode, permission: PermissionPolicy) -> &'static str {
    if mode == ExecutionMode::Plan {
        return "read-only";
    }
    match permission {
        PermissionPolicy::Ask => "read-only",
        PermissionPolicy::AcceptEdits => "workspace-write",
        PermissionPolicy::Bypass => "danger-full-access",
    }
}

/// De omgeving van het proces: je eigen omgeving, met de map van het programma en de gangbare plekken van Node en
/// agents voorin `PATH` (ook als Nook vanuit het startmenu start), zonder `NOOK_INTERNAL`, plus wat Nook toevoegt.
pub fn environment(base: &BTreeMap<String, String>, executable: &str, extra: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut env = base.clone();
    let separator = if cfg!(windows) { ";" } else { ":" };
    let home = env.get("HOME").or_else(|| env.get("USERPROFILE")).cloned().unwrap_or_default();
    let dir = std::path::Path::new(executable).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let mut paths = vec![dir];
    if cfg!(windows) {
        if let Some(appdata) = env.get("APPDATA") {
            paths.push(format!("{appdata}\\npm"));
        }
        paths.push(format!("{home}\\.local\\bin"));
    } else {
        paths.extend([
            "/usr/local/bin".to_string(),
            format!("{home}/.local/bin"),
            format!("{home}/.bun/bin"),
            format!("{home}/.volta/bin"),
        ]);
    }
    let path_key = env.keys().find(|k| k.eq_ignore_ascii_case("PATH")).cloned().unwrap_or_else(|| "PATH".into());
    let current = env.get(&path_key).cloned().unwrap_or_else(|| if cfg!(windows) { String::new() } else { "/usr/bin:/bin".into() });
    paths.push(current);
    env.insert(path_key, paths.into_iter().filter(|p| !p.is_empty()).collect::<Vec<_>>().join(separator));
    // Nooks eigen denken via Claude Code zet dit; een sessie in de werkruimte is een echte agentsessie.
    env.remove("NOOK_INTERNAL");
    for (k, v) in extra {
        env.insert(k.clone(), v.clone());
    }
    env
}

// MARK: AgentTelemetry (AG-33 / SV-05)

/// What a coding-agent launch gains when OpenTelemetry export is enabled (`AgentTelemetry.Launch` on macOS):
/// environment variables (standard `OTEL_EXPORTER_OTLP_*` plus agent-specific switches) and, for Codex, `-c` TOML
/// overrides.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TelemetryLaunch {
    pub environment: BTreeMap<String, String>,
    pub arguments: Vec<String>,
}

/// Signals an agent exports natively once told the receiver (`AgentTelemetry.signals(_:)` on macOS).
/// Empty means the agent has no native OTLP export of its own; it still gets the standard `OTEL_EXPORTER_OTLP_*`
/// variables for extensions or SDKs inside it.
pub fn telemetry_signals(provider: RunProvider) -> &'static [OtlpSignal] {
    match provider {
        RunProvider::Claude | RunProvider::Codex | RunProvider::Gemini => &[OtlpSignal::Traces, OtlpSignal::Metrics, OtlpSignal::Logs],
        RunProvider::Opencode => &[OtlpSignal::Traces, OtlpSignal::Logs],
        RunProvider::Grok => &[OtlpSignal::Metrics, OtlpSignal::Logs],
        RunProvider::Cursor | RunProvider::Antigravity | RunProvider::Pi => &[],
    }
}

/// Standard OpenTelemetry variables: each configured signal's endpoint with its exporter set to `otlp`, unconfigured
/// signals set to `none`, the shared base endpoint when all configured signals share one, protocol, and headers.
pub fn standard_telemetry_environment(config: &OtlpConfig) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    for signal in OtlpSignal::ALL {
        if let Some(url) = config.endpoint(signal) {
            env.insert(signal.endpoint_env().into(), url.to_string());
            env.insert(signal.exporter_env().into(), "otlp".into());
        } else {
            env.insert(signal.exporter_env().into(), "none".into());
        }
    }
    if let Some(base) = config.base_endpoint() {
        env.insert(BASE_ENDPOINT_ENV.into(), base);
    }
    env.insert(PROTOCOL_ENV.into(), config.protocol.as_str().into());
    if !config.headers.is_empty() {
        env.insert(HEADERS_ENV.into(), config.headers_variable());
    }
    env
}

/// A TOML basic string with quotes, backslashes, and control characters escaped so a header value cannot break the
/// inline table passed to `codex -c`.
pub fn toml_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || (c as u32) == 0x7F => {
                out.push_str(&format!("\\u{:04X}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Codex `[otel]` overrides (`-c otel.exporter={otlp-http={...}}`), one per configured signal.
pub fn codex_telemetry_arguments(config: &OtlpConfig) -> Vec<String> {
    let keys =
        [(OtlpSignal::Logs, "otel.exporter"), (OtlpSignal::Traces, "otel.trace_exporter"), (OtlpSignal::Metrics, "otel.metrics_exporter")];
    let wire = if config.protocol == OtlpProtocol::HttpJson { "json" } else { "binary" };
    let headers =
        config.headers.iter().map(|h| format!("{}={}", toml_string(&h.name), toml_string(&h.value))).collect::<Vec<_>>().join(",");
    let mut args = Vec::new();
    for (signal, key) in keys {
        let Some(url) = config.endpoint(signal) else { continue };
        let table = format!("{{otlp-http={{endpoint={},protocol=\"{wire}\",headers={{{headers}}}}}}}", toml_string(url));
        args.push("-c".into());
        args.push(format!("{key}={table}"));
    }
    args
}

fn headers_json_object(headers: &[OtlpHeader]) -> String {
    let mut map = BTreeMap::new();
    for h in headers {
        map.insert(h.name.as_str(), h.value.as_str());
    }
    serde_json::to_string(&map).unwrap_or_else(|_| "{}".into())
}

/// Computes the telemetry environment variables and arguments for `provider` from the resolved `OtlpConfig`.
/// Returns an empty `TelemetryLaunch` whenever export is off or `OTEL_SDK_DISABLED=true`.
pub fn telemetry_launch(provider: RunProvider, config: &OtlpConfig) -> TelemetryLaunch {
    if !config.is_exporting() {
        return TelemetryLaunch::default();
    }
    let mut launch = TelemetryLaunch { environment: standard_telemetry_environment(config), arguments: Vec::new() };
    match provider {
        RunProvider::Claude => {
            launch.environment.insert("CLAUDE_CODE_ENABLE_TELEMETRY".into(), "1".into());
            if config.endpoint(OtlpSignal::Traces).is_some() {
                launch.environment.insert("CLAUDE_CODE_ENHANCED_TELEMETRY_BETA".into(), "1".into());
            }
        }
        RunProvider::Codex => {
            launch.arguments = codex_telemetry_arguments(config);
        }
        RunProvider::Gemini => {
            if let Some(base) = config.base_endpoint() {
                launch.environment.insert("GEMINI_TELEMETRY_ENABLED".into(), "true".into());
                launch.environment.insert("GEMINI_TELEMETRY_TARGET".into(), "local".into());
                launch.environment.insert("GEMINI_TELEMETRY_OTLP_ENDPOINT".into(), base);
                launch.environment.insert("GEMINI_TELEMETRY_OTLP_PROTOCOL".into(), "http".into());
                if config.endpoint(OtlpSignal::Traces).is_some() {
                    launch.environment.insert("GEMINI_TELEMETRY_TRACES_ENABLED".into(), "true".into());
                }
                if !config.headers.is_empty() {
                    launch.environment.insert("GEMINI_TELEMETRY_OTLP_HEADERS".into(), headers_json_object(&config.headers));
                }
            }
        }
        RunProvider::Grok => {
            if config.endpoint(OtlpSignal::Metrics).is_some() || config.endpoint(OtlpSignal::Logs).is_some() {
                launch.environment.insert("GROK_EXTERNAL_OTEL".into(), "1".into());
            }
        }
        RunProvider::Opencode | RunProvider::Cursor | RunProvider::Antigravity | RunProvider::Pi => {}
    }
    launch
}

/// Returns `spec` with agent telemetry applied. Variables already present in `spec.extra_environment` are preserved.
/// Codex's `-c` overrides are inserted right after its subcommand (`exec` or `app-server`).
pub fn apply_telemetry(provider: RunProvider, config: &OtlpConfig, mut spec: LaunchSpec) -> LaunchSpec {
    let launch = telemetry_launch(provider, config);
    if launch.environment.is_empty() && launch.arguments.is_empty() {
        return spec;
    }
    for (k, v) in launch.environment {
        spec.extra_environment.entry(k).or_insert(v);
    }
    if !launch.arguments.is_empty() {
        let at = if matches!(spec.arguments.first().map(String::as_str), Some("exec" | "app-server")) { 1 } else { 0 };
        spec.arguments.splice(at..at, launch.arguments);
    }
    spec
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(provider: RunProvider, model: &str, resume: Option<&str>, instructions: &str) -> CommandInput {
        CommandInput {
            provider,
            executable: format!("/usr/local/bin/{}", provider.id()),
            prompt: "-doe iets".into(),
            model: model.into(),
            mode: ExecutionMode::Agent,
            permission: PermissionPolicy::AcceptEdits,
            instructions: instructions.into(),
            working_directory: "/tmp/w".into(),
            resume_session_id: resume.map(str::to_string),
            fork_session: false,
            resume_at: None,
            pending_rollback: None,
            account_environment: [("CLAUDE_CONFIG_DIR".to_string(), "/home/x/.claude-werk".to_string())].into_iter().collect(),
            run_id: "run-1".into(),
            profile_id: "default".into(),
            bridge: None,
            effort: None,
            tool_search: None,
            tuning: Default::default(),
            omit_agent_credits: false,
        }
    }

    fn value<'a>(flag: &str, args: &'a [String]) -> Option<&'a str> {
        args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).map(String::as_str)
    }

    #[test]
    fn claude_settings_carry_env_credits_and_tuning() {
        let mut i = input(RunProvider::Claude, "", None, "");
        let bare = spec(&i).arguments;
        let bare_json: serde_json::Value = serde_json::from_str(value("--settings", &bare).unwrap()).unwrap();
        assert_eq!(bare_json.get("showThinkingSummaries").and_then(|v| v.as_bool()), Some(true));
        assert!(bare_json.get("env").is_none());

        i.tool_search = Some("true".into());
        i.omit_agent_credits = true;
        i.tuning.claude_plugins = vec!["sales@inline".into()];
        i.tuning.claude_no_connectors = true;
        let lean = spec(&i).arguments;
        let lean_json: serde_json::Value = serde_json::from_str(value("--settings", &lean).unwrap()).unwrap();
        assert_eq!(lean_json.pointer("/env/ENABLE_TOOL_SEARCH").and_then(|v| v.as_str()), Some("true"));
        assert_eq!(lean_json.get("includeCoAuthoredBy").and_then(|v| v.as_bool()), Some(false));
        assert_eq!(lean_json.pointer("/attribution/commit").and_then(|v| v.as_str()), Some(""));
        assert_eq!(lean_json.pointer("/enabledPlugins/sales@inline").and_then(|v| v.as_bool()), Some(false));
        assert_eq!(lean_json.get("disableClaudeAiConnectors").and_then(|v| v.as_bool()), Some(true));
    }

    #[test]
    fn claude_resume_session_at_and_fork() {
        let mut i = input(RunProvider::Claude, "", Some("s1"), "");
        i.fork_session = true;
        i.resume_at = Some("u1".into());
        let a = spec(&i).arguments;
        assert_eq!(value("--resume", &a), Some("s1"));
        assert_eq!(value("--resume-session-at", &a), Some("u1"));
        assert!(a.contains(&"--fork-session".to_string()));
    }

    #[test]
    fn claude_arguments() {
        let s = spec(&input(RunProvider::Claude, "opus", Some("sess-1"), "Gebruik tabs"));
        let a = &s.arguments;
        assert_eq!(a[0], "-p");
        assert!(a.contains(&"--verbose".to_string()));
        assert_eq!(value("--input-format", a), Some("stream-json"));
        assert_eq!(value("--output-format", a), Some("stream-json"));
        assert_eq!(value("--permission-prompt-tool", a), Some("stdio"));
        assert_eq!(value("--permission-mode", a), Some("acceptEdits"));
        assert_eq!(value("--model", a), Some("opus"));
        assert_eq!(value("--resume", a), Some("sess-1"));
        assert_eq!(value("--append-system-prompt", a), Some("Gebruik tabs"));
        assert!(!a.contains(&"-doe iets".to_string()), "de opdracht gaat via stdin");
        assert!(s.keeps_input_open);
        assert_eq!(s.initial_input.len(), 1);
        assert_eq!(s.extra_environment.get("NOOK_RUN_ID").map(String::as_str), Some("run-1"));
        assert_eq!(s.extra_environment.get("CLAUDE_CONFIG_DIR").map(String::as_str), Some("/home/x/.claude-werk"));
        assert!(s.display_command().starts_with("claude -p"));
    }

    #[test]
    fn claude_fork_only_with_resume() {
        let mut forked = input(RunProvider::Claude, "", Some("sess-1"), "");
        forked.fork_session = true;
        assert!(spec(&forked).arguments.contains(&"--fork-session".to_string()));
        assert!(!spec(&input(RunProvider::Claude, "", Some("sess-1"), "")).arguments.contains(&"--fork-session".to_string()));
        let mut fresh = input(RunProvider::Claude, "", None, "");
        fresh.fork_session = true;
        assert!(!spec(&fresh).arguments.contains(&"--fork-session".to_string()));
        assert_eq!(claude_permission_mode(ExecutionMode::Plan, PermissionPolicy::Bypass), "plan");
        assert_eq!(claude_permission_mode(ExecutionMode::Agent, PermissionPolicy::Ask), "default");
        assert_eq!(claude_permission_mode(ExecutionMode::Agent, PermissionPolicy::Bypass), "bypassPermissions");
        assert_eq!(value("--model", &spec(&input(RunProvider::Claude, "", None, "")).arguments), None);
        assert_eq!(value("--effort", &spec(&input(RunProvider::Claude, "", None, "")).arguments), None);
        let mut high = input(RunProvider::Claude, "", None, "");
        high.effort = Some("high".into());
        assert_eq!(value("--effort", &spec(&high).arguments), Some("high"));
    }

    #[test]
    fn codex_arguments() {
        let s = spec(&input(RunProvider::Codex, "gpt-5-codex", Some("th-1"), ""));
        let a = &s.arguments;
        assert_eq!(a[0], "exec");
        assert!(a.contains(&"--json".to_string()));
        assert_eq!(value("--sandbox", a), Some("workspace-write"));
        assert_eq!(value("--model", a), Some("gpt-5-codex"));
        assert_eq!(value("resume", a), Some("th-1"));
        assert_eq!(&a[a.len() - 2..], &["--".to_string(), "-doe iets".to_string()]);
        assert!(!s.keeps_input_open);
        assert_eq!(codex_sandbox(ExecutionMode::Plan, PermissionPolicy::Bypass), "read-only");
        assert_eq!(codex_sandbox(ExecutionMode::Agent, PermissionPolicy::Bypass), "danger-full-access");
    }

    #[test]
    fn bridge_goes_on_the_command_line() {
        let mut i = input(RunProvider::Claude, "", None, "");
        i.bridge = Some(BridgeLaunch { script: "/h/.nook/nook-mcp".into() });
        let a = spec(&i).arguments;
        assert!(value("--mcp-config", &a).unwrap().contains("nook-mcp"));
        assert!(value("--append-system-prompt", &a).unwrap().contains("running inside Nook"));
    }

    #[test]
    fn environment_paths_and_internal() {
        let base: BTreeMap<String, String> =
            [("PATH", "/usr/bin"), ("HOME", "/home/x"), ("NOOK_INTERNAL", "1")].into_iter().map(|(k, v)| (k.into(), v.into())).collect();
        let extra = [("NOOK_RUN_ID".to_string(), "r".to_string())].into_iter().collect();
        let env = environment(&base, "/opt/tools/bin/claude", &extra);
        if !cfg!(windows) {
            assert!(env["PATH"].starts_with("/opt/tools/bin:"));
            assert!(env["PATH"].ends_with(":/usr/bin"));
        }
        assert!(!env.contains_key("NOOK_INTERNAL"));
        assert_eq!(env["NOOK_RUN_ID"], "r");
    }

    #[test]
    fn display_hides_environment() {
        let mut i = input(RunProvider::Claude, "", None, "");
        i.account_environment.insert("ANTHROPIC_API_KEY".into(), "sk-ant-geheim".into());
        let s = spec(&i);
        assert!(!s.display_command().contains("sk-ant"));
        assert!(!s.arguments.join("").contains("sk-ant"));
    }

    fn otlp_config(traces: bool, metrics: bool, logs: bool, protocol: OtlpProtocol, headers: Vec<OtlpHeader>) -> OtlpConfig {
        let mut endpoints = BTreeMap::new();
        if traces {
            endpoints.insert(OtlpSignal::Traces, "http://localhost:4318/v1/traces".into());
        }
        if metrics {
            endpoints.insert(OtlpSignal::Metrics, "http://localhost:4318/v1/metrics".into());
        }
        if logs {
            endpoints.insert(OtlpSignal::Logs, "http://localhost:4318/v1/logs".into());
        }
        OtlpConfig { enabled: true, endpoints, headers, protocol, ..OtlpConfig::default() }
    }

    #[test]
    fn telemetry_disabled_or_empty_is_noop() {
        let empty = OtlpConfig::default();
        assert_eq!(telemetry_launch(RunProvider::Claude, &empty), TelemetryLaunch::default());

        let mut disabled = otlp_config(true, true, true, OtlpProtocol::HttpProtobuf, vec![]);
        disabled.sdk_disabled = true;
        assert_eq!(telemetry_launch(RunProvider::Claude, &disabled), TelemetryLaunch::default());

        let base_spec = spec(&input(RunProvider::Claude, "", None, ""));
        assert_eq!(apply_telemetry(RunProvider::Claude, &disabled, base_spec.clone()), base_spec);
    }

    #[test]
    fn telemetry_claude_sets_standard_and_native_env_and_preserves_existing() {
        let cfg = otlp_config(true, false, true, OtlpProtocol::HttpJson, vec![OtlpHeader::new("Authorization", "Bearer tok")]);
        let mut s = spec(&input(RunProvider::Claude, "", None, ""));
        s.extra_environment.insert("OTEL_TRACES_EXPORTER".into(), "custom".into());
        let out = apply_telemetry(RunProvider::Claude, &cfg, s);

        assert_eq!(out.extra_environment.get("CLAUDE_CODE_ENABLE_TELEMETRY").map(String::as_str), Some("1"));
        assert_eq!(out.extra_environment.get("CLAUDE_CODE_ENHANCED_TELEMETRY_BETA").map(String::as_str), Some("1"));
        assert_eq!(
            out.extra_environment.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT").map(String::as_str),
            Some("http://localhost:4318/v1/traces")
        );
        assert_eq!(out.extra_environment.get("OTEL_TRACES_EXPORTER").map(String::as_str), Some("custom"));
        assert_eq!(out.extra_environment.get("OTEL_METRICS_EXPORTER").map(String::as_str), Some("none"));
        assert_eq!(out.extra_environment.get("OTEL_LOGS_EXPORTER").map(String::as_str), Some("otlp"));
        assert_eq!(out.extra_environment.get(BASE_ENDPOINT_ENV).map(String::as_str), Some("http://localhost:4318"));
        assert_eq!(out.extra_environment.get(PROTOCOL_ENV).map(String::as_str), Some("http/json"));
        assert!(out.extra_environment.contains_key(HEADERS_ENV));
    }

    #[test]
    fn telemetry_codex_inserts_escaped_toml_overrides_after_subcommand() {
        let cfg = otlp_config(true, false, true, OtlpProtocol::HttpJson, vec![OtlpHeader::new("X-Key", "a\"b\\c\n")]);
        assert_eq!(toml_string("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"");

        let s = spec(&input(RunProvider::Codex, "", None, ""));
        let out = apply_telemetry(RunProvider::Codex, &cfg, s);
        assert_eq!(out.arguments[0], "exec");
        assert_eq!(out.arguments[1], "-c");
        assert!(out.arguments[2].starts_with("otel.exporter={otlp-http={endpoint=\"http://localhost:4318/v1/logs\",protocol=\"json\""));
        assert!(out.arguments[2].contains("\\\"b\\\\c\\n"));
        assert_eq!(out.arguments[3], "-c");
        assert!(out.arguments[4].starts_with("otel.trace_exporter="));
    }

    #[test]
    fn telemetry_gemini_grok_and_other_providers() {
        let cfg = otlp_config(true, true, false, OtlpProtocol::HttpProtobuf, vec![OtlpHeader::new("X-Token", "secret")]);
        let gemini = telemetry_launch(RunProvider::Gemini, &cfg);
        assert_eq!(gemini.environment.get("GEMINI_TELEMETRY_ENABLED").map(String::as_str), Some("true"));
        assert_eq!(gemini.environment.get("GEMINI_TELEMETRY_OTLP_ENDPOINT").map(String::as_str), Some("http://localhost:4318"));
        assert_eq!(gemini.environment.get("GEMINI_TELEMETRY_TRACES_ENABLED").map(String::as_str), Some("true"));
        assert_eq!(gemini.environment.get("GEMINI_TELEMETRY_OTLP_HEADERS").map(String::as_str), Some("{\"X-Token\":\"secret\"}"));

        let grok = telemetry_launch(RunProvider::Grok, &cfg);
        assert_eq!(grok.environment.get("GROK_EXTERNAL_OTEL").map(String::as_str), Some("1"));

        let traces_only = otlp_config(true, false, false, OtlpProtocol::HttpProtobuf, vec![]);
        let grok_traces = telemetry_launch(RunProvider::Grok, &traces_only);
        assert!(!grok_traces.environment.contains_key("GROK_EXTERNAL_OTEL"));

        assert_eq!(telemetry_signals(RunProvider::Claude).len(), 3);
        assert_eq!(telemetry_signals(RunProvider::Opencode), &[OtlpSignal::Traces, OtlpSignal::Logs]);
        assert_eq!(telemetry_signals(RunProvider::Grok), &[OtlpSignal::Metrics, OtlpSignal::Logs]);
        assert!(telemetry_signals(RunProvider::Cursor).is_empty());
        assert!(telemetry_signals(RunProvider::Antigravity).is_empty());
    }
}
