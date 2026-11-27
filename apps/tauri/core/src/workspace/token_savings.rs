//! What Nook does so coding agents spend fewer tokens without losing quality (`TokenSavings` on macOS).
//!
//! - Prompt cache tracking (`PromptCache`, `PromptCacheWindow`): extracts Claude Code's ephemeral cache lifetime
//!   (1 hour on subscription, 5 minutes on API key) from `usage.cache_creation`.
//! - Idle compaction (`IdleCompaction`): summarizes a long idle session (`/compact`) shortly before its prompt cache
//!   expires while its history is still cheap to read.
//! - Return compaction (`ReturnCompaction`): offers to compact first when returning to a long session whose cache has
//!   already expired.
//! - Size compaction (`SizeCompaction`) and auto-compact mark (`AutoCompactMark`): summarizes a session once its
//!   context crosses your configured limit (or 80 % of its context window), and detects Claude Code's own
//!   `autoCompactWindow`.
//! - Tool search (`ClaudeToolSearch`): enables Claude Code's `ENABLE_TOOL_SEARCH` unless the user chose otherwise.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::models::{RunProvider, RunStatus};
use super::parsers;

static IDLE_COMPACTION: AtomicBool = AtomicBool::new(true);
static AUTO_COMPACT_TOKENS: AtomicU64 = AtomicU64::new(SizeCompaction::DEFAULT_TOKENS);
static OMIT_AGENT_CREDITS: AtomicBool = AtomicBool::new(false);

pub fn idle_compaction_enabled() -> bool {
    IDLE_COMPACTION.load(Ordering::Relaxed)
}

pub fn set_idle_compaction_enabled(on: bool) {
    IDLE_COMPACTION.store(on, Ordering::Relaxed);
}

pub fn auto_compact_tokens() -> u64 {
    AUTO_COMPACT_TOKENS.load(Ordering::Relaxed)
}

pub fn set_auto_compact_tokens(tokens: u64) {
    AUTO_COMPACT_TOKENS.store(tokens, Ordering::Relaxed);
}

pub fn omit_agent_credits() -> bool {
    OMIT_AGENT_CREDITS.load(Ordering::Relaxed)
}

pub fn set_omit_agent_credits(on: bool) {
    OMIT_AGENT_CREDITS.store(on, Ordering::Relaxed);
}

/// Whether the agent natively accepts `/compact` (`AgentCommands.hasBuiltInCompact` on macOS).
pub fn has_built_in_compact(provider: RunProvider) -> bool {
    matches!(provider, RunProvider::Claude | RunProvider::Codex)
}

/// Whether the agent compacts its context on `/compact`: built in, or announced by the agent itself (ACP).
pub fn can_compact(provider: RunProvider, offered_commands: &[String]) -> bool {
    has_built_in_compact(provider) || offered_commands.iter().any(|c| c == "compact")
}

/// How long the agent's prompt cache stays warm after its last request, as the agent reported it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptCacheWindow {
    /// When the cache of the last request runs out.
    pub expires_at: DateTime<Utc>,
    /// The cache lifetime the agent reported in seconds (Claude: 1 hour on a subscription, 5 minutes on an API key).
    pub ttl: f64,
    /// The turn that set this window compacted the conversation (by hand, by Nook, or by the agent itself).
    #[serde(default)]
    pub after_compaction: bool,
}

pub struct PromptCache;

impl PromptCache {
    /// The cache lifetime of a Claude request from its `usage.cache_creation`, or `None` when it wrote nothing to the
    /// cache. A request served fully from the cache reports no lifetime but refreshes the cache with the lifetime it
    /// had.
    pub fn claude_ttl(usage: &Value) -> Option<f64> {
        let creation = usage.get("cache_creation")?.as_object()?;
        let tokens = |key: &str| parsers::number(creation.get(key)).unwrap_or(0.0);
        if tokens("ephemeral_1h_input_tokens") > 0.0 {
            return Some(3_600.0);
        }
        if tokens("ephemeral_5m_input_tokens") > 0.0 {
            return Some(300.0);
        }
        None
    }

