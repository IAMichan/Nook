//! Lopende agents in de proceslijst (`LocalAgentScanner` op de Mac): Claude Code, Codex, Gemini CLI, Aider, OpenCode,
//! Copilot CLI, Amp, Hermes, … ook zonder hooks. Zo staan ze meteen in Nook; hooks zijn alleen nodig voor details en
//! goedkeuringen. De namen zijn die van de hub, zodat een agent met hooks niet dubbel verschijnt.
//!
//! Op Windows en Linux leest `sysinfo` de opdrachtregel, de werkmap en de omgeving van elk proces van deze gebruiker.

use std::collections::HashMap;
use std::sync::Mutex;

use regex::Regex;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

/// Een agent die als proces op deze computer draait.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DetectedAgent {
    pub pid: u32,
    pub name: String,
    pub cwd: String,
    /// `CLAUDE_CONFIG_DIR` of `CODEX_HOME` uit de omgeving: onder welk account hij draait. Leeg als onbekend.
    pub home: String,
}

struct Kind {
    name: &'static str,
    commands: &'static [&'static str],
    packages: &'static [&'static str],
}

const KINDS: &[Kind] = &[
    Kind { name: "Claude Code", commands: &["claude"], packages: &["@anthropic-ai/claude-code"] },
    Kind { name: "Codex", commands: &["codex"], packages: &["@openai/codex"] },
    Kind { name: "Gemini CLI", commands: &["gemini"], packages: &["@google/gemini-cli"] },
    Kind { name: "Aider", commands: &["aider"], packages: &[] },
    Kind { name: "OpenCode", commands: &["opencode"], packages: &["opencode-ai"] },
    Kind { name: "Copilot CLI", commands: &["copilot"], packages: &["@github/copilot"] },
    Kind { name: "Amp", commands: &["amp"], packages: &["@sourcegraph/amp"] },
    Kind { name: "Cursor", commands: &["cursor-agent"], packages: &[] },
    Kind { name: "Antigravity", commands: &["agy"], packages: &[] },
    Kind { name: "Hermes", commands: &["hermes"], packages: &["hermes-agent", "hermes_cli"] },
    Kind { name: "Muse Code", commands: &["muse"], packages: &[] },
    Kind { name: "Qwen Code", commands: &["qwen"], packages: &["@qwen-code/qwen-code"] },
];

/// De namen van de agents die de scan herkent.
pub const AGENT_NAMES: &[&str] = &[
    "Claude Code",
    "Codex",
    "Gemini CLI",
    "Aider",
    "OpenCode",
    "Copilot CLI",
    "Amp",
    "Cursor",
    "Antigravity",
    "Hermes",
    "Muse Code",
    "Qwen Code",
];

const INTERPRETERS: &[&str] = &["node", "bun", "deno", "python", "python3", "pythonw"];
const BACKGROUND_MODES: &[&str] = &["app-server", "mcp-server", "mcp", "proto", "--acp", "acp"];

/// Het programma zonder map en zonder `.exe`/`.cmd`.
fn program_name(token: &str) -> String {
    let base = token.rsplit(['/', '\\']).next().unwrap_or(token).trim_matches('"').to_lowercase();
    for ext in [".exe", ".cmd", ".bat", ".ps1", ".js", ".mjs"] {
        if let Some(stripped) = base.strip_suffix(ext) {
            return stripped.to_string();
        }
    }
    base
}

/// Herkent een agent aan zijn opdrachtregel (een regel met spaties ertussen).
pub fn identify(command: &str) -> Option<&'static str> {
    let args: Vec<String> = command.split_whitespace().map(str::to_string).collect();
    identify_args(&args)
}

