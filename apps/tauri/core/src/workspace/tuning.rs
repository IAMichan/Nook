//! Settings › Usage & costs › Tokens (`AgentTuning` on macOS): scans each coding agent's configuration files (and
//! Claude Code's transcripts from the last 30 days) for unused plugins, connectors, MCP servers, long personal
//! instructions, and disabled auto-compact.
//!
//! Nook only reads the agents' files and never modifies them. Where Nook can, it applies a suggestion to the sessions
//! it starts itself (Claude Code, through `--settings`); every suggestion also gives the exact setting for the user's
//! own configuration.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::models::RunProvider;

/// Not used for this many days counts as unused.
pub const UNUSED_DAYS: i64 = 30;
/// A personal instruction file past this many characters is worth a look.
pub const LONG_INSTRUCTIONS_CHARS: usize = 8_000;

/// What kind of overhead a suggestion describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TuningKind {
    /// Plugins whose skills and agents are listed in every request, unused for `UNUSED_DAYS`.
    UnusedPlugins,
    /// Cloud connectors (claude.ai) loaded into every session.
    CloudConnectors,
    /// MCP servers whose tools load into every session, unused for `UNUSED_DAYS`.
    UnusedServers,
    /// MCP servers whose tools load into every session; the agent keeps no record of their use.
    Servers,
    /// A personal instruction file that goes with every session and has grown long.
    LongInstructions,
    /// The agent no longer summarizes a full conversation by itself.
    AutoCompactOff,
}

impl TuningKind {
    pub fn key(self) -> &'static str {
        match self {
            Self::UnusedPlugins => "unusedPlugins",
            Self::CloudConnectors => "cloudConnectors",
            Self::UnusedServers => "unusedServers",
            Self::Servers => "servers",
            Self::LongInstructions => "longInstructions",
            Self::AutoCompactOff => "autoCompactOff",
        }
    }
}

/// One token-saving suggestion for one coding agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TuningAdvice {
    pub id: String,
    pub provider: RunProvider,
    pub kind: TuningKind,
    /// What the suggestion is about: plugin ids, server or connector names, or a file path.
    pub items: Vec<String>,
    /// Of the same kind, the ones in use that stay (e.g. a claude.ai connector you use).
    #[serde(default)]
    pub kept: Vec<String>,
    /// Characters this adds to every request, when Nook can tell.
    #[serde(default)]
    pub characters: Option<usize>,
    /// Estimated tokens per request (~4 characters per token).
    #[serde(default)]
    pub tokens: Option<usize>,
    /// Where the setting goes: a file path or a URL.
    pub location: String,
    /// The setting to put there, ready to paste; `None` when it is a step in the agent's own settings.
    #[serde(default)]
    pub snippet: Option<String>,
    /// Whether Nook can apply this suggestion to sessions it starts itself (`AppliedTuning`).
    #[serde(default)]
    pub applies_in_nook: bool,
}

impl TuningAdvice {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        provider: RunProvider,
        kind: TuningKind,
        items: Vec<String>,
        kept: Vec<String>,
        characters: Option<usize>,
        location: impl Into<String>,
        snippet: Option<String>,
        applies_in_nook: bool,
    ) -> Self {
        let id = format!("{}.{}.{}", provider.id(), kind.key(), items.join(","));
        let tokens = characters.map(|c| (c / 4).max(1));
        Self { id, provider, kind, items, kept, characters, tokens, location: location.into(), snippet, applies_in_nook }
    }
}

/// Which suggestions you applied to the sessions Nook starts (`AgentTuning.Applied` on macOS).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppliedTuning {
    /// Claude Code plugins left out (`enabledPlugins` set to `false`).
    pub claude_plugins: Vec<String>,
    /// Claude Code without claude.ai connectors (`disableClaudeAiConnectors`).
    pub claude_no_connectors: bool,
}