    /// Computes the updated prompt cache window after a turn finishes.
    pub fn window_after(
        last_request_at: Option<DateTime<Utc>>,
        turn_ttl: Option<f64>,
        previous: Option<&PromptCacheWindow>,
        compacted: bool,
    ) -> Option<PromptCacheWindow> {
        let started = last_request_at?;
        let ttl = turn_ttl.or_else(|| previous.map(|p| p.ttl))?;
        if ttl <= 0.0 {
            return None;
        }
        let expires_at = started + Duration::milliseconds((ttl * 1000.0).round() as i64);
        Some(PromptCacheWindow { expires_at, ttl, after_compaction: compacted })
    }
}

/// An idle Claude session over `MINIMUM_CONTEXT_TOKENS` is summarized (`/compact`) shortly before its prompt cache
/// expires, while its history is still cheap to read.
pub struct IdleCompaction;

/// What decides whether, and when, an idle session is summarized. Everything that holds it back is a reason to wait.
#[derive(Debug, Clone, PartialEq)]
pub struct IdleCandidate {
    /// The agent reports how long its prompt cache lives (`ProviderCapabilities.reports_prompt_cache_lifetime`).
    pub agent_reports_cache_lifetime: bool,
    pub status: RunStatus,
    pub archived: bool,
    pub settled: bool,
    pub snoozed_until: Option<DateTime<Utc>>,
    pub context_tokens: Option<u64>,
    pub cache: Option<PromptCacheWindow>,
    /// Approvals or questions wait, messages are queued, background work will report into the next turn, or a handoff
    /// or rollback waits for your next message.
    pub holds_for_you: bool,
    pub is_remote: bool,
}

impl IdleCompaction {
    /// Below this a cold reread costs little, so summarizing mostly loses context for a small saving.
    pub const MINIMUM_CONTEXT_TOKENS: u64 = 200_000;
    /// How long before the cache expires the summary starts (seconds).
    pub const LEAD_SECS: f64 = 120.0;

    /// When to send the summary, or `None` when this session should not get one.
    pub fn fire_date(candidate: &IdleCandidate, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        if !candidate.agent_reports_cache_lifetime
            || candidate.status != RunStatus::Completed
            || candidate.archived
            || candidate.settled
            || candidate.holds_for_you
            || candidate.is_remote
            || candidate.context_tokens.unwrap_or(0) < Self::MINIMUM_CONTEXT_TOKENS
        {
            return None;
        }
        if candidate.snoozed_until.is_some_and(|snoozed| snoozed > now) {
            return None;
        }
        let cache = candidate.cache.as_ref()?;
        if cache.after_compaction || cache.expires_at <= now {
            return None;
        }
        // A short-lived cache (5 minutes) leaves little room; start at least halfway through it.
        let lead = Self::LEAD_SECS.min(cache.ttl / 2.0);
        let start = cache.expires_at - Duration::milliseconds((lead * 1000.0).round() as i64);
        Some(start.max(now))
    }
}

/// Returning to a long session after its prompt cache expired: offers to summarize (`/compact`) before sending the
/// next message.
pub struct ReturnCompaction;

#[derive(Debug, Clone, PartialEq)]
pub struct ReturnCandidate {
    pub agent_reports_cache_lifetime: bool,
    pub can_compact: bool,
    pub enabled: bool,
    pub status: RunStatus,
    pub context_tokens: Option<u64>,
    pub cache: Option<PromptCacheWindow>,
    pub is_remote: bool,
}

impl ReturnCompaction {
    /// True for a finished session over `IdleCompaction::MINIMUM_CONTEXT_TOKENS` whose cache has run out and was not
    /// summarized since.
    pub fn offers(candidate: &ReturnCandidate, now: DateTime<Utc>) -> bool {
        if !candidate.enabled
            || !candidate.agent_reports_cache_lifetime
            || !candidate.can_compact
            || candidate.status != RunStatus::Completed
            || candidate.is_remote
            || candidate.context_tokens.unwrap_or(0) < IdleCompaction::MINIMUM_CONTEXT_TOKENS
        {
            return false;
        }
        let Some(cache) = candidate.cache.as_ref() else { return false };
        if cache.after_compaction {
            return false;
        }
        cache.expires_at <= now
    }
}

