//! Subscription limits read while no session runs (`ClaudeUsage`, `CodexUsage`, `CodexRateLimits` on the Mac): the
//! status line and a session's own limit events only report while an agent works.
//!
//! Nook never touches an agent's login. For Claude Code it asks the official `claude` CLI the `get_usage` control
//! request (the numbers of `/usage`) in an empty folder with only project settings, so no hooks fire and no prompt is
//! sent: a reading costs no usage. For Codex it starts `codex app-server` with the account's `CODEX_HOME` and asks
//! `account/rateLimits/read`, the source of Codex's own `/status`; the same server spends a reset credit when you ask.

use std::collections::{BTreeMap, HashSet};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Datelike, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::models::{PlanUsage, PlanWindow};

/// The background timer reads an account at most this often: a usage view, a turn or a limit event reads sooner.
pub const BACKGROUND_INTERVAL: Duration = Duration::from_secs(60 * 60);
/// `refresh_now` (a usage view opens, a turn ended) asks again at most this often per account.
pub const MINIMUM_INTERVAL: Duration = Duration::from_secs(60);
/// The refresh button asks again at most this often per account, however often it is clicked.
pub const MANUAL_INTERVAL: Duration = Duration::from_secs(10);
/// Length of a 5-hour session window in seconds.
pub const FIVE_HOURS_SECS: i64 = 5 * 3600;
/// Length of a weekly window in seconds.
pub const WEEK_SECS: i64 = 7 * 24 * 3600;

fn number(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// The body of Claude Code's `get_usage` reply as plan windows (`UsageLimits.claudeUsageReply`): `rate_limits` with
/// `five_hour` and `seven_day`, each a `utilization` in percent and an ISO `resets_at`.
pub fn claude_usage_reply(response: &Value, now: DateTime<Utc>) -> Option<PlanUsage> {
    let limits = response.get("rate_limits")?;
    let window = |key: &str| -> Option<PlanWindow> {
        let raw = limits.get(key)?;
        let percent = number(raw.get("utilization"))?;
        let reset = raw.get("resets_at")?.as_str().and_then(|t| DateTime::parse_from_rfc3339(t).ok())?.with_timezone(&Utc);
        Some(PlanWindow { used_percent: percent.clamp(0.0, 100.0), resets_at: reset })
    };
    let (five_hour, seven_day) = (window("five_hour"), window("seven_day"));
    (five_hour.is_some() || seven_day.is_some()).then_some(PlanUsage { five_hour, seven_day, updated: now })
}

/// One Codex window: its use, when it resets and how long it lasts.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexWindow {
    pub used_percent: f64,
    pub resets_at: Option<DateTime<Utc>>,
    pub window_minutes: Option<i64>,
}

/// Reset credits the account has banked: each one empties the 5-hour and weekly windows at once.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCredits {
    pub available: i64,
    pub next_expires_at: Option<DateTime<Utc>>,
}

/// A Codex account's limits (`CodexUsageSnapshot`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexUsage {
    pub five_hour: Option<CodexWindow>,
    pub weekly: Option<CodexWindow>,
    pub plan_type: Option<String>,
    pub updated: DateTime<Utc>,
    pub reset_credits: Option<ResetCredits>,
}

impl CodexUsage {
    /// The same windows in the shape the rest of Nook shows (`PlanUsage`); a window without a reset time is left out.
    pub fn plan_usage(&self) -> PlanUsage {
        let w =
            |w: &Option<CodexWindow>| w.as_ref().and_then(|w| Some(PlanWindow { used_percent: w.used_percent, resets_at: w.resets_at? }));
        PlanUsage { five_hour: w(&self.five_hour), seven_day: w(&self.weekly), updated: self.updated }
    }

    /// Capitalized plan name (`"plus"` → `"Plus"`, `"pro"` → `"Pro"`), matching `QuotaService.codexPlan` on the Mac.
    pub fn plan_display(&self) -> Option<String> {
        let raw = self.plan_type.as_deref()?.trim();
        if raw.is_empty() {
            return None;
        }
        let mut chars = raw.chars();
        let first = chars.next()?.to_uppercase().to_string();
        Some(format!("{first}{}", chars.as_str()))
    }
}

fn codex_window(value: Option<&Value>, at: DateTime<Utc>) -> Option<CodexWindow> {
    let raw = value?;
    let percent = number(raw.get("usedPercent")).or_else(|| number(raw.get("used_percent")))?;
    let minutes = number(raw.get("windowDurationMins")).or_else(|| number(raw.get("window_minutes"))).map(|m| m as i64);
    let reset = number(raw.get("resetsAt"))
        .or_else(|| number(raw.get("resets_at")))
        .and_then(|s| Utc.timestamp_opt(s as i64, 0).single())
        .or_else(|| {
            number(raw.get("resetsInSeconds"))
                .or_else(|| number(raw.get("resets_in_seconds")))
                .map(|s| at + chrono::Duration::seconds(s as i64))
        });
    Some(CodexWindow { used_percent: percent.clamp(0.0, 100.0), resets_at: reset, window_minutes: minutes })
}

/// The windows of a Codex rate-limit snapshot: primary and secondary are not fixed, the length says which is which (a
/// day or shorter is the 5-hour one); without a length primary is the short one.
fn codex_windows(limits: &Value, at: DateTime<Utc>) -> CodexUsage {
    let mut usage = CodexUsage {
        five_hour: None,
        weekly: None,
        plan_type: limits.get("planType").or_else(|| limits.get("plan_type")).and_then(Value::as_str).map(str::to_string),
        updated: at,
        reset_credits: None,
    };
    for (index, key) in ["primary", "secondary"].into_iter().enumerate() {
        let Some(window) = codex_window(limits.get(key), at) else { continue };
        let short = window.window_minutes.map_or(index == 0, |m| m <= 24 * 60);
        if short {
            usage.five_hour = Some(window);
        } else {
            usage.weekly = Some(window);
        }
    }
    usage
}

/// An `account/rateLimits/read` answer (`CodexRateLimits.snapshot`); `None` without any window.
pub fn codex_snapshot(result: &Value, at: DateTime<Utc>) -> Option<CodexUsage> {
    let mut usage = codex_windows(result.get("rateLimits")?, at);
    if usage.five_hour.is_none() && usage.weekly.is_none() {
        return None;
    }
    usage.reset_credits = result.get("rateLimitResetCredits").and_then(|summary| {
        let available = number(summary.get("availableCount"))? as i64;
        let next = summary
            .get("credits")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|c| c.get("status").and_then(Value::as_str) == Some("available"))
            .filter_map(|c| number(c.get("expiresAt")))
            .fold(None::<f64>, |min, e| Some(min.map_or(e, |m| m.min(e))))
            .and_then(|s| Utc.timestamp_opt(s as i64, 0).single());
        Some(ResetCredits { available: available.max(0), next_expires_at: next })
    });
    Some(usage)
}