impl AppliedTuning {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("agent-tuning.json")
    }

    pub fn load_from(file: &Path) -> Self {
        std::fs::read(file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save_to(&self, file: &Path) {
        if let Ok(bytes) = serde_json::to_vec_pretty(self) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    pub fn is_empty(&self) -> bool {
        self.claude_plugins.is_empty() && !self.claude_no_connectors
    }

    /// Entries merged into Claude Code's `--settings` JSON.
    pub fn claude_settings(&self) -> Map<String, Value> {
        let mut settings = Map::new();
        if !self.claude_plugins.is_empty() {
            let mut map = Map::new();
            let mut sorted = self.claude_plugins.clone();
            sorted.sort();
            sorted.dedup();
            for id in sorted {
                map.insert(id, Value::Bool(false));
            }
            settings.insert("enabledPlugins".into(), Value::Object(map));
        }
        if self.claude_no_connectors {
            settings.insert("disableClaudeAiConnectors".into(), Value::Bool(true));
        }
        settings
    }

    pub fn is_applied(&self, advice: &TuningAdvice) -> bool {
        match advice.kind {
            TuningKind::UnusedPlugins => !advice.items.is_empty() && advice.items.iter().all(|id| self.claude_plugins.contains(id)),
            TuningKind::CloudConnectors => self.claude_no_connectors,
            TuningKind::UnusedServers | TuningKind::Servers | TuningKind::LongInstructions | TuningKind::AutoCompactOff => false,
        }
    }

    pub fn set(&mut self, advice: &TuningAdvice, on: bool) {
        match advice.kind {
            TuningKind::UnusedPlugins => {
                self.claude_plugins.retain(|id| !advice.items.contains(id));
                if on {
                    self.claude_plugins.extend(advice.items.iter().cloned());
                }
            }
            TuningKind::CloudConnectors => {
                self.claude_no_connectors = on;
            }
            TuningKind::UnusedServers | TuningKind::Servers | TuningKind::LongInstructions | TuningKind::AutoCompactOff => {}
        }
    }
}

/// `advice` plus rows for what you applied earlier and no scan suggests any more, so it can always be undone.
pub fn with_applied(mut advice: Vec<TuningAdvice>, applied: &AppliedTuning, settings_file: &str) -> Vec<TuningAdvice> {
    let suggested: HashSet<String> =
        advice.iter().filter(|a| a.kind == TuningKind::UnusedPlugins).flat_map(|a| a.items.iter().cloned()).collect();
    let leftover: Vec<String> = applied.claude_plugins.iter().filter(|id| !suggested.contains(*id)).cloned().collect();
    if !leftover.is_empty() {
        advice.push(TuningAdvice::new(RunProvider::Claude, TuningKind::UnusedPlugins, leftover, vec![], None, settings_file, None, true));
    }
    if applied.claude_no_connectors && !advice.iter().any(|a| a.kind == TuningKind::CloudConnectors && a.applies_in_nook) {
        advice.retain(|a| a.kind != TuningKind::CloudConnectors);
        advice.push(TuningAdvice::new(RunProvider::Claude, TuningKind::CloudConnectors, vec![], vec![], None, settings_file, None, true));
    }
    advice
}

/// Every suggestion for the agents configured under `home`. Reads Claude Code transcripts of the last 30 days, so run
/// off the UI/runtime thread.
pub fn scan(home: &Path, now: DateTime<Utc>) -> Vec<TuningAdvice> {
    let mut advice = Vec::new();
    for provider in RunProvider::ALL {
        match provider {
            RunProvider::Claude => advice.extend(claude(home, now)),
            RunProvider::Codex => advice.extend(codex(home)),
            RunProvider::Gemini => advice.extend(gemini(home)),
            RunProvider::Opencode => advice.extend(opencode(home)),
            RunProvider::Cursor => advice.extend(json_servers(RunProvider::Cursor, &home.join(".cursor/mcp.json"))),
            RunProvider::Antigravity => {
                advice.extend(json_servers(RunProvider::Antigravity, &home.join(".gemini/antigravity/mcp_config.json")));
            }
            RunProvider::Grok | RunProvider::Acp => {}
        }
    }
    advice
}

// MARK: Claude Code

pub fn claude(home: &Path, now: DateTime<Utc>) -> Vec<TuningAdvice> {
    let state_file = home.join(".claude.json");
    let state = read_json(&state_file);
    let settings_file = home.join(".claude/settings.json");
    let settings = read_json(&settings_file);
    let since = now - Duration::days(UNUSED_DAYS);
    let used_servers = TranscriptToolUse::servers_in_projects(&home.join(".claude/projects"), since);
    let mut advice = Vec::new();

    // Plugins: those loaded now, minus those used in the last 30 days.
    let plugins = ClaudePlugins::loaded(home, settings.as_ref());
    let plugin_usage = state.as_ref().and_then(|v| v.get("pluginUsage"));
    let skill_usage = state.as_ref().and_then(|v| v.get("skillUsage"));
    let unused: Vec<ClaudePlugin> = plugins.into_iter().filter(|p| !ClaudePlugins::used(&p.id, plugin_usage, skill_usage, since)).collect();
    if !unused.is_empty() {
        let mut ids: Vec<String> = unused.iter().map(|p| p.id.clone()).collect();
        ids.sort();
        let chars: usize = unused.iter().map(|p| p.characters).sum();
        let mut enabled_map = Map::new();
        for id in &ids {
            enabled_map.insert(id.clone(), Value::Bool(false));
        }
        let mut root = Map::new();
        root.insert("enabledPlugins".into(), Value::Object(enabled_map));
        advice.push(TuningAdvice::new(
            RunProvider::Claude,
            TuningKind::UnusedPlugins,
            ids,
            vec![],
            Some(chars),
            settings_file.to_string_lossy().into_owned(),
            Some(json_snippet(&Value::Object(root))),
            true,
        ));
    }

    // claude.ai connectors: one switch disables all of them, so only `applies_in_nook` when none is used.
    let connectors: Vec<String> = state
        .as_ref()
        .and_then(|v| v.get("claudeAiMcpEverConnected"))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let connectors_disabled = settings.as_ref().and_then(|v| v.get("disableClaudeAiConnectors")).and_then(Value::as_bool) == Some(true);
    if !connectors.is_empty() && !connectors_disabled {
        let used: Vec<String> =
            connectors.iter().filter(|c| used_servers.contains_key(&TranscriptToolUse::server_key(c))).cloned().collect();
        let idle: Vec<String> = connectors.iter().filter(|c| !used.contains(*c)).cloned().collect();
        if !idle.is_empty() {
            if used.is_empty() {
                let snippet = json_snippet(&serde_json::json!({ "disableClaudeAiConnectors": true }));
                advice.push(TuningAdvice::new(
                    RunProvider::Claude,
                    TuningKind::CloudConnectors,
                    idle,
                    vec![],
                    None,
                    settings_file.to_string_lossy().into_owned(),
                    Some(snippet),
                    true,
                ));
            } else {
                advice.push(TuningAdvice::new(
                    RunProvider::Claude,
                    TuningKind::CloudConnectors,
                    idle,
                    used,
                    None,
                    "https://claude.ai/settings/connectors",
                    None,
                    false,
                ));
            }
        }
    }

    // User-scoped MCP servers in ~/.claude.json.
    let mut servers: Vec<String> = state
        .as_ref()
        .and_then(|v| v.get("mcpServers"))
        .and_then(Value::as_object)
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    servers.sort();
    let idle_servers: Vec<String> = servers.into_iter().filter(|s| !used_servers.contains_key(s)).collect();
    if !idle_servers.is_empty() {
        let snippet = idle_servers.iter().map(|s| format!("claude mcp remove {s} -s user")).collect::<Vec<_>>().join("\n");
        advice.push(TuningAdvice::new(
            RunProvider::Claude,
            TuningKind::UnusedServers,
            idle_servers,
            vec![],
            None,
            state_file.to_string_lossy().into_owned(),
            Some(snippet),
            false,
        ));
    }

    if state.as_ref().and_then(|v| v.get("autoCompactEnabled")).and_then(Value::as_bool) == Some(false) {
        advice.push(TuningAdvice::new(
            RunProvider::Claude,
            TuningKind::AutoCompactOff,
            vec![],
            vec![],
            None,
            state_file.to_string_lossy().into_owned(),
            Some(json_snippet(&serde_json::json!({ "autoCompactEnabled": true }))),
            false,
        ));
    }

    advice.extend(instructions(RunProvider::Claude, &home.join(".claude/CLAUDE.md")));
    advice
}

// MARK: Codex

pub fn codex(home: &Path) -> Vec<TuningAdvice> {
    let file = home.join(".codex/config.toml");
    let mut advice = Vec::new();
    if let Ok(text) = std::fs::read_to_string(&file) {
        let on = CodexConfig::enabled_servers(&text);
        if !on.is_empty() {
            advice.push(TuningAdvice::new(
                RunProvider::Codex,
                TuningKind::Servers,
                on.clone(),
                vec![],
                None,
                file.to_string_lossy().into_owned(),
                Some(CodexConfig::disable_snippet(&on)),
                false,
            ));
        }
    }
    advice.extend(instructions(RunProvider::Codex, &home.join(".codex/AGENTS.md")));
    advice
}

// MARK: Gemini CLI

pub fn gemini(home: &Path) -> Vec<TuningAdvice> {
    let file = home.join(".gemini/settings.json");
    let mut advice = Vec::new();
    if let Some(settings) = read_json(&file) {
        let excluded: HashSet<String> = settings
            .get("mcp")
            .and_then(|m| m.get("excluded"))
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        let mut on: Vec<String> = settings
            .get("mcpServers")
            .and_then(Value::as_object)
            .map(|m| m.keys().filter(|k| !excluded.contains(*k)).cloned().collect())
            .unwrap_or_default();
        on.sort();
        if !on.is_empty() {
            let mut combined: Vec<String> = excluded.into_iter().collect();
            combined.sort();
            combined.extend(on.iter().cloned());
            let snippet = json_snippet(&serde_json::json!({ "mcp": { "excluded": combined } }));
            advice.push(TuningAdvice::new(
                RunProvider::Gemini,
                TuningKind::Servers,
                on,
                vec![],
                None,
                file.to_string_lossy().into_owned(),
                Some(snippet),
                false,
            ));
        }
    }
    advice.extend(instructions(RunProvider::Gemini, &home.join(".gemini/GEMINI.md")));
    advice
}

// MARK: OpenCode

pub fn opencode(home: &Path) -> Vec<TuningAdvice> {
    let folder = home.join(".config/opencode");
    let mut advice = Vec::new();
    for name in ["opencode.json", "opencode.jsonc"] {
        let file = folder.join(name);
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        let Ok(config) = serde_json::from_str::<Value>(&strip_jsonc(&text)) else { continue };
        let mut on: Vec<String> = config
            .get("mcp")
            .and_then(Value::as_object)
            .map(|m| m.iter().filter(|(_, v)| v.get("enabled").and_then(Value::as_bool) != Some(false)).map(|(k, _)| k.clone()).collect())
            .unwrap_or_default();
        on.sort();
        if !on.is_empty() {
            let mut mcp_map = Map::new();
            for s in &on {
                mcp_map.insert(s.clone(), serde_json::json!({ "enabled": false }));
            }
            let mut root = Map::new();
            root.insert("mcp".into(), Value::Object(mcp_map));
            advice.push(TuningAdvice::new(
                RunProvider::Opencode,
                TuningKind::Servers,
                on,
                vec![],
                None,
                file.to_string_lossy().into_owned(),
                Some(json_snippet(&Value::Object(root))),
                false,
            ));
        }
        break;
    }
    advice.extend(instructions(RunProvider::Opencode, &folder.join("AGENTS.md")));
    advice
}

// MARK: Shared

/// MCP servers in an `mcpServers` JSON file that the agent turns off in its own settings (Cursor, Antigravity).
pub fn json_servers(provider: RunProvider, file: &Path) -> Vec<TuningAdvice> {
    let Some(config) = read_json(file) else { return vec![] };
    let mut on: Vec<String> = config
        .get("mcpServers")
        .and_then(Value::as_object)
        .map(|m| m.iter().filter(|(_, v)| v.get("disabled").and_then(Value::as_bool) != Some(true)).map(|(k, _)| k.clone()).collect())
        .unwrap_or_default();
    on.sort();
    if on.is_empty() {
        vec![]
    } else {
        vec![TuningAdvice::new(provider, TuningKind::Servers, on, vec![], None, file.to_string_lossy().into_owned(), None, false)]
    }
}

pub fn instructions(provider: RunProvider, file: &Path) -> Vec<TuningAdvice> {
    let Ok(text) = std::fs::read_to_string(file) else { return vec![] };
    let chars = text.chars().count();
    if chars <= LONG_INSTRUCTIONS_CHARS {
        return vec![];
    }
    let path_str = file.to_string_lossy().into_owned();
    vec![TuningAdvice::new(provider, TuningKind::LongInstructions, vec![path_str.clone()], vec![], Some(chars), path_str, None, false)]
}

fn read_json(file: &Path) -> Option<Value> {
    let bytes = std::fs::read(file).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Pretty-prints JSON with sorted keys (using `BTreeMap` serialization order via `serde_json` default Map).
pub fn json_snippet(value: &Value) -> String {
    let sorted = sort_json(value);
    serde_json::to_string_pretty(&sorted).unwrap_or_default()
}

fn sort_json(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let ordered: BTreeMap<String, Value> = map.iter().map(|(k, v)| (k.clone(), sort_json(v))).collect();
            let mut out = Map::new();
            for (k, v) in ordered {
                out.insert(k, v);
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(sort_json).collect()),
        other => other.clone(),
    }
}

// MARK: Claude Code plugins

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudePlugin {
    /// `name@marketplace` (`@inline` for plugins synced from claude.ai).
    pub id: String,
    /// Characters its skills and agents add to the listings in every request.
    pub characters: usize,
}

pub struct ClaudePlugins;

impl ClaudePlugins {
    /// The plugins Claude Code loads: those synced from claude.ai, and those installed and enabled.
    pub fn loaded(home: &Path, settings: Option<&Value>) -> Vec<ClaudePlugin> {
        let plugins_folder = home.join(".claude/plugins");
        let enabled = settings.and_then(|v| v.get("enabledPlugins")).and_then(Value::as_object);
        let mut plugins = Vec::new();

        // Synced: ~/.claude/plugins/synced/<account>/<name or name~variant>/, listed in manifest.json.
        let synced = plugins_folder.join("synced");
        if let Ok(accounts) = std::fs::read_dir(&synced) {
            for account in accounts.flatten() {
                let account_path = account.path();
                if account.file_name().to_string_lossy().starts_with('.') || !account_path.is_dir() {
                    continue;
                }
                let names: Vec<String> = read_json(&account_path.join("manifest.json"))
                    .and_then(|v| v.get("plugins").and_then(Value::as_array).cloned())
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|p| p.get("name").and_then(Value::as_str).map(str::to_string))
                    .collect();
                let folders: Vec<(String, PathBuf)> = std::fs::read_dir(&account_path)
                    .ok()
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
                    .collect();
                for name in names {
                    let id = format!("{name}@inline");
                    if enabled.and_then(|m| m.get(&id)).and_then(Value::as_bool) == Some(false) {
                        continue;
                    }
                    let prefix = format!("{name}~");
                    let Some((_, folder)) = folders.iter().find(|(n, _)| n == &name || n.starts_with(&prefix)) else {
                        continue;
                    };
                    plugins.push(ClaudePlugin { id, characters: Self::listing_characters(folder, &name) });
                }
            }
        }

        // Installed from a marketplace: on only when `enabledPlugins` says `true`.
        if let Some(installed) =
            read_json(&plugins_folder.join("installed_plugins.json")).and_then(|v| v.get("plugins").and_then(Value::as_object).cloned())
        {
            for (id, entries) in installed {
                if enabled.and_then(|m| m.get(&id)).and_then(Value::as_bool) != Some(true) {
                    continue;
                }
                let Some(path) = entries.as_array().and_then(|a| a.first()).and_then(|e| e.get("installPath")).and_then(Value::as_str)
                else {
                    continue;
                };
                let name = id.split('@').next().unwrap_or(&id);
                plugins.push(ClaudePlugin { characters: Self::listing_characters(Path::new(path), name), id });
            }
        }

        plugins.sort_by(|a, b| a.id.cmp(&b.id));
        let mut seen = HashSet::new();
        plugins.retain(|p| seen.insert(p.id.clone()));
        plugins
    }

    /// Used within the period: the plugin itself (`pluginUsage`, also its synced twin) or one of its skills.
    pub fn used(id: &str, usage: Option<&Value>, skills: Option<&Value>, since: DateTime<Utc>) -> bool {
        let name = id.split('@').next().unwrap_or(id);
        let since_ms = since.timestamp_millis() as f64;
        let recent = |entry: &Value| -> bool {
            let count = entry.get("usageCount").and_then(Value::as_i64).unwrap_or(0);
            if count <= 0 {
                return false;
            }
            let Some(last) = super::parsers::number(entry.get("lastUsedAt")) else { return false };
            last >= since_ms
        };
        let synced_id = format!("{name}@synced");
        let inline_id = format!("{name}@inline");
        if let Some(map) = usage.and_then(Value::as_object) {
            for (key, entry) in map {
                if (key == id || key == &synced_id || key == &inline_id) && recent(entry) {
                    return true;
                }
            }
        }
        let skill_prefix = format!("{name}:");
        if let Some(map) = skills.and_then(Value::as_object) {
            for (key, entry) in map {
                if (key == name || key.starts_with(&skill_prefix)) && recent(entry) {
                    return true;
                }
            }
        }
        false
    }

    /// The lines its skills and agents add to Claude Code's listings: `- plugin:name: description`.
    pub fn listing_characters(folder: &Path, plugin: &str) -> usize {
        let mut total = 0usize;
        for (sub, file) in [("skills", Some("SKILL.md")), ("agents", None)] {
            let base = folder.join(sub);
            let Ok(entries) = std::fs::read_dir(&base) else { continue };
            for entry in entries.flatten() {
                let path = match file {
                    Some(f) => entry.path().join(f),
                    None => entry.path(),
                };
                if path.extension().and_then(|e| e.to_str()) != Some("md") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&path) else { continue };
                let front = frontmatter_fields(&text);
                let name_len = front.get("name").map(|s| s.chars().count()).unwrap_or(0);
                let desc_len = front.get("description").map(|s| s.chars().count()).unwrap_or(0);
                total += plugin.chars().count() + name_len + desc_len + 6;
            }
        }
        total
    }
}