/// Herkent een agent aan zijn argumenten; geen app-onderdelen en geen zoekcommando's.
pub fn identify_args(args: &[String]) -> Option<&'static str> {
    let lowered: Vec<String> = args.iter().map(|a| a.to_lowercase().replace('\\', "/")).collect();
    let lower = lowered.join(" ");
    let tokens: Vec<&str> = lowered.iter().map(String::as_str).collect();
    let first = tokens.first()?;
    if matches!(program_name(first).as_str(), "grep" | "findstr" | "rg") || tokens.contains(&"grep") {
        return None;
    }
    // Achtergronddiensten van een editor of app zijn geen sessies van de gebruiker.
    if tokens.iter().any(|t| BACKGROUND_MODES.contains(t)) {
        return None;
    }
    let program = program_name(first);
    let is_agent_command = KINDS.iter().any(|k| k.commands.contains(&program.as_str()));
    if (lower.contains(".app/contents") || lower.contains("/resources/app/")) && !is_agent_command {
        return None;
    }
    let interpreter = INTERPRETERS.contains(&program.as_str());
    let mut candidates = vec![program.clone()];
    if interpreter {
        candidates.extend(tokens.iter().skip(1).filter(|t| !t.starts_with('-')).take(3).map(|t| program_name(t)));
    }
    for kind in KINDS {
        if candidates.iter().any(|c| kind.commands.contains(&c.as_str())) {
            return Some(kind.name);
        }
        if interpreter && kind.packages.iter().any(|p| lower.contains(p)) {
            return Some(kind.name);
        }
    }
    None
}

/// Processen die Nook zelf startte (sessies in de werkruimte, het Claude Code-brein) hebben dit in hun omgeving.
/// Het zijn geen sessies van anderen: ze worden niet getoond en nooit beëindigd.
pub fn is_nook_owned(env: &HashMap<String, String>) -> bool {
    env.contains_key("NOOK_RUN_ID") || env.contains_key("NOOK_INTERNAL")
}

/// De waarde van `NAAM=` in een regel `ps -E`-uitvoer (de waarde mag spaties hebben: hij loopt tot de volgende
/// `ANDERE_NAAM=` of het eind van de regel).
pub fn env_value_in_line(name: &str, line: &str) -> Option<String> {
    let marker = Regex::new(&format!(r"(^|\s){}=", regex::escape(name))).ok()?;
    let m = marker.find(line)?;
    let rest = &line[m.end()..];
    let next = Regex::new(r"\s[A-Z][A-Z0-9_]*=").ok()?;
    let end = next.find(rest).map(|n| n.start()).unwrap_or(rest.len());
    let value = rest[..end].trim();
    (!value.is_empty()).then(|| value.to_string())
}

static SYSTEM: Mutex<Option<System>> = Mutex::new(None);

/// Scant de proceslijst. Blokkeert even (tot een paar honderd ms); draai hem op een achtergrondthread.
pub fn scan() -> Vec<DetectedAgent> {
    let me = std::process::id();
    let mut guard = SYSTEM.lock().unwrap_or_else(|e| e.into_inner());
    let system = guard.get_or_insert_with(System::new);
    let kind = ProcessRefreshKind::nothing()
        .with_cmd(UpdateKind::OnlyIfNotSet)
        .with_exe(UpdateKind::OnlyIfNotSet)
        .with_cwd(UpdateKind::Always)
        .with_environ(UpdateKind::OnlyIfNotSet);
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, kind);
    let mut found = Vec::new();
    for (pid, process) in system.processes() {
        let pid = pid.as_u32();
        // Nooks eigen hulpprocessen (codex app-server, claude -p) slaan we over.
        if pid == me || process.parent().map(|p| p.as_u32()) == Some(me) {
            continue;
        }
        let command: Vec<String> = process.cmd().iter().map(|c| c.to_string_lossy().into_owned()).collect();
        if command.is_empty() {
            continue;
        }
        let Some(name) = identify_args(&command) else { continue };
        let env: HashMap<String, String> = process
            .environ()
            .iter()
            .filter_map(|e| {
                let e = e.to_string_lossy();
                let (k, v) = e.split_once('=')?;
                Some((k.to_string(), v.to_string()))
            })
            .collect();
        if is_nook_owned(&env) {
            continue;
        }
        let home = env.get("CLAUDE_CONFIG_DIR").or_else(|| env.get("CODEX_HOME")).cloned().unwrap_or_default();
        let cwd = process.cwd().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        found.push(DetectedAgent { pid, name: name.into(), cwd, home });
    }
    found.sort_by_key(|a| a.pid);
    found
}