/// An `account/rateLimits/updated` from a working session laid over what was shown: the update may name one window;
/// a model's own allowance (`limitId` other than "codex") never overwrites the account's main one.
pub fn codex_merge(params: &Value, previous: Option<&CodexUsage>, at: DateTime<Utc>) -> Option<CodexUsage> {
    let limits = params.get("rateLimits")?;
    if limits.get("limitId").and_then(Value::as_str).is_some_and(|id| id != "codex") {
        return None;
    }
    let fresh = codex_windows(limits, at);
    if fresh.five_hour.is_none() && fresh.weekly.is_none() {
        return None;
    }
    let mut usage =
        previous.cloned().unwrap_or(CodexUsage { five_hour: None, weekly: None, plan_type: None, updated: at, reset_credits: None });
    if fresh.five_hour.is_some() {
        usage.five_hour = fresh.five_hour;
    }
    if fresh.weekly.is_some() {
        usage.weekly = fresh.weekly;
    }
    if fresh.plan_type.is_some() {
        usage.plan_type = fresh.plan_type;
    }
    usage.updated = at;
    Some(usage)
}

/// What spending a reset credit did (`account/rateLimitResetCredit/consume`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ResetOutcome {
    Reset,
    NothingToReset,
    NoCredit,
    AlreadyRedeemed,
    Failed,
}

pub fn reset_outcome(result: &Value) -> ResetOutcome {
    match result.get("outcome").and_then(Value::as_str) {
        Some("reset") => ResetOutcome::Reset,
        Some("nothingToReset") => ResetOutcome::NothingToReset,
        Some("noCredit") => ResetOutcome::NoCredit,
        Some("alreadyRedeemed") => ResetOutcome::AlreadyRedeemed,
        _ => ResetOutcome::Failed,
    }
}

/// Runs `program args` with `env`, writes `input` and returns the first stdout line `pick` accepts, within `timeout`.
/// The process is ended either way. `close_input`: end stdin after writing (Claude Code exits once its input ends).
fn exchange(
    program: &str,
    args: &[&str],
    env: &BTreeMap<String, String>,
    cwd: Option<&Path>,
    input: String,
    close_input: bool,
    timeout: Duration,
    pick: impl Fn(&Value) -> Option<Value> + Send + 'static,
) -> Option<Value> {
    let mut cmd = Command::new(program);
    cmd.args(args).env_clear().envs(env).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let mut child = cmd.spawn().ok()?;
    let mut stdin = child.stdin.take()?;
    let stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if let Some(found) = serde_json::from_str::<Value>(&line).ok().as_ref().and_then(&pick) {
                let _ = tx.send(found);
                return;
            }
        }
    });
    let written = stdin.write_all(input.as_bytes()).and_then(|_| stdin.flush()).is_ok();
    // Codex's app-server ends when its input does: keep it open until the answer is in.
    let keep = if close_input {
        drop(stdin);
        None
    } else {
        Some(stdin)
    };
    let answer = if written { rx.recv_timeout(timeout).ok() } else { None };
    drop(keep);
    let _ = child.kill();
    let _ = child.wait();
    answer
}

/// One control request to `claude` outside a session (`ClaudeControl.ask`): the body of a successful reply.
pub fn claude_control(executable: &str, extra: &BTreeMap<String, String>, request: Value, timeout: Duration) -> Option<Value> {
    let request_id = format!("nook-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
    let line = json!({"type": "control_request", "request_id": request_id, "request": request}).to_string() + "\n";
    let base: BTreeMap<String, String> = std::env::vars().collect();
    let mut env = crate::workspace::command::environment(&base, executable, extra);
    env.insert("NOOK_INTERNAL".into(), "1".into());
    let folder = crate::paths::brain_scratch_directory();
    let _ = std::fs::create_dir_all(&folder);
    let args = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--setting-sources",
        "project",
    ];
    let answer = exchange(executable, &args, &env, Some(&folder), line, true, timeout, move |object| {
        let response = object.get("response").filter(|_| object.get("type").and_then(Value::as_str) == Some("control_response"))?;
        if response.get("request_id").and_then(Value::as_str) != Some(request_id.as_str()) {
            return None;
        }
        Some(if response.get("subtype").and_then(Value::as_str) == Some("success") {
            response.get("response").cloned().unwrap_or(Value::Null)
        } else {
            Value::Null
        })
    })?;
    (!answer.is_null()).then_some(answer)
}

/// The limits of one Claude account, `None` when it is not signed in with a subscription or Claude Code did not answer.
pub fn read_claude(executable: &str, extra: &BTreeMap<String, String>) -> Option<PlanUsage> {
    claude_control(executable, extra, json!({"subtype": "get_usage", "skip_behaviors": true}), Duration::from_secs(20))
        .and_then(|r| claude_usage_reply(&r, Utc::now()))
}

/// Starts `codex app-server` for one account (`CODEX_HOME` = `home`, or the default), sends one request after the
/// handshake and returns its `result`.
pub fn codex_request(executable: &str, home: Option<&str>, method: &str, params: Option<Value>, timeout: Duration) -> Option<Value> {
    let base: BTreeMap<String, String> = std::env::vars().collect();
    let mut extra = BTreeMap::new();
    if let Some(home) = home.filter(|h| !h.is_empty()) {
        extra.insert("CODEX_HOME".to_string(), home.to_string());
    }
    let env = crate::workspace::command::environment(&base, executable, &extra);
    let mut call = json!({"id": 2, "method": method});
    if let Some(p) = params {
        call["params"] = p;
    }
    let input = [
        json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "nook", "version": "1"}}}).to_string(),
        json!({"method": "initialized"}).to_string(),
        call.to_string(),
    ]
    .join("\n")
        + "\n";
    exchange(executable, &["app-server"], &env, None, input, false, timeout, |object| {
        (number(object.get("id")) == Some(2.0)).then(|| object.get("result").cloned().unwrap_or(Value::Null))
    })
    .filter(|v| !v.is_null())
}

pub fn read_codex(executable: &str, home: Option<&str>) -> Option<CodexUsage> {
    codex_request(executable, home, "account/rateLimits/read", None, Duration::from_secs(15)).and_then(|r| codex_snapshot(&r, Utc::now()))
}

/// Resolves the Codex home directory for an account (`home`, else `CODEX_HOME`, else `~/.codex`).
pub fn codex_home_dir(home: Option<&str>) -> PathBuf {
    if let Some(h) = home.filter(|h| !h.trim().is_empty()) {
        return PathBuf::from(h);
    }
    if let Ok(env_home) = std::env::var("CODEX_HOME") {
        if !env_home.trim().is_empty() {
            return PathBuf::from(env_home);
        }
    }
    super::AgentKind::Codex.default_home()
}