/// The `key: value` lines between a Markdown file's opening `---` lines.
pub fn frontmatter_fields(text: &str) -> HashMap<String, String> {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return HashMap::new();
    }
    let mut fields = HashMap::new();
    for line in lines {
        if line.trim() == "---" {
            break;
        }
        if line.starts_with(' ') {
            continue;
        }
        let Some((k, v)) = line.split_once(':') else { continue };
        let value = v.trim().trim_matches(|c| c == '"' || c == '\'');
        fields.insert(k.to_string(), value.to_string());
    }
    fields
}

// MARK: Tool use in transcripts

/// Which MCP servers Claude Code actually called, from its transcripts (`~/.claude/projects/*/*.jsonl`).
pub struct TranscriptToolUse;

impl TranscriptToolUse {
    const CALL_START: &'static [u8] = br#""type":"tool_use","id":""#;
    const NAME_START: &'static [u8] = br#"","name":"mcp__"#;

    /// Calls per server in these bytes: each `"type":"tool_use","id":"…","name":"mcp__SERVER__tool"`.
    pub fn servers_in_bytes(data: &[u8]) -> HashMap<String, usize> {
        let mut counts = HashMap::new();
        let mut offset = 0usize;
        let len = data.len();
        while offset < len {
            let Some(rel) = find_bytes(&data[offset..], Self::CALL_START) else { break };
            let mut at = offset + rel + Self::CALL_START.len();
            while at < len && data[at] != b'"' {
                at += 1;
            }
            offset = at;
            if at + Self::NAME_START.len() > len || &data[at..at + Self::NAME_START.len()] != Self::NAME_START {
                continue;
            }
            at += Self::NAME_START.len();
            let start = at;
            while at + 1 < len && !(data[at] == b'_' && data[at + 1] == b'_') && data[at] != b'"' && at - start < 200 {
                at += 1;
            }
            if at + 1 < len && data[at] == b'_' && data[at + 1] == b'_' && at > start {
                if let Ok(server) = std::str::from_utf8(&data[start..at]) {
                    *counts.entry(server.to_string()).or_insert(0) += 1;
                }
            }
            offset = at;
        }
        counts
    }