/// Where the agent summarizes by itself, for the mark on the context meter: Nook's own limit (`SizeCompaction`) and
/// the agent's own threshold where it reports one (Claude Code's `autoCompactWindow`), whichever comes first.
pub struct AutoCompactMark;

impl AutoCompactMark {
    /// Claude Code compacts this far short of its `autoCompactWindow`.
    pub const CLAUDE_RESERVE: u64 = 33_000;
    /// Inclusive range of `autoCompactWindow` values Claude Code accepts.
    pub const CLAUDE_WINDOW_MIN: u64 = 100_000;
    pub const CLAUDE_WINDOW_MAX: u64 = 1_000_000;

    /// The first positive threshold that applies, or `None` when neither does.
    pub fn tokens(nook_limit: Option<u64>, agent_threshold: Option<u64>) -> Option<u64> {
        [nook_limit, agent_threshold].into_iter().flatten().filter(|&v| v > 0).min()
    }

    /// Claude Code's threshold for an `autoCompactWindow`: only below the model's own window, which caps it.
    pub fn claude_threshold(window: Option<u64>, context_window: Option<u64>) -> Option<u64> {
        let window = window?;
        if !(Self::CLAUDE_WINDOW_MIN..=Self::CLAUDE_WINDOW_MAX).contains(&window) {
            return None;
        }
        if let Some(cw) = context_window {
            if cw > 0 && window >= cw {
                return None;
            }
        }
        window.checked_sub(Self::CLAUDE_RESERVE)
    }

    /// `autoCompactWindow` from Claude Code's settings files, strongest first: the model's own entry in
    /// `modelSettings` (where `"auto"` means none), else the file's top-level value. Numbers may be written as text.
    pub fn claude_window(files: &[PathBuf], model: &str) -> Option<u64> {
        let key = model.to_lowercase().replace("[1m]", "");
        for file in files {
            let Ok(bytes) = std::fs::read(file) else { continue };
            let Ok(object) = serde_json::from_slice::<Value>(&bytes) else { continue };
            let entry = object
                .get("modelSettings")
                .and_then(Value::as_object)
                .and_then(|ms| ms.get(&key))
                .and_then(Value::as_object)
                .and_then(|m| m.get("autoCompactWindow"));
            if entry.and_then(Value::as_str) == Some("auto") {
                return None;
            }
            let candidate = json_u64(entry).or_else(|| json_u64(object.get("autoCompactWindow")));
            if let Some(window) = candidate {
                if (Self::CLAUDE_WINDOW_MIN..=Self::CLAUDE_WINDOW_MAX).contains(&window) {
                    return Some(window);
                }
            }
        }
        None
    }
}

fn json_u64(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(n) => n.as_u64().or_else(|| n.as_f64().filter(|&f| f >= 0.0).map(|f| f as u64)),
        Value::String(s) => s.trim().parse::<u64>().ok(),
        _ => None,
    }
}

/// Summarizing a session once its context grows past a size, whether or not it goes idle.
pub struct SizeCompaction;

impl SizeCompaction {
    /// `0` turns it off. The default sits well above the point where an idle session is summarized.
    pub const DEFAULT_TOKENS: u64 = 350_000;
    pub const CHOICES: &'static [u64] = &[0, 150_000, 250_000, 350_000, 500_000];
    /// Never wait for more than this share of the agent's window, so a small window is summarized before it is full.
    pub const WINDOW_SHARE: f64 = 0.8;

    /// The size at which this session is summarized, or `None` when it is off.
    pub fn limit(setting: u64, context_window: Option<u64>) -> Option<u64> {
        if setting == 0 {
            return None;
        }
        match context_window {
            Some(window) if window > 0 => Some(setting.min((window as f64 * Self::WINDOW_SHARE) as u64)),
            _ => Some(setting),
        }
    }

    /// Whether a turn that just ended leaves the session past its limit.
    #[allow(clippy::too_many_arguments)]
    pub fn should_compact(
        setting: u64,
        context_tokens: Option<u64>,
        context_window: Option<u64>,
        can_compact: bool,
        completed: bool,
        holds_for_you: bool,
        is_remote: bool,
        already_compacted: bool,
    ) -> bool {
        if !can_compact || !completed || holds_for_you || is_remote || already_compacted {
            return false;
        }
        let (Some(tokens), Some(limit)) = (context_tokens, Self::limit(setting, context_window)) else {
            return false;
        };
        tokens >= limit
    }
}