/// Searches backwards in the tail (up to 512 KB) of one Codex rollout `.jsonl` file for the latest `rate_limits`
/// reading (`CodexUsage.readSessionLog` on the Mac).
pub fn read_codex_log_file(path: &Path, fallback_at: DateTime<Utc>) -> Option<CodexUsage> {
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    const TAIL_SIZE: u64 = 512 * 1024;
    if size > TAIL_SIZE {
        file.seek(SeekFrom::Start(size - TAIL_SIZE)).ok()?;
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    for line in text.lines().rev() {
        if !line.contains("\"rate_limits\"") {
            continue;
        }
        let Ok(object) = serde_json::from_str::<Value>(line) else { continue };
        let payload = object.get("payload").unwrap_or(&object);
        let Some(limits) = payload.get("rate_limits") else { continue };
        let at = object
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or(fallback_at);
        let usage = codex_windows(limits, at);
        if usage.five_hour.is_some() || usage.weekly.is_some() {
            return Some(usage);
        }
    }
    None
}

/// Reads the newest Codex rollout session log under `<codex_home>/sessions/YYYY/MM/DD/` (looking 1 day ahead and 8 days
/// back so UTC and local day names both match), falling back across up to 3 recent logs (`CodexUsage.recentSessionFiles`).
pub fn read_codex_session_log(home: Option<&str>) -> Option<CodexUsage> {
    let root = codex_home_dir(home).join("sessions");
    if !root.is_dir() {
        return None;
    }
    let now = Utc::now();
    let mut files: Vec<(PathBuf, SystemTime)> = Vec::new();
    let mut seen_days = HashSet::new();
    for offset in -1..=8 {
        let day = now - chrono::Duration::days(offset);
        let rel = format!("{:04}/{:02}/{:02}", day.year(), day.month(), day.day());
        if !seen_days.insert(rel.clone()) {
            continue;
        }
        let dir = root.join(rel);
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                continue;
            }
            if let Ok(meta) = entry.metadata() {
                let mtime = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                files.push((entry.path(), mtime));
            }
        }
        if files.len() >= 3 && offset >= 1 {
            break;
        }
    }
    files.sort_by_key(|b| std::cmp::Reverse(b.1));
    for (path, mtime) in files.into_iter().take(3) {
        let at: DateTime<Utc> = mtime.into();
        if let Some(usage) = read_codex_log_file(&path, at) {
            return Some(usage);
        }
    }
    None
}

/// Reads Codex limits from `codex app-server`, falling back to recent session logs when offline or unavailable.
/// A session log reading keeps the `plan_type` and `reset_credits` from `previous`, as only app-server reports them.
pub fn read_codex_with_fallback(executable: Option<&str>, home: Option<&str>, previous: Option<&CodexUsage>) -> Option<CodexUsage> {
    if let Some(exe) = executable {
        if let Some(fresh) = read_codex(exe, home) {
            return Some(fresh);
        }
    }
    let mut fallback = read_codex_session_log(home)?;
    if let Some(prev) = previous {
        if fallback.plan_type.is_none() {
            fallback.plan_type = prev.plan_type.clone();
        }
        fallback.reset_credits = prev.reset_credits.clone();
    }
    Some(fallback)
}

/// Spends one reset credit; `key` makes a retry of the same click harmless.
pub fn use_reset_credit(executable: &str, home: Option<&str>, key: &str) -> ResetOutcome {
    codex_request(executable, home, "account/rateLimitResetCredit/consume", Some(json!({"idempotencyKey": key})), Duration::from_secs(20))
        .map_or(ResetOutcome::Failed, |r| reset_outcome(&r))
}

// MARK: - Generic QuotaLimit & Antigravity quota (AG-48)

/// One subscription window (`QuotaLimit` on the Mac): "5 hours" at 34%, resetting at some time, or an idle note.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaLimit {
    pub label: String,
    pub percent: f64,
    pub resets_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
    pub duration_secs: Option<i64>,
}

impl QuotaLimit {
    /// Settles an Antigravity window (`QuotaService.settled`): one that has already reset, or that has not started yet
    /// (nothing used and its reset still a whole window away), reads as 0% starting with the next message.
    pub fn settled(&self, now: DateTime<Utc>) -> Self {
        let Some(resets_at) = self.resets_at else { return self.clone() };
        let passed = resets_at <= now;
        let unstarted = self.percent < 0.5 && self.duration_secs.is_some_and(|d| (resets_at - now).num_seconds() > d - 15 * 60);
        if passed || unstarted {
            Self {
                label: self.label.clone(),
                percent: 0.0,
                resets_at: None,
                note: Some(crate::i18n::tr("Start bij je eerste bericht", "Starts with your first message").to_string()),
                duration_secs: self.duration_secs,
            }
        } else {
            self.clone()
        }
    }
}

/// Credentials read from Antigravity's own sign-in file (`<GEMINI_HOME>/antigravity-acp/acp_token.json`).
#[derive(Debug, Clone, Default)]
pub struct AntigravityCreds {
    pub client_id: Option<String>,
    pub client_secret: Option<String>,
    pub refresh_token: Option<String>,
    pub access_token: Option<String>,
    pub project_id: Option<String>,
}

impl AntigravityCreds {
    pub fn can_refresh(&self) -> bool {
        self.refresh_token.as_deref().is_some_and(|s| !s.is_empty())
            && self.client_id.as_deref().is_some_and(|s| !s.is_empty())
            && self.client_secret.as_deref().is_some_and(|s| !s.is_empty())
    }
}

/// Outcome of reading Antigravity's quota.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AntigravityReading {
    pub limits: Vec<QuotaLimit>,
    pub no_login: bool,
}

const ANTIGRAVITY_ENDPOINTS: [&str; 2] = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"];

/// Whether a model or bucket belongs to a third-party provider (Claude, GPT, etc.) not counted under Antigravity.
pub fn antigravity_is_third_party(text: &str) -> bool {
    let lower = text.to_lowercase();
    ["claude", "gpt", "openai", "anthropic", "3p", "oss"].iter().any(|k| lower.contains(k))
}

/// Model IDs that are Antigravity's own helpers (autocomplete, chat titles, images), not models you pick.
pub fn antigravity_is_helper(id: &str) -> bool {
    let lower = id.to_lowercase();
    lower.starts_with("chat_")
        || lower.starts_with("tab_")
        || ["internal", "autocomplete", "lite", "image"].iter().any(|k| lower.contains(k))
        || lower.ends_with("-exp")
        || lower.ends_with("-agent")
        || lower.ends_with("disabled")
}

/// A readable model name from an id: `"gemini-4-pro-high"` → `"Gemini 4 Pro"`, `"claude-sonnet-4-5"` → `"Claude Sonnet 4.5"`.
pub fn antigravity_model_name(id: &str) -> String {
    const DROPPED: &[&str] = &[
        "3p",
        "5h",
        "weekly",
        "week",
        "daily",
        "quota",
        "bucket",
        "high",
        "low",
        "medium",
        "thinking",
        "preview",
        "latest",
        "exp",
        "experimental",
    ];
    let mut parts: Vec<String> = Vec::new();
    for word in id.to_lowercase().split(['-', '_', ' ']).filter(|w| !w.is_empty()) {
        if DROPPED.contains(&word) || (word.len() > 2 && word.chars().all(|c| c.is_ascii_digit())) {
            continue;
        }
        let all_digits = word.chars().all(|c| c.is_ascii_digit());
        if all_digits && parts.last().is_some_and(|last| last.chars().all(|c| c.is_ascii_digit() || c == '.')) {
            if let Some(last) = parts.last_mut() {
                last.push('.');
                last.push_str(word);
            }
            continue;
        }
        let nice = match word {
            "gemini" => "Gemini".to_string(),
            "claude" => "Claude".to_string(),
            "gpt" => "GPT".to_string(),
            "oss" => "OSS".to_string(),
            other => {
                let mut cs = other.chars();
                match cs.next() {
                    Some(c) => format!("{}{}", c.to_uppercase(), cs.as_str()),
                    None => String::new(),
                }
            }
        };
        parts.push(nice);
    }
    parts.join(" ")
}

