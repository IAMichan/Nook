//! Hoe Nook een agent start (`AgentCommand` en `LaunchSpec` op de Mac): programma, argumenten (als lijst, nooit via een
//! shell), omgeving en map. Hier draait niets; alleen de opdracht wordt opgebouwd.

use std::collections::BTreeMap;

use super::bridge::{self, BridgeLaunch};
use super::models::{ExecutionMode, PermissionPolicy, RunProvider};
use super::parsers::claude_user_message;

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
    /// `CLAUDE_CONFIG_DIR` of `CODEX_HOME` (en een API-sleutel) van het gekozen account.
    pub account_environment: BTreeMap<String, String>,
    pub run_id: String,
    /// De werkruimte-brug als MCP-server; `None` laat de agent zoals hij is.
    pub bridge: Option<BridgeLaunch>,
    /// Redeneerniveau ("low", "medium", "high"); alleen Codex kent het.
    pub effort: Option<String>,
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
            let mut args: Vec<String> = [
                "-p",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
                // Toestemmingsvragen komen als control_request op stdout; Nook antwoordt via stdin.
                "--permission-prompt-tool",
                "stdio",
                "--permission-mode",
                claude_permission_mode(input.mode, input.permission),
                // Nieuwere modellen laten hun denken leeg tenzij om samenvattingen gevraagd wordt.
                "--settings",
                r#"{"showThinkingSummaries":true}"#,
            ]
            .iter()
            .map(|s| s.to_string())
            .collect();
            if !input.model.is_empty() {
                args.extend(["--model".into(), input.model.clone()]);
            }
            if let Some(r) = &resume {
                args.extend(["--resume".into(), r.clone()]);
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
            account_environment: [("CLAUDE_CONFIG_DIR".to_string(), "/home/x/.claude-werk".to_string())].into_iter().collect(),
            run_id: "run-1".into(),
            bridge: None,
            effort: None,
        }
    }

    fn value<'a>(flag: &str, args: &'a [String]) -> Option<&'a str> {
        args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).map(String::as_str)
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
}