/// `pid` and the processes it was started from, nearest first, at most `limit`: the hook, the shell that ran it, the
/// agent, its terminal. The hook reads it about itself, since it and its shell are gone a moment later.
pub fn lineage(pid: u32, limit: usize) -> Vec<u32> {
    let mut system = System::new();
    let mut chain = Vec::new();
    let mut next = Some(pid);
    while let Some(current) = next {
        if current <= 1 || chain.len() >= limit || chain.contains(&current) {
            break;
        }
        chain.push(current);
        let target = Pid::from_u32(current);
        system.refresh_processes_specifics(ProcessesToUpdate::Some(&[target]), true, ProcessRefreshKind::nothing());
        next = system.process(target).and_then(|p| p.parent()).map(|p| p.as_u32());
    }
    chain
}

/// Beëindigt een proces netjes (zodat de agent zijn gesprek bewaart), na een paar seconden geforceerd.
pub fn terminate(pid: u32) -> bool {
    if pid <= 1 || pid == std::process::id() {
        return false;
    }
    let mut system = System::new();
    let target = Pid::from_u32(pid);
    system.refresh_processes_specifics(ProcessesToUpdate::Some(&[target]), true, ProcessRefreshKind::nothing());
    let Some(process) = system.process(target) else { return false };
    let polite = process.kill_with(sysinfo::Signal::Term).unwrap_or(false);
    if !polite {
        return process.kill();
    }
    std::thread::spawn(move || {
        for _ in 0..12 {
            std::thread::sleep(std::time::Duration::from_millis(250));
            let mut s = System::new();
            s.refresh_processes_specifics(ProcessesToUpdate::Some(&[target]), true, ProcessRefreshKind::nothing());
            if s.process(target).is_none() {
                return;
            }
        }
        let mut s = System::new();
        s.refresh_processes_specifics(ProcessesToUpdate::Some(&[target]), true, ProcessRefreshKind::nothing());
        if let Some(p) = s.process(target) {
            p.kill();
        }
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifies_agents() {
        assert_eq!(identify("/usr/local/bin/claude --resume x"), Some("Claude Code"));
        assert_eq!(identify("node /home/x/.npm/lib/node_modules/@openai/codex/bin/codex.js"), Some("Codex"));
        let win = [
            "C:\\Program Files\\nodejs\\node.exe",
            "C:\\Users\\x\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js",
        ];
        assert_eq!(identify_args(&win.map(String::from)), Some("Claude Code"));
        assert_eq!(identify("codex.exe"), Some("Codex"));
        assert_eq!(identify("codex app-server"), None, "achtergronddienst");
        assert_eq!(identify("grep claude"), None);
        assert_eq!(identify("/usr/bin/vim notes.txt"), None);
    }

    #[test]
    fn environment_value_with_spaces() {
        let line = "123 /usr/local/bin/claude TERM=xterm CLAUDE_CONFIG_DIR=/Users/x/My Projects/.claude-work HOME=/Users/x";
        assert_eq!(env_value_in_line("CLAUDE_CONFIG_DIR", line).as_deref(), Some("/Users/x/My Projects/.claude-work"));
        assert_eq!(env_value_in_line("HOME", line).as_deref(), Some("/Users/x"));
        assert_eq!(env_value_in_line("CODEX_HOME", line), None);
        assert_eq!(env_value_in_line("HOME", "1 cmd CODEX_HOME=/x"), None);
    }

    #[test]
    fn nook_owned() {
        let mut env = HashMap::new();
        assert!(!is_nook_owned(&env));
        env.insert("NOOK_RUN_ID".to_string(), "x".to_string());
        assert!(is_nook_owned(&env));
    }

    #[test]
    fn lineage_starts_with_the_process_itself() {
        let chain = lineage(std::process::id(), 6);
        assert_eq!(chain.first(), Some(&std::process::id()));
        assert!(chain.len() <= 6);
        assert!(lineage(1, 6).is_empty());
    }

    #[test]
    fn scan_runs() {
        // Geen agents in de testomgeving nodig; de scan mag niet vastlopen of panieken.
        let _ = scan();
    }
}