fn antigravity_remaining_fraction(quota: &Value) -> Option<f64> {
    if let Some(v) = number(quota.get("remainingFraction").or_else(|| quota.get("remaining_fraction"))) {
        return Some(v);
    }
    let nested = quota.get("remaining")?;
    if let Some(v) = number(nested.get("remainingFraction").or_else(|| nested.get("remaining_fraction"))) {
        return Some(v);
    }
    if nested.get("case").and_then(Value::as_str) == Some("remainingFraction") {
        return number(nested.get("value"));
    }
    None
}

fn antigravity_reset_date(quota: &Value) -> Option<DateTime<Utc>> {
    let v = quota.get("resetTime").or_else(|| quota.get("reset_time"))?;
    if let Some(s) = v.as_str() {
        if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
            return Some(dt.with_timezone(&Utc));
        }
        if let Ok(secs) = s.trim().parse::<f64>() {
            return Utc.timestamp_opt(secs as i64, 0).single();
        }
    }
    number(Some(v)).and_then(|secs| Utc.timestamp_opt(secs as i64, 0).single())
}

fn antigravity_limit(label: String, quota: &Value, duration_secs: Option<i64>) -> Option<QuotaLimit> {
    if quota.get("disabled").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let resets_at = antigravity_reset_date(quota);
    let remaining = antigravity_remaining_fraction(quota).or_else(|| resets_at.map(|_| 0.0))?;
    let percent = (1.0 - remaining.clamp(0.0, 1.0)) * 100.0;
    Some(QuotaLimit { label, percent, resets_at, note: None, duration_secs })
}

fn antigravity_merge(windows: Vec<QuotaLimit>, list: &mut Vec<QuotaLimit>) {
    for window in windows {
        if let Some(existing) = list.iter_mut().find(|w| w.label == window.label) {
            if window.percent > existing.percent {
                *existing = window;
            }
        } else {
            list.push(window);
        }
    }
}

fn antigravity_window_span(window: Option<&str>, id: &str, name: &str) -> Option<i64> {
    let text = format!("{} {} {}", window.unwrap_or(""), id, name).to_lowercase();
    if window == Some("5h") || text.contains("5h") || text.contains("five hour") {
        return Some(FIVE_HOURS_SECS);
    }
    if window == Some("weekly") || text.contains("weekly") || text.contains("week") {
        return Some(WEEK_SECS);
    }
    None
}

fn strip_models_suffix(s: &str) -> String {
    let trimmed = s.trim();
    let lower = trimmed.to_lowercase();
    for suffix in [" models", " model"] {
        if lower.ends_with(suffix) {
            return trimmed[..trimmed.len() - suffix.len()].trim().to_string();
        }
    }
    trimmed.to_string()
}

/// Parses `retrieveUserQuotaSummary` windows (`AntigravityUsage.summaryWindows`).
pub fn antigravity_summary_windows(object: &Value) -> Vec<QuotaLimit> {
    let root = object
        .get("response")
        .or_else(|| object.get("summary"))
        .or_else(|| object.get("command").and_then(|c| c.get("data")))
        .unwrap_or(object);
    let groups = root.get("groups").and_then(Value::as_array);
    let has_group_buckets =
        groups.is_some_and(|gs| gs.iter().any(|g| g.get("buckets").and_then(Value::as_array).is_some_and(|b| !b.is_empty())));
    let sources: Vec<(String, Vec<&Value>)> = if has_group_buckets {
        groups
            .unwrap()
            .iter()
            .map(|g| {
                let name = g.get("displayName").or_else(|| g.get("name")).and_then(Value::as_str).unwrap_or("").to_string();
                let buckets = g.get("buckets").and_then(Value::as_array).map(|a| a.iter().collect()).unwrap_or_default();
                (name, buckets)
            })
            .collect()
    } else {
        let buckets = root.get("buckets").and_then(Value::as_array).map(|a| a.iter().collect()).unwrap_or_default();
        vec![(String::new(), buckets)]
    };

    let five_h_label = crate::i18n::tr("5 uur", "5 hours");
    let week_label = crate::i18n::tr("Week", "Week");
    let quota_label = crate::i18n::tr("Quotum", "Quota");

    let mut result = Vec::new();
    for (source_name, buckets) in sources {
        if antigravity_is_third_party(&source_name) {
            continue;
        }
        let mut group: Vec<(u8, usize, QuotaLimit)> = Vec::new();
        for (idx, bucket) in buckets.into_iter().enumerate() {
            let Some(id) = bucket.get("bucketId").or_else(|| bucket.get("id")).and_then(Value::as_str) else { continue };
            if antigravity_is_third_party(id) {
                continue;
            }
            let name = bucket.get("displayName").or_else(|| bucket.get("name")).and_then(Value::as_str).unwrap_or("").trim();
            let span = antigravity_window_span(bucket.get("window").and_then(Value::as_str), id, name);
            let family = {
                let lowered = format!("{id} {source_name}").to_lowercase();
                if id.starts_with("gemini-") || lowered.contains("gemini") {
                    "Gemini".to_string()
                } else {
                    let t = source_name.trim();
                    if t.is_empty() {
                        id.to_string()
                    } else {
                        t.to_string()
                    }
                }
            };
            let kind = match span {
                Some(FIVE_HOURS_SECS) => five_h_label,
                Some(WEEK_SECS) => week_label,
                _ => {
                    if name.is_empty() {
                        quota_label
                    } else {
                        name
                    }
                }
            };
            let model = antigravity_model_name(id);
            let group_name = strip_models_suffix(&source_name);
            let title = if model.chars().any(|c| c.is_ascii_digit()) {
                model
            } else if group_name.chars().any(|c| c.is_ascii_digit()) {
                group_name
            } else {
                family
            };
            let Some(entry) = antigravity_limit(format!("{title} · {kind}"), bucket, span) else { continue };
            let order = match span {
                Some(FIVE_HOURS_SECS) => 0,
                Some(WEEK_SECS) => 1,
                _ => 2,
            };
            group.push((order, idx, entry));
        }
        group.sort_by_key(|(order, idx, _)| (*order, *idx));
        antigravity_merge(group.into_iter().map(|(_, _, w)| w).collect(), &mut result);
    }
    result
}