/// Claude Code's `ENABLE_TOOL_SEARCH`: Nook turns tool search on unless you chose something else yourself.
pub struct ClaudeToolSearch;

impl ClaudeToolSearch {
    /// The value Nook sets, or `None` to leave yours: `auto` and `auto:N` (`0 < N < 100`) become `"true"`. `auto:0`
    /// already means on, `auto:100` off, and `"true"` or `"false"` are a choice of yours.
    pub fn override_value(user_value: Option<&str>) -> Option<&'static str> {
        let Some(raw) = user_value.map(str::trim) else {
            return Some("true");
        };
        if raw == "auto" {
            return Some("true");
        }
        let rest = raw.strip_prefix("auto:")?;
        // Claude Code treats an unreadable `auto:N` as `auto`.
        let Ok(percent) = rest.trim().parse::<i64>() else {
            return Some("true");
        };
        if percent > 0 && percent < 100 {
            Some("true")
        } else {
            None
        }
    }

    /// The settings files Claude Code reads `env` from, strongest first: the project's local and shared settings, then
    /// the account's own (`CLAUDE_CONFIG_DIR`, else `~/.claude`).
    pub fn settings_files(working_directory: &str, config_directory: Option<&str>) -> Vec<PathBuf> {
        let folder = Path::new(working_directory).join(".claude");
        let config = config_directory
            .filter(|s| !s.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(crate::paths::support_directory).join(".claude"));
        vec![folder.join("settings.local.json"), folder.join("settings.json"), config.join("settings.json")]
    }

    /// The first `env.ENABLE_TOOL_SEARCH` in these files, or `None` when none sets it.
    pub fn user_value(files: &[PathBuf]) -> Option<String> {
        for file in files {
            let Ok(bytes) = std::fs::read(file) else { continue };
            let Ok(object) = serde_json::from_slice::<Value>(&bytes) else { continue };
            let Some(val) = object.get("env").and_then(Value::as_object).and_then(|e| e.get("ENABLE_TOOL_SEARCH")) else {
                continue;
            };
            if let Some(text) = val.as_str() {
                return Some(text.to_string());
            }
            if let Some(flag) = val.as_bool() {
                return Some(if flag { "true" } else { "false" }.to_string());
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_000_000, 0).unwrap()
    }

    #[test]
    fn claude_cache_lifetime_from_usage() {
        assert_eq!(
            PromptCache::claude_ttl(&json!({"cache_creation": {"ephemeral_1h_input_tokens": 26_000, "ephemeral_5m_input_tokens": 0}})),
            Some(3_600.0)
        );
        assert_eq!(
            PromptCache::claude_ttl(&json!({"cache_creation": {"ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 900}})),
            Some(300.0)
        );
        assert_eq!(
            PromptCache::claude_ttl(&json!({"cache_creation": {"ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 0}})),
            None
        );
        assert_eq!(PromptCache::claude_ttl(&json!({"input_tokens": 3})), None);
    }

    fn base_idle(n: DateTime<Utc>) -> IdleCandidate {
        IdleCandidate {
            agent_reports_cache_lifetime: true,
            status: RunStatus::Completed,
            archived: false,
            settled: false,
            snoozed_until: None,
            context_tokens: Some(250_000),
            cache: Some(PromptCacheWindow { expires_at: n + Duration::seconds(3_000), ttl: 3_600.0, after_compaction: false }),
            holds_for_you: false,
            is_remote: false,
        }
    }

    #[test]
    fn idle_compaction_timing_and_holds() {
        let n = now();
        assert_eq!(IdleCompaction::fire_date(&base_idle(n), n), Some(n + Duration::seconds(3_000 - IdleCompaction::LEAD_SECS as i64)));

        let mut short = base_idle(n);
        short.cache = Some(PromptCacheWindow { expires_at: n + Duration::seconds(300), ttl: 300.0, after_compaction: false });
        assert_eq!(IdleCompaction::fire_date(&short, n), Some(n + Duration::seconds(180)));

        let mut late = base_idle(n);
        late.cache = Some(PromptCacheWindow { expires_at: n + Duration::seconds(30), ttl: 300.0, after_compaction: false });
        assert_eq!(IdleCompaction::fire_date(&late, n), Some(n));

        let mut cases: Vec<(&str, IdleCandidate)> = vec![
            ("no cache lifetime", {
                let mut c = base_idle(n);
                c.agent_reports_cache_lifetime = false;
                c
            }),
            ("short", {
                let mut c = base_idle(n);
                c.context_tokens = Some(IdleCompaction::MINIMUM_CONTEXT_TOKENS - 1);
                c
            }),
            ("no usage", {
                let mut c = base_idle(n);
                c.context_tokens = None;
                c
            }),
            ("expired", {
                let mut c = base_idle(n);
                c.cache.as_mut().unwrap().expires_at = n;
                c
            }),
            ("no cache", {
                let mut c = base_idle(n);
                c.cache = None;
                c
            }),
            ("after compaction", {
                let mut c = base_idle(n);
                c.cache.as_mut().unwrap().after_compaction = true;
                c
            }),
            ("failed", {
                let mut c = base_idle(n);
                c.status = RunStatus::Failed;
                c
            }),
            ("stopped", {
                let mut c = base_idle(n);
                c.status = RunStatus::Stopped;
                c
            }),
            ("running", {
                let mut c = base_idle(n);
                c.status = RunStatus::Running;
                c
            }),
            ("archived", {
                let mut c = base_idle(n);
                c.archived = true;
                c
            }),
            ("settled", {
                let mut c = base_idle(n);
                c.settled = true;
                c
            }),
            ("snoozed", {
                let mut c = base_idle(n);
                c.snoozed_until = Some(n + Duration::seconds(60));
                c
            }),
            ("holds", {
                let mut c = base_idle(n);
                c.holds_for_you = true;
                c
            }),
            ("remote", {
                let mut c = base_idle(n);
                c.is_remote = true;
                c
            }),
        ];
        for (reason, cand) in cases.drain(..) {
            assert_eq!(IdleCompaction::fire_date(&cand, n), None, "{reason}");
        }

        let mut unsnoozed = base_idle(n);
        unsnoozed.snoozed_until = Some(n - Duration::seconds(60));
        assert!(IdleCompaction::fire_date(&unsnoozed, n).is_some());
    }

    #[test]
    fn return_compaction_offers_only_when_long_and_cold() {
        let n = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        let make = |expired: bool, tokens: u64| ReturnCandidate {
            agent_reports_cache_lifetime: true,
            can_compact: true,
            enabled: true,
            status: RunStatus::Completed,
            context_tokens: Some(tokens),
            cache: Some(PromptCacheWindow {
                expires_at: if expired { n - Duration::seconds(60) } else { n + Duration::seconds(600) },
                ttl: 3_600.0,
                after_compaction: false,
            }),
            is_remote: false,
        };
        assert!(ReturnCompaction::offers(&make(true, 312_000), n));
        assert!(!ReturnCompaction::offers(&make(false, 312_000), n));
        assert!(!ReturnCompaction::offers(&make(true, 150_000), n));

        let mut other = make(true, 312_000);
        other.agent_reports_cache_lifetime = false;
        assert!(!ReturnCompaction::offers(&other, n));

        let mut other = make(true, 312_000);
        other.enabled = false;
        assert!(!ReturnCompaction::offers(&other, n));

        let mut other = make(true, 312_000);
        other.cache.as_mut().unwrap().after_compaction = true;
        assert!(!ReturnCompaction::offers(&other, n));

        let mut other = make(true, 312_000);
        other.status = RunStatus::Running;
        assert!(!ReturnCompaction::offers(&other, n));

        let mut other = make(true, 312_000);
        other.is_remote = true;
        assert!(!ReturnCompaction::offers(&other, n));
    }

    struct TempDir(PathBuf);
    impl TempDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("nook-token-savings-{}", uuid::Uuid::new_v4()));
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
    fn auto_compact_mark_and_claude_window_files() {
        assert_eq!(AutoCompactMark::tokens(Some(350_000), Some(117_000)), Some(117_000));
        assert_eq!(AutoCompactMark::tokens(Some(160_000), None), Some(160_000));
        assert_eq!(AutoCompactMark::tokens(None, None), None);
        assert_eq!(AutoCompactMark::claude_threshold(Some(150_000), Some(200_000)), Some(117_000));
        assert_eq!(AutoCompactMark::claude_threshold(Some(200_000), Some(200_000)), None);
        assert_eq!(AutoCompactMark::claude_threshold(Some(50_000), None), None);

        let dir = TempDir::new();
        let local = dir.path().join("local.json");
        let shared = dir.path().join("shared.json");
        std::fs::write(&local, r#"{"modelSettings":{"claude-opus-5-5":{"autoCompactWindow":"auto"}}}"#).unwrap();
        std::fs::write(&shared, r#"{"autoCompactWindow":"400000"}"#).unwrap();
        assert_eq!(AutoCompactMark::claude_window(&[local.clone(), shared.clone()], "claude-opus-5-5[1m]"), None);
        assert_eq!(AutoCompactMark::claude_window(&[local, shared], "claude-sonnet-5-5"), Some(400_000));
    }

    #[test]
    fn size_compaction_limits_and_holds() {
        assert_eq!(SizeCompaction::limit(350_000, Some(200_000)), Some(160_000));
        assert_eq!(SizeCompaction::limit(350_000, None), Some(350_000));
        assert_eq!(SizeCompaction::limit(0, Some(200_000)), None);

        assert!(SizeCompaction::should_compact(350_000, Some(350_000), Some(1_000_000), true, true, false, false, false));
        assert!(!SizeCompaction::should_compact(350_000, Some(349_999), Some(1_000_000), true, true, false, false, false));
        assert!(!SizeCompaction::should_compact(0, Some(900_000), Some(1_000_000), true, true, false, false, false));
        assert!(SizeCompaction::should_compact(350_000, Some(170_000), Some(200_000), true, true, false, false, false));
        assert!(!SizeCompaction::should_compact(350_000, Some(500_000), Some(1_000_000), false, true, false, false, false));
        assert!(!SizeCompaction::should_compact(350_000, Some(500_000), Some(1_000_000), true, false, false, false, false));
        assert!(!SizeCompaction::should_compact(350_000, Some(500_000), Some(1_000_000), true, true, true, false, false));
        assert!(!SizeCompaction::should_compact(350_000, Some(500_000), Some(1_000_000), true, true, false, true, false));
        assert!(!SizeCompaction::should_compact(350_000, Some(500_000), Some(1_000_000), true, true, false, false, true));
    }

    #[test]
    fn claude_tool_search_overrides_and_reads_strongest_file() {
        assert_eq!(ClaudeToolSearch::override_value(None), Some("true"));
        assert_eq!(ClaudeToolSearch::override_value(Some("auto")), Some("true"));
        assert_eq!(ClaudeToolSearch::override_value(Some("auto:10")), Some("true"));
        assert_eq!(ClaudeToolSearch::override_value(Some("auto:x")), Some("true"));
        assert_eq!(ClaudeToolSearch::override_value(Some("auto:0")), None);
        assert_eq!(ClaudeToolSearch::override_value(Some("auto:100")), None);
        assert_eq!(ClaudeToolSearch::override_value(Some("false")), None);
        assert_eq!(ClaudeToolSearch::override_value(Some("true")), None);

        let dir = TempDir::new();
        let project = dir.path().join("project");
        let config = dir.path().join("config");
        std::fs::create_dir_all(project.join(".claude")).unwrap();
        std::fs::create_dir_all(&config).unwrap();
        let files = ClaudeToolSearch::settings_files(project.to_str().unwrap(), Some(config.to_str().unwrap()));
        assert_eq!(ClaudeToolSearch::user_value(&files), None);
        std::fs::write(config.join("settings.json"), r#"{"env":{"ENABLE_TOOL_SEARCH":"false"}}"#).unwrap();
        assert_eq!(ClaudeToolSearch::user_value(&files).as_deref(), Some("false"));
        std::fs::write(project.join(".claude/settings.json"), r#"{"env":{"ENABLE_TOOL_SEARCH":"auto"}}"#).unwrap();
        assert_eq!(ClaudeToolSearch::user_value(&files).as_deref(), Some("auto"));
    }
}