    pub fn servers_in_str(text: &str) -> HashMap<String, usize> {
        Self::servers_in_bytes(text.as_bytes())
    }

    /// Calls per server in `.jsonl` transcripts under `projects` modified since `since`.
    pub fn servers_in_projects(projects: &Path, since: DateTime<Utc>) -> HashMap<String, usize> {
        let mut counts = HashMap::new();
        let since_sys = SystemTime::from(since);
        walk_jsonl(projects, since_sys, &mut counts);
        counts
    }

    /// The server key in tool names for a claude.ai connector: `"claude.ai Google Drive"` -> `"claude_ai_Google_Drive"`.
    pub fn server_key(connector: &str) -> String {
        connector.replace(['.', ' '], "_")
    }
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    let first = needle[0];
    let mut i = 0usize;
    let limit = haystack.len() - needle.len();
    while i <= limit {
        if haystack[i] == first && &haystack[i..i + needle.len()] == needle {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn walk_jsonl(dir: &Path, since: SystemTime, counts: &mut HashMap<String, usize>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            walk_jsonl(&path, since, counts);
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(modified) = meta.modified() else { continue };
        if modified < since {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else { continue };
        for (name, count) in TranscriptToolUse::servers_in_bytes(&bytes) {
            *counts.entry(name).or_insert(0) += count;
        }
    }
}

// MARK: Codex and JSONC

pub struct CodexConfig;

impl CodexConfig {
    /// The `[mcp_servers.NAME]` tables of a `config.toml` that do not say `enabled = false`.
    pub fn enabled_servers(toml: &str) -> Vec<String> {
        let mut servers: Vec<(String, bool)> = Vec::new();
        for raw in toml.lines() {
            let line = Self::without_comment(raw).trim().to_string();
            if line.starts_with('[') {
                let header = line.trim_matches(|c| matches!(c, '[' | ']' | ' ' | '\t'));
                if let Some(rest) = header.strip_prefix("mcp_servers.") {
                    if let Some(name) = Self::table_name(rest) {
                        servers.push((name, true));
                        continue;
                    }
                }
                servers.push((String::new(), false));
            } else if let Some(last) = servers.last_mut() {
                if !last.0.is_empty() && line.chars().filter(|c| !c.is_whitespace()).collect::<String>() == "enabled=false" {
                    last.1 = false;
                }
            }
        }
        let mut seen = HashSet::new();
        let mut out: Vec<String> = servers
            .into_iter()
            .filter(|(name, enabled)| !name.is_empty() && *enabled && seen.insert(name.clone()))
            .map(|(name, _)| name)
            .collect();
        out.sort();
        out
    }

    fn table_name(rest: &str) -> Option<String> {
        if let Some(inner) = rest.strip_prefix('"') {
            let end = inner.find('"')?;
            let after = &inner[end + 1..];
            if after.is_empty() {
                Some(inner[..end].to_string())
            } else {
                None
            }
        } else if rest.contains('.') {
            None
        } else {
            Some(rest.to_string())
        }
    }

    /// A TOML table key: bare when ASCII letters/digits/`_`/`-`, quoted otherwise.
    pub fn key(name: &str) -> String {
        let bare = !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
        if bare {
            name.to_string()
        } else {
            serde_json::to_string(name).unwrap_or_else(|_| format!("\"{name}\""))
        }
    }

    /// What to add to each server's existing table without repeating the `[mcp_servers.*]` header.
    pub fn disable_snippet(servers: &[String]) -> String {
        servers
            .iter()
            .map(|s| format!("# In the existing [mcp_servers.{}] table, add:\nenabled = false", Self::key(s)))
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    /// The line without a `#` comment (a `#` inside a quoted string stays).
    pub fn without_comment(line: &str) -> &str {
        let mut in_string = false;
        let mut escaped = false;
        for (idx, ch) in line.char_indices() {
            if escaped {
                escaped = false;
                continue;
            }
            if in_string && ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                in_string = !in_string;
            } else if ch == '#' && !in_string {
                return &line[..idx];
            }
        }
        line
    }
}

/// Strips `//`, `/* ... */` comments and trailing commas from JSONC (`opencode.jsonc`) while preserving strings.
pub fn strip_jsonc(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut no_comments = String::with_capacity(text.len());
    let mut i = 0usize;
    let mut in_string = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            no_comments.push(c);
            if c == '\\' && i + 1 < chars.len() {
                no_comments.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if c == '"' {
            in_string = true;
            no_comments.push(c);
            i += 1;
            continue;
        }
        if c == '/' && i + 1 < chars.len() && chars[i + 1] == '/' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && i + 1 < chars.len() && chars[i + 1] == '*' {
            i += 2;
            while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                i += 1;
            }
            i = (i + 2).min(chars.len());
            continue;
        }
        no_comments.push(c);
        i += 1;
    }

    let cleaned: Vec<char> = no_comments.chars().collect();
    let mut out = String::with_capacity(no_comments.len());
    let mut j = 0usize;
    in_string = false;
    while j < cleaned.len() {
        let c = cleaned[j];
        if in_string {
            out.push(c);
            if c == '\\' && j + 1 < cleaned.len() {
                out.push(cleaned[j + 1]);
                j += 2;
                continue;
            }
            if c == '"' {
                in_string = false;
            }
            j += 1;
            continue;
        }
        if c == '"' {
            in_string = true;
            out.push(c);
            j += 1;
            continue;
        }
        if c == ',' {
            let mut k = j + 1;
            while k < cleaned.len() && cleaned[k].is_whitespace() {
                k += 1;
            }
            if k < cleaned.len() && (cleaned[k] == '}' || cleaned[k] == ']') {
                j += 1;
                continue;
            }
        }
        out.push(c);
        j += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_file(base: &Path, rel: &str, text: &str) {
        let path = base.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn skill(name: &str, description: &str) -> String {
        format!("---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n")
    }

    fn claude_home(home: &Path, now: DateTime<Utc>, connector_used: bool) {
        let millis = |days_ago: i64| (now - Duration::days(days_ago)).timestamp_millis();
        write_file(
            home,
            ".claude/plugins/synced/acct/manifest.json",
            r#"{"plugins":[{"name":"sales"},{"name":"engineering"},{"name":"design"}]}"#,
        );
        write_file(home, ".claude/plugins/synced/acct/sales/skills/forecast/SKILL.md", &skill("forecast", "Write the forecast narrative."));
        write_file(home, ".claude/plugins/synced/acct/engineering~g2/skills/debug/SKILL.md", &skill("debug", "Structured debugging."));
        write_file(home, ".claude/plugins/synced/acct/design/skills/critique/SKILL.md", &skill("critique", "Design feedback."));
        write_file(home, ".claude/settings.json", r#"{"enabledPlugins":{"design@inline":false}}"#);
        write_file(
            home,
            ".claude.json",
            &format!(
                r#"{{"pluginUsage":{{"sales@inline":{{"usageCount":0,"lastUsedAt":{}}},"engineering@inline":{{"usageCount":4,"lastUsedAt":{}}}}},"skillUsage":{{"sales:forecast":{{"usageCount":1,"lastUsedAt":{}}}}},"claudeAiMcpEverConnected":["claude.ai Gmail","claude.ai Claude Docs"],"mcpServers":{{"elementor":{{}},"old-server":{{}}}},"autoCompactEnabled":false}}"#,
                millis(1),
                millis(2),
                millis(45)
            ),
        );
        let mut calls = String::from(
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"mcp__elementor__list","input":{}}]}}"#,
        );
        calls.push('\n');
        if connector_used {
            calls.push_str(
                r#"{"message":{"content":[{"type":"tool_use","id":"toolu_2","name":"mcp__claude_ai_Claude_Docs__read","input":{}}]}}"#,
            );
            calls.push('\n');
        }
        // A tool list in a request names tools without calling them.
        calls.push_str(r#"{"type":"api-request-shape","shape":{"tools":[{"name":"mcp__old-server__x"}]}}"#);
        calls.push('\n');
        write_file(home, ".claude/projects/p/s.jsonl", &calls);
    }

    struct TempDir(PathBuf);
    impl TempDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("nook-tuning-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn claude_suggests_what_you_do_not_use() {
        let dir = TempDir::new();
        let now = Utc::now();
        claude_home(dir.path(), now, false);
        let advice = claude(dir.path(), now);

        let plugins = advice.iter().find(|a| a.kind == TuningKind::UnusedPlugins).unwrap();
        assert_eq!(plugins.items, vec!["sales@inline"]);
        assert!(plugins.applies_in_nook);
        assert!(plugins.characters.unwrap_or(0) > 0);
        assert!(plugins.snippet.as_deref().unwrap_or("").contains("\"sales@inline\": false"));

        let connectors = advice.iter().find(|a| a.kind == TuningKind::CloudConnectors).unwrap();
        assert_eq!(connectors.items, vec!["claude.ai Gmail", "claude.ai Claude Docs"]);
        assert!(connectors.applies_in_nook);

        let servers = advice.iter().find(|a| a.kind == TuningKind::UnusedServers).unwrap();
        assert_eq!(servers.items, vec!["old-server"]);
        assert!(advice.iter().any(|a| a.kind == TuningKind::AutoCompactOff));
    }

    #[test]
    fn connector_in_use_keeps_switch_off() {
        let dir = TempDir::new();
        let now = Utc::now();
        claude_home(dir.path(), now, true);
        let advice = claude(dir.path(), now);
        let connectors = advice.iter().find(|a| a.kind == TuningKind::CloudConnectors).unwrap();
        assert_eq!(connectors.items, vec!["claude.ai Gmail"]);
        assert_eq!(connectors.kept, vec!["claude.ai Claude Docs"]);
        assert!(!connectors.applies_in_nook);
        assert!(connectors.location.starts_with("https://claude.ai/"));
    }

    #[test]
    fn plugin_synced_twice_is_counted_once() {
        let dir = TempDir::new();
        let now = Utc::now();
        claude_home(dir.path(), now, false);
        write_file(dir.path(), ".claude/plugins/synced/acct2/manifest.json", r#"{"plugins":[{"name":"sales"}]}"#);
        write_file(
            dir.path(),
            ".claude/plugins/synced/acct2/sales/skills/forecast/SKILL.md",
            &skill("forecast", "Write the forecast narrative."),
        );
        let advice = claude(dir.path(), now);
        let plugins = advice.iter().find(|a| a.kind == TuningKind::UnusedPlugins).unwrap();
        assert_eq!(plugins.items, vec!["sales@inline"]);
    }

    #[test]
    fn applied_suggestions_stay_listed_and_reach_claude_settings() {
        let mut applied =
            AppliedTuning { claude_plugins: vec!["sales@inline".into(), "marketing@inline".into()], claude_no_connectors: true };
        let current = vec![TuningAdvice::new(
            RunProvider::Claude,
            TuningKind::UnusedPlugins,
            vec!["sales@inline".into()],
            vec![],
            None,
            "",
            None,
            true,
        )];
        let rows = with_applied(current, &applied, "/s");
        let plugin_items: Vec<Vec<String>> = rows.iter().filter(|r| r.kind == TuningKind::UnusedPlugins).map(|r| r.items.clone()).collect();
        assert_eq!(plugin_items, vec![vec!["sales@inline"], vec!["marketing@inline"]]);
        assert!(rows.iter().all(|r| applied.is_applied(r)));
        let unique_ids: HashSet<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(unique_ids.len(), rows.len());

        let settings = applied.claude_settings();
        assert_eq!(settings.get("enabledPlugins").and_then(|v| v.get("sales@inline")).and_then(Value::as_bool), Some(false));
        assert_eq!(settings.get("disableClaudeAiConnectors").and_then(Value::as_bool), Some(true));

        let sales = TuningAdvice::new(
            RunProvider::Claude,
            TuningKind::UnusedPlugins,
            vec!["sales@inline".into(), "marketing@inline".into()],
            vec![],
            None,
            "",
            None,
            true,
        );
        applied.set(&sales, false);
        assert!(!applied.is_applied(&sales));
        assert!(applied.claude_settings().get("enabledPlugins").is_none());
    }

    #[test]
    fn codex_gemini_opencode_cursor_antigravity_and_long_instructions() {
        let dir = TempDir::new();
        let now = Utc::now();
        write_file(
            dir.path(),
            ".codex/config.toml",
            r#"model = "gpt-5"
[mcp_servers.github] # the work one
command = "gh-mcp"
[mcp_servers.github.env]
TOKEN = "x"
[mcp_servers."my server"]
command = "a"
[mcp_servers.off]
command = "b"
enabled	=	false # not now
[mcp_servers."büro"]
command = "c"
[projects."/tmp"]
trust_level = "trusted"
"#,
        );
        let codex_advice = codex(dir.path());
        assert_eq!(codex_advice[0].kind, TuningKind::Servers);
        assert_eq!(codex_advice[0].items, vec!["büro", "github", "my server"]);
        let snippet = codex_advice[0].snippet.as_deref().unwrap();
        assert!(!snippet.contains("\n[mcp_servers"));
        assert!(snippet.contains("[mcp_servers.\"my server\"] table, add:\nenabled = false"));
        assert!(snippet.contains("[mcp_servers.\"büro\"]"));
        assert_eq!(CodexConfig::key("github-2"), "github-2");
        assert!(!codex_advice[0].applies_in_nook);

        write_file(dir.path(), ".gemini/settings.json", r#"{"mcpServers":{"a":{},"b":{}},"mcp":{"excluded":["b"]}}"#);
        let gemini_advice = gemini(dir.path());
        assert_eq!(gemini_advice[0].items, vec!["a"]);
        assert!(gemini_advice[0].snippet.as_deref().unwrap().contains("\"a\""));

        write_file(
            dir.path(),
            ".config/opencode/opencode.jsonc",
            "{\n  // mine\n  \"mcp\": {\"x\": {\"type\": \"local\"}, \"y\": {\"enabled\": false},},\n}",
        );
        assert_eq!(opencode(dir.path())[0].items, vec!["x"]);

        write_file(dir.path(), ".cursor/mcp.json", r#"{"mcpServers":{"z":{"command":"z"}}}"#);
        write_file(dir.path(), ".gemini/antigravity/mcp_config.json", r#"{"mcpServers":{"q":{"disabled":true}}}"#);
        let all = scan(dir.path(), now);
        assert_eq!(all.iter().find(|a| a.provider == RunProvider::Cursor).unwrap().items, vec!["z"]);
        assert!(all.iter().find(|a| a.provider == RunProvider::Antigravity).is_none());

        write_file(dir.path(), ".codex/AGENTS.md", &"Be brief. ".repeat(1_000));
        let long = codex(dir.path()).into_iter().find(|a| a.kind == TuningKind::LongInstructions).unwrap();
        assert_eq!(long.characters, Some(10_000));
        assert_eq!(long.tokens, Some(2_500));

        let empty = TempDir::new();
        assert!(scan(empty.path(), now).is_empty());
    }

    #[test]
    fn jsonc_keeps_strings_and_connector_key_formatting() {
        let text = "{\"url\": \"https://x.dev/a//b\", /* c */ \"list\": [1, 2,], // end\n}";
        let parsed: Value = serde_json::from_str(&strip_jsonc(text)).unwrap();
        assert_eq!(parsed.get("url").and_then(Value::as_str), Some("https://x.dev/a//b"));
        assert_eq!(TranscriptToolUse::server_key("claude.ai Google Drive"), "claude_ai_Google_Drive");
    }
}