/// Parses `fetchAvailableModels` per-model quotas (`AntigravityUsage.modelWindows`).
pub fn antigravity_model_windows(object: &Value) -> Vec<QuotaLimit> {
    let Some(models) = object.get("models").and_then(Value::as_object) else { return vec![] };
    let picker: HashSet<String> = object
        .get("agentModelSorts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|s| s.get("groups").and_then(Value::as_array))
        .flatten()
        .filter_map(|g| g.get("modelIds").and_then(Value::as_array))
        .flatten()
        .filter_map(|id| id.as_str().map(str::to_string))
        .collect();
    let quota_label = crate::i18n::tr("Quotum", "Quota");
    let week_label = crate::i18n::tr("Week", "Week");

    let mut keys: Vec<&String> = models.keys().collect();
    keys.sort();
    let mut result = Vec::new();
    for id in keys {
        let model = &models[id];
        if model.get("disabled").and_then(Value::as_bool) == Some(true)
            || antigravity_is_helper(id)
            || antigravity_is_third_party(id)
            || (!picker.is_empty() && !picker.contains(id))
        {
            continue;
        }
        let provider = model.get("modelProvider").and_then(Value::as_str);
        if provider != Some("MODEL_PROVIDER_GOOGLE") && !id.starts_with("gemini-") {
            continue;
        }
        let display = model
            .get("displayName")
            .and_then(Value::as_str)
            .map(|s| {
                // Strip parenthesized tags like "(Preview)".
                let mut out = String::new();
                let mut depth = 0usize;
                for ch in s.chars() {
                    match ch {
                        '(' => depth += 1,
                        ')' if depth > 0 => depth -= 1,
                        _ if depth == 0 => out.push(ch),
                        _ => {}
                    }
                }
                out.trim().to_string()
            })
            .unwrap_or_default();
        let derived = antigravity_model_name(id);
        let name = if !display.is_empty() {
            display
        } else if !derived.is_empty() {
            derived
        } else {
            "Gemini".to_string()
        };
        for (key, suffix, span) in [("quotaInfo", quota_label, None), ("weeklyQuotaInfo", week_label, Some(WEEK_SECS))] {
            let Some(quota) = model.get(key) else { continue };
            let Some(entry) = antigravity_limit(format!("{name} · {suffix}"), quota, span) else { continue };
            antigravity_merge(vec![entry], &mut result);
        }
    }
    result.sort_by_key(|a| a.label.to_lowercase());
    result
}

/// Looks for Antigravity's sign-in file under `homes` (`antigravity-acp/acp_token.json` and nearby `.json` files,
/// never `<home>/oauth_creds.json` which belongs to Gemini CLI).
pub fn antigravity_credentials(homes: &[PathBuf]) -> Option<AntigravityCreds> {
    let mut candidates = Vec::new();
    for home in homes {
        candidates.push(home.join("antigravity-acp").join("acp_token.json"));
        for folder in ["antigravity-acp", "antigravity", "antigravity-cli", "config"] {
            let dir = home.join(folder);
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            let mut names: Vec<PathBuf> =
                entries.flatten().map(|e| e.path()).filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json")).collect();
            names.sort();
            candidates.extend(names);
        }
    }
    let now_secs = Utc::now().timestamp() as f64;
    for path in candidates {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let Ok(file) = serde_json::from_str::<Value>(&text) else { continue };
        let access = number(file.get("expiry_date"))
            .filter(|ms| ms / 1000.0 > now_secs + 60.0)
            .and_then(|_| file.get("access_token").and_then(Value::as_str).map(str::to_string));
        let creds = AntigravityCreds {
            client_id: file.get("client_id").and_then(Value::as_str).map(str::to_string),
            client_secret: file.get("client_secret").and_then(Value::as_str).map(str::to_string),
            refresh_token: file.get("refresh_token").and_then(Value::as_str).map(str::to_string),
            access_token: access,
            project_id: file.get("project_id").and_then(Value::as_str).map(str::to_string),
        };
        if creds.can_refresh() || creds.access_token.is_some() {
            return Some(creds);
        }
    }
    None
}

type AntigravityTokenCache = Mutex<BTreeMap<String, (String, DateTime<Utc>)>>;

fn antigravity_token_cache() -> &'static AntigravityTokenCache {
    static CACHE: OnceLock<AntigravityTokenCache> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

/// Reads Antigravity's quota windows from Google's Cloud Code endpoints using the local sign-in token.
pub async fn read_antigravity(homes: &[PathBuf]) -> AntigravityReading {
    let Some(creds) = antigravity_credentials(homes) else {
        return AntigravityReading { limits: vec![], no_login: true };
    };
    let Ok(client) = reqwest::Client::builder().timeout(Duration::from_secs(10)).build() else {
        return AntigravityReading { limits: vec![], no_login: false };
    };
    let mut access = creds.access_token.clone();
    if access.is_none() && creds.can_refresh() {
        let client_id = creds.client_id.as_deref().unwrap_or_default();
        let client_secret = creds.client_secret.as_deref().unwrap_or_default();
        let refresh = creds.refresh_token.as_deref().unwrap_or_default();
        let cache_key = format!("{client_id}\0{refresh}");
        if let Some((tok, until)) = antigravity_token_cache().lock().ok().and_then(|c| c.get(&cache_key).cloned()) {
            if until > Utc::now() {
                access = Some(tok);
            }
        }
        if access.is_none() {
            let form =
                [("client_id", client_id), ("client_secret", client_secret), ("refresh_token", refresh), ("grant_type", "refresh_token")];
            if let Ok(resp) = client.post("https://oauth2.googleapis.com/token").form(&form).send().await {
                if resp.status().is_success() {
                    if let Ok(body) = resp.json::<Value>().await {
                        if let Some(tok) = body.get("access_token").and_then(Value::as_str) {
                            if let Some(secs) = number(body.get("expires_in")).filter(|&s| s > 60.0) {
                                let until = Utc::now() + chrono::Duration::seconds(secs as i64 - 60);
                                if let Ok(mut cache) = antigravity_token_cache().lock() {
                                    cache.insert(cache_key, (tok.to_string(), until));
                                }
                            }
                            access = Some(tok.to_string());
                        }
                    }
                }
            }
        }
    }
    let Some(access) = access else {
        return AntigravityReading { limits: vec![], no_login: false };
    };

    let os_type = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "x64" };
    let user_agent = format!("antigravity/hub/2.24.0 (aidev_client; os_type={os_type}; arch={arch}; cl=1000335682)");
    let body = match &creds.project_id {
        Some(p) if !p.is_empty() => json!({"project": p}),
        _ => json!({}),
    };

    let ask = |op: &'static str| {
        let client = client.clone();
        let access = access.clone();
        let user_agent = user_agent.clone();
        let body = body.clone();
        async move {
            let mut answers = Vec::new();
            for endpoint in ANTIGRAVITY_ENDPOINTS {
                let url = format!("{endpoint}/v1internal:{op}");
                if let Ok(resp) = client.post(url).bearer_auth(&access).header("User-Agent", &user_agent).json(&body).send().await {
                    if resp.status().is_success() {
                        if let Ok(v) = resp.json::<Value>().await {
                            answers.push(v);
                        }
                    }
                }
            }
            answers
        }
    };

    let mut summary = Vec::new();
    for answer in ask("retrieveUserQuotaSummary").await {
        antigravity_merge(antigravity_summary_windows(&answer), &mut summary);
    }
    if !summary.is_empty() {
        return AntigravityReading { limits: summary, no_login: false };
    }

    let mut models = Vec::new();
    for answer in ask("fetchAvailableModels").await {
        antigravity_merge(antigravity_model_windows(&answer), &mut models);
    }
    if models.iter().any(|w| w.percent > 0.0) {
        return AntigravityReading { limits: models, no_login: false };
    }
    AntigravityReading { limits: vec![], no_login: false }
}

// MARK: - CLIProxyAPI Hub validation & reply parsing (AG-48)

/// A CLIProxyAPI hub pooling multiple accounts behind one address (`CLIProxyHub` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyHub {
    pub id: String,
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliProxyAddressError {
    Invalid,
    Insecure,
}

impl CliProxyHub {
    pub fn name(&self) -> String {
        let trimmed = self.label.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
        url::Url::parse(&self.url).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_else(|| self.url.clone())
    }

    pub fn secret_account(&self) -> String {
        format!("cliproxy.hub.{}", self.id)
    }

    /// Validates and normalizes a hub address: plain `http` is allowed only on loopback or private LAN hosts.
    pub fn base(text: &str) -> Result<url::Url, CliProxyAddressError> {
        let mut trimmed = text.trim().to_string();
        if trimmed.is_empty() {
            return Err(CliProxyAddressError::Invalid);
        }
        if !trimmed.contains("://") {
            trimmed = format!("http://{trimmed}");
        }
        let mut parsed = url::Url::parse(&trimmed).map_err(|_| CliProxyAddressError::Invalid)?;
        let scheme = parsed.scheme();
        if scheme != "http" && scheme != "https" {
            return Err(CliProxyAddressError::Invalid);
        }
        if !parsed.username().is_empty() || parsed.password().is_some() {
            return Err(CliProxyAddressError::Invalid);
        }
        let host = parsed.host_str().ok_or(CliProxyAddressError::Invalid)?;
        if scheme == "http" && !Self::is_local_host(host) {
            return Err(CliProxyAddressError::Insecure);
        }
        let mut path = parsed.path().to_string();
        if path.to_lowercase().ends_with("/management.html") {
            path.truncate(path.len() - "/management.html".len());
        }
        while path.ends_with('/') {
            path.pop();
        }
        path.push('/');
        parsed.set_path(&path);
        parsed.set_query(None);
        parsed.set_fragment(None);
        Ok(parsed)
    }

    pub fn management_url(base: &url::Url, path: &str) -> Option<url::Url> {
        base.join(&format!("v0/management/{path}")).ok()
    }

    pub fn is_local_host(host: &str) -> bool {
        let name = host.to_lowercase();
        if name == "localhost" || name == "::1" || name == "[::1]" || name.ends_with(".local") || name.ends_with(".localhost") {
            return true;
        }
        let parts: Vec<&str> = name.split('.').collect();
        if parts.len() != 4 {
            return false;
        }
        let octets: Vec<u8> = parts.iter().filter_map(|p| p.parse::<u8>().ok()).collect();
        if octets.len() != 4 {
            return false;
        }
        matches!((octets[0], octets[1]), (127, _) | (10, _) | (192, 168) | (169, 254) | (172, 16..=31))
    }
}

/// One window reported by a CLIProxyAPI hub's observed headers.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyWindow {
    pub key: String,
    pub used_percent: f64,
    pub resets_at: Option<DateTime<Utc>>,
    pub duration_secs: Option<i64>,
}

/// One account inside a CLIProxyAPI hub (`GET /v0/management/auth-files`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyAccount {
    pub id: String,
    pub provider: String,
    pub email: Option<String>,
    pub label: String,
    pub disabled: bool,
    pub status: String,
    pub status_message: Option<String>,
    pub unavailable: bool,
    pub retry_at: Option<DateTime<Utc>>,
    pub succeeded: i64,
    pub failed: i64,
    pub signals: BTreeMap<String, String>,
    pub signals_observed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CliProxyProblem {
    NoKey,
    BadAddress,
    InsecureAddress,
    RejectedKey,
    Unreachable,
    NotAHub,
}

impl From<CliProxyAddressError> for CliProxyProblem {
    fn from(value: CliProxyAddressError) -> Self {
        match value {
            CliProxyAddressError::Invalid => Self::BadAddress,
            CliProxyAddressError::Insecure => Self::InsecureAddress,
        }
    }
}

/// Persisted list of CLIProxyAPI hubs (`cliproxy-hubs.json` in Nook's support directory).
#[derive(Debug, Default)]
pub struct CliProxyHubStore {
    path: Option<PathBuf>,
    hubs: Vec<CliProxyHub>,
}

impl CliProxyHubStore {
    pub fn load(path: Option<PathBuf>) -> Self {
        let hubs = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str::<Vec<CliProxyHub>>(&s).ok())
            .unwrap_or_default();
        Self { path, hubs }
    }

    pub fn all(&self) -> Vec<CliProxyHub> {
        self.hubs.clone()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.hubs.iter().any(|h| h.id == id)
    }

    pub fn add(&mut self, hub: CliProxyHub) -> CliProxyHub {
        self.hubs.push(hub.clone());
        self.save();
        hub
    }

    pub fn remove(&mut self, id: &str) -> Option<CliProxyHub> {
        let idx = self.hubs.iter().position(|h| h.id == id)?;
        let removed = self.hubs.remove(idx);
        self.save();
        Some(removed)
    }

    fn save(&self) {
        let Some(path) = &self.path else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(text) = serde_json::to_string_pretty(&self.hubs) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, path);
            }
        }
    }
}

/// Settled view of one CLIProxyAPI pooled account for the UI (`CLIProxyAccountRow` on the Mac).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyAccountView {
    pub id: String,
    pub provider: String,
    pub agent_kind: Option<super::AgentKind>,
    pub name: String,
    pub email: Option<String>,
    pub label: String,
    pub disabled: bool,
    pub status: String,
    pub status_message: Option<String>,
    pub unavailable: bool,
    pub available: bool,
    pub retry_at: Option<DateTime<Utc>>,
    pub succeeded: i64,
    pub failed: i64,
    pub windows: Vec<CliProxyWindow>,
}

/// One configured CLIProxyAPI hub together with its latest fetched snapshot.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliProxyHubSnapshot {
    pub hub: CliProxyHub,
    pub name: String,
    pub accounts: Vec<CliProxyAccountView>,
    pub read_at: Option<DateTime<Utc>>,
    pub problem: Option<CliProxyProblem>,
}

impl CliProxyAccount {
    /// Display name: email when known, else the hub's label.
    pub fn display_name(&self) -> &str {
        self.email.as_deref().unwrap_or(&self.label)
    }

    /// Coding agent kind corresponding to the hub's provider string.
    pub fn agent_kind(&self) -> Option<super::AgentKind> {
        match self.provider.as_str() {
            "claude" => Some(super::AgentKind::Claude),
            "codex" => Some(super::AgentKind::Codex),
            "antigravity" => Some(super::AgentKind::Antigravity),
            "gemini" | "gemini-cli" => Some(super::AgentKind::Gemini),
            "xai" | "grok" => Some(super::AgentKind::Grok),
            _ => None,
        }
    }

    /// Whether the hub can route requests to this account right now.
    pub fn is_available(&self, now: DateTime<Utc>) -> bool {
        if self.disabled {
            return false;
        }
        if self.unavailable {
            return self.retry_at.is_some_and(|r| r <= now);
        }
        true
    }

    pub fn windows(&self, now: DateTime<Utc>) -> Vec<CliProxyWindow> {
        let num = |k: &str| self.signals.get(k).and_then(|s| s.trim().parse::<f64>().ok());
        let base = self.signals_observed_at.unwrap_or(now);
        let mut out = Vec::new();
        for (key, token, dur) in [("five_hour", "5h", FIVE_HOURS_SECS), ("seven_day", "7d", WEEK_SECS)] {
            if let Some(u) = num(&format!("anthropic-ratelimit-unified-{token}-utilization")) {
                let pct = if u <= 1.0 { u * 100.0 } else { u };
                let reset =
                    num(&format!("anthropic-ratelimit-unified-{token}-reset")).and_then(|s| Utc.timestamp_opt(s as i64, 0).single());
                out.push(CliProxyWindow {
                    key: key.to_string(),
                    used_percent: pct.clamp(0.0, 100.0),
                    resets_at: reset,
                    duration_secs: Some(dur),
                });
            }
        }
        for name in ["primary", "secondary"] {
            if let Some(used) = num(&format!("x-codex-{name}-used-percent")) {
                let duration_secs = num(&format!("x-codex-{name}-window-minutes")).map(|m| (m * 60.0) as i64);
                let resets_at = num(&format!("x-codex-{name}-reset-after-seconds")).map(|s| base + chrono::Duration::seconds(s as i64));
                let key = match duration_secs {
                    Some(d) if d <= 6 * 3600 => "five_hour",
                    Some(d) if d >= 6 * 24 * 3600 => "seven_day",
                    _ => "other",
                };
                out.push(CliProxyWindow { key: key.to_string(), used_percent: used.clamp(0.0, 100.0), resets_at, duration_secs });
            }
        }
        out
    }

    /// Windows settled against `now`: a window whose reset has already passed resets to 0% idle.
    pub fn settled_windows(&self, now: DateTime<Utc>) -> Vec<CliProxyWindow> {
        self.windows(now)
            .into_iter()
            .map(|mut w| {
                if w.resets_at.is_some_and(|r| r <= now) {
                    w.used_percent = 0.0;
                    w.resets_at = None;
                }
                w
            })
            .collect()
    }

    pub fn to_view(&self, now: DateTime<Utc>) -> CliProxyAccountView {
        CliProxyAccountView {
            id: self.id.clone(),
            provider: self.provider.clone(),
            agent_kind: self.agent_kind(),
            name: self.display_name().to_string(),
            email: self.email.clone(),
            label: self.label.clone(),
            disabled: self.disabled,
            status: self.status.clone(),
            status_message: self.status_message.clone(),
            unavailable: self.unavailable,
            available: self.is_available(now),
            retry_at: self.retry_at,
            succeeded: self.succeeded,
            failed: self.failed,
            windows: self.settled_windows(now),
        }
    }
}

/// Parses a `GET /v0/management/auth-files` JSON reply (`CLIProxyReply.accounts`).
pub fn cliproxy_accounts(data: &[u8]) -> Option<Vec<CliProxyAccount>> {
    let root: Value = serde_json::from_slice(data).ok()?;
    let files = root.get("files")?.as_array()?;
    let str_val = |v: Option<&Value>| -> Option<String> {
        match v? {
            Value::String(s) if !s.trim().is_empty() => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    };
    let date_val = |v: Option<&Value>| -> Option<DateTime<Utc>> {
        let s = v?.as_str().filter(|s| !s.is_empty())?;
        let dt = DateTime::parse_from_rfc3339(s).ok()?.with_timezone(&Utc);
        (dt.timestamp() >= 86_400).then_some(dt)
    };
    let mut accounts = Vec::new();
    for file in files {
        let Some(id) = str_val(file.get("id")).or_else(|| str_val(file.get("name"))) else { continue };
        let quota = file.get("quota");
        let signals: BTreeMap<String, String> = quota
            .and_then(|q| q.get("signals"))
            .and_then(Value::as_object)
            .map(|m| m.iter().filter_map(|(k, v)| str_val(Some(v)).map(|val| (k.to_lowercase(), val))).collect())
            .unwrap_or_default();
        let mut retry = date_val(file.get("next_retry_after"));
        let cooldowns: Vec<DateTime<Utc>> =
            file.get("cooldowns").and_then(Value::as_array).into_iter().flatten().filter_map(|c| date_val(c.get("retry_at"))).collect();
        if let Some(latest) = cooldowns.iter().copied().max() {
            retry = Some(retry.map_or(latest, |r| r.max(latest)));
        }
        let unavailable = file.get("unavailable").and_then(Value::as_bool).unwrap_or(false);
        let email = str_val(file.get("email")).or_else(|| str_val(file.get("account")).filter(|s| s.contains('@')));
        accounts.push(CliProxyAccount {
            label: str_val(file.get("label")).or_else(|| str_val(file.get("name"))).unwrap_or_else(|| id.clone()),
            provider: str_val(file.get("provider")).or_else(|| str_val(file.get("type"))).unwrap_or_default().to_lowercase(),
            email,
            id,
            disabled: file.get("disabled").and_then(Value::as_bool).unwrap_or(false),
            status: str_val(file.get("status")).unwrap_or_else(|| "active".to_string()),
            status_message: str_val(file.get("status_message")),
            unavailable,
            retry_at: if unavailable || !cooldowns.is_empty() { retry } else { None },
            succeeded: number(file.get("success")).unwrap_or(0.0) as i64,
            failed: number(file.get("failed")).unwrap_or(0.0) as i64,
            signals,
            signals_observed_at: date_val(quota.and_then(|q| q.get("observed_at"))),
        });
    }
    Some(accounts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_claude_get_usage() {
        let now = Utc::now();
        let reply = json!({"rate_limits": {"five_hour": {"utilization": 42.5, "resets_at": "2026-11-20T18:00:00.000Z"}, "seven_day": {"utilization": 130, "resets_at": "2026-11-24T08:00:00Z"}}});
        let usage = claude_usage_reply(&reply, now).unwrap();
        assert_eq!(usage.five_hour.as_ref().unwrap().used_percent, 42.5);
        assert_eq!(usage.seven_day.as_ref().unwrap().used_percent, 100.0);
        assert!(claude_usage_reply(&json!({"rate_limits": {}}), now).is_none());
        assert!(claude_usage_reply(&json!({}), now).is_none());
    }

    #[test]
    fn reads_codex_windows_by_length_and_credits() {
        let now = Utc.timestamp_opt(1_000_000, 0).unwrap();
        let read = json!({
            "rateLimits": {"planType": "plus", "primary": {"usedPercent": 80, "windowDurationMins": 10080, "resetsAt": 1_500_000},
                           "secondary": {"usedPercent": 12, "windowDurationMins": 300, "resetsInSeconds": 600}},
            "rateLimitResetCredits": {"availableCount": 2, "credits": [{"status": "available", "expiresAt": 2_000_000}, {"status": "available", "expiresAt": 1_800_000}, {"status": "used", "expiresAt": 1}]}
        });
        let usage = codex_snapshot(&read, now).unwrap();
        assert_eq!(usage.weekly.as_ref().unwrap().used_percent, 80.0);
        assert_eq!(usage.five_hour.as_ref().unwrap().resets_at, Some(now + chrono::Duration::seconds(600)));
        assert_eq!(usage.plan_type.as_deref(), Some("plus"));
        assert_eq!(usage.plan_display().as_deref(), Some("Plus"));
        let credits = usage.reset_credits.clone().unwrap();
        assert_eq!(credits.available, 2);
        assert_eq!(credits.next_expires_at, Utc.timestamp_opt(1_800_000, 0).single());
        // A push names one window; a model's own allowance is left alone.
        let pushed = json!({"rateLimits": {"primary": {"usedPercent": 90, "windowDurationMins": 10080}}});
        let merged = codex_merge(&pushed, Some(&usage), now).unwrap();
        assert_eq!(merged.weekly.unwrap().used_percent, 90.0);
        assert_eq!(merged.five_hour.unwrap().used_percent, 12.0);
        assert!(codex_merge(&json!({"rateLimits": {"limitId": "gpt-x", "primary": {"usedPercent": 1}}}), Some(&usage), now).is_none());
        assert_eq!(reset_outcome(&json!({"outcome": "nothingToReset"})), ResetOutcome::NothingToReset);
        assert_eq!(reset_outcome(&json!({})), ResetOutcome::Failed);
    }

    #[test]
    fn reads_codex_session_log_and_preserves_previous_metadata() {
        let dir = std::env::temp_dir().join(format!("nook-codex-log-{}", uuid::Uuid::new_v4()));
        let now = Utc::now();
        let day_dir = dir.join("sessions").join(format!("{:04}/{:02}/{:02}", now.year(), now.month(), now.day()));
        std::fs::create_dir_all(&day_dir).unwrap();
        let log = day_dir.join("rollout-test.jsonl");
        let line1 = json!({"timestamp": "2026-11-20T10:00:00Z", "payload": {"rate_limits": {"primary": {"used_percent": 20, "window_minutes": 300, "resets_at": 4_000_000_000i64}}}});
        let line2 = json!({"timestamp": "2026-11-20T11:00:00Z", "payload": {"rate_limits": {"primary": {"used_percent": 47, "window_minutes": 300, "resets_at": 4_000_000_000i64}, "secondary": {"used_percent": 15, "window_minutes": 10080, "resets_at": 4_000_500_000i64}}}});
        std::fs::write(&log, format!("{line1}\nnot-json\n{line2}\n")).unwrap();

        let prev = CodexUsage {
            five_hour: None,
            weekly: None,
            plan_type: Some("pro".into()),
            updated: now,
            reset_credits: Some(ResetCredits { available: 3, next_expires_at: None }),
        };
        let fallback = read_codex_with_fallback(None, Some(&dir.to_string_lossy()), Some(&prev)).unwrap();
        assert_eq!(fallback.five_hour.as_ref().unwrap().used_percent, 47.0);
        assert_eq!(fallback.weekly.as_ref().unwrap().used_percent, 15.0);
        assert_eq!(fallback.plan_type.as_deref(), Some("pro"));
        assert_eq!(fallback.reset_credits.as_ref().unwrap().available, 3);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn parses_antigravity_summary_and_models_and_settles_idle() {
        let summary = json!({
            "response": {
                "groups": [
                    {
                        "displayName": "Claude and GPT models",
                        "buckets": [{"bucketId": "claude-5h", "window": "5h", "remainingFraction": 0.5}]
                    },
                    {
                        "displayName": "Gemini Models",
                        "buckets": [
                            {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.7, "resetTime": "2026-11-28T00:00:00Z"},
                            {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.4, "resetTime": "2026-11-21T15:00:00Z"}
                        ]
                    }
                ]
            }
        });
        let windows = antigravity_summary_windows(&summary);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].duration_secs, Some(FIVE_HOURS_SECS));
        assert!((windows[0].percent - 60.0).abs() < 0.01);
        assert_eq!(windows[1].duration_secs, Some(WEEK_SECS));
        assert!((windows[1].percent - 30.0).abs() < 0.01);

        assert_eq!(antigravity_model_name("gemini-4-pro-high"), "Gemini 4 Pro");
        assert_eq!(antigravity_model_name("claude-sonnet-4-5"), "Claude Sonnet 4.5");

        let now = DateTime::parse_from_rfc3339("2026-11-21T16:00:00Z").unwrap().with_timezone(&Utc);
        let settled = windows[0].settled(now);
        assert_eq!(settled.percent, 0.0);
        assert!(settled.resets_at.is_none());
        assert!(settled.note.is_some());

        let models = json!({
            "models": {
                "gemini-2.5-pro": {"modelProvider": "MODEL_PROVIDER_GOOGLE", "displayName": "Gemini 2.5 Pro (Preview)", "quotaInfo": {"remainingFraction": 0.25}},
                "chat_internal": {"modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": {"remainingFraction": 0.1}},
                "claude-sonnet": {"modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": {"remainingFraction": 0.1}}
            }
        });
        let mwindows = antigravity_model_windows(&models);
        assert_eq!(mwindows.len(), 1);
        assert!(mwindows[0].label.starts_with("Gemini 2.5 Pro · "));
        assert!((mwindows[0].percent - 75.0).abs() < 0.01);
    }

    #[test]
    fn validates_cliproxy_hub_and_parses_accounts() {
        assert!(CliProxyHub::base("127.0.0.1:8317/management.html").is_ok());
        assert!(CliProxyHub::base("https://hub.example.com/").is_ok());
        assert_eq!(CliProxyHub::base("http://hub.example.com/"), Err(CliProxyAddressError::Insecure));
        assert_eq!(CliProxyHub::base(""), Err(CliProxyAddressError::Invalid));

        let payload = json!({
            "files": [{
                "id": "acc-1",
                "provider": "claude",
                "email": "dev@example.com",
                "status": "active",
                "quota": {
                    "observed_at": "2026-11-21T10:00:00Z",
                    "signals": {
                        "anthropic-ratelimit-unified-5h-utilization": "0.42",
                        "anthropic-ratelimit-unified-5h-reset": "1800000000"
                    }
                }
            }]
        });
        let accounts = cliproxy_accounts(payload.to_string().as_bytes()).unwrap();
        assert_eq!(accounts.len(), 1);
        let wins = accounts[0].windows(Utc::now());
        assert_eq!(wins.len(), 1);
        assert_eq!(wins[0].key, "five_hour");
        assert!((wins[0].used_percent - 42.0).abs() < 0.01);
        assert_eq!(accounts[0].agent_kind(), Some(super::super::AgentKind::Claude));

        // Expired window settles back to 0% with no reset timestamp.
        let past_now = Utc.timestamp_opt(1_800_000_100, 0).unwrap();
        let settled = accounts[0].settled_windows(past_now);
        assert_eq!(settled.len(), 1);
        assert_eq!(settled[0].used_percent, 0.0);
        assert!(settled[0].resets_at.is_none());
    }

    #[test]
    fn cliproxy_hub_store_persists_add_and_remove() {
        let dir = std::env::temp_dir().join(format!("nook-cliproxy-store-{}", uuid::Uuid::new_v4()));
        let path = dir.join("cliproxy-hubs.json");
        let mut store = CliProxyHubStore::load(Some(path.clone()));
        assert!(store.all().is_empty());

        let hub = CliProxyHub { id: "h1".into(), label: "Local".into(), url: "http://127.0.0.1:8317".into() };
        store.add(hub.clone());
        assert_eq!(store.all(), vec![hub.clone()]);
        assert_eq!(hub.name(), "Local");

        let reloaded = CliProxyHubStore::load(Some(path.clone()));
        assert_eq!(reloaded.all(), vec![hub.clone()]);

        let mut reloaded = reloaded;
        assert_eq!(reloaded.remove("h1"), Some(hub));
        assert!(reloaded.all().is_empty());
        assert!(CliProxyHubStore::load(Some(path)).all().is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn talks_to_a_fake_codex_app_server() {
        let dir = std::env::temp_dir().join(format!("nook-usage-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("codex");
        std::fs::write(
            &exe,
            "#!/bin/sh\nread a\nread b\nread c\necho '{\"id\":1,\"result\":{}}'\necho '{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":33,\"windowDurationMins\":300,\"resetsAt\":4000000000}}}}'\nread rest\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        let usage = read_codex(&exe.to_string_lossy(), Some("/nowhere")).unwrap();
        assert_eq!(usage.five_hour.unwrap().used_percent, 33.0);
        let _ = std::fs::remove_dir_all(dir);
    }
}
