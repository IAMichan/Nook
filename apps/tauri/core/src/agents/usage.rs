//! Subscription limits read while no session runs (`ClaudeUsage`, `CodexUsage`, `CodexRateLimits` on the Mac): the
//! status line and a session's own limit events only report while an agent works.
//!
//! Nook never touches an agent's login. For Claude Code it asks the official `claude` CLI the `get_usage` control
//! request (the numbers of `/usage`) in an empty folder with only project settings, so no hooks fire and no prompt is
//! sent: a reading costs no usage. For Codex it starts `codex app-server` with the account's `CODEX_HOME` and asks
//! `account/rateLimits/read`, the source of Codex's own `/status`; the same server spends a reset credit when you ask.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use serde::Serialize;
use serde_json::{json, Value};

use super::models::{PlanUsage, PlanWindow};

/// The background timer reads an account at most this often: a usage view, a turn or a limit event reads sooner.
pub const BACKGROUND_INTERVAL: Duration = Duration::from_secs(60 * 60);
/// `refresh_now` (a usage view opens, a turn ended) asks again at most this often per account.
pub const MINIMUM_INTERVAL: Duration = Duration::from_secs(60);
/// The refresh button asks again at most this often per account, however often it is clicked.
pub const MANUAL_INTERVAL: Duration = Duration::from_secs(10);

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
        let w = |w: &Option<CodexWindow>| w.as_ref().and_then(|w| Some(PlanWindow { used_percent: w.used_percent, resets_at: w.resets_at? }));
        PlanUsage { five_hour: w(&self.five_hour), seven_day: w(&self.weekly), updated: self.updated }
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
            number(raw.get("resetsInSeconds")).or_else(|| number(raw.get("resets_in_seconds"))).map(|s| at + chrono::Duration::seconds(s as i64))
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
    cwd: Option<&std::path::Path>,
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
    let keep = if close_input { drop(stdin); None } else { Some(stdin) };
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
    let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--setting-sources", "project"];
    let answer = exchange(executable, &args, &env, Some(&folder), line, true, timeout, move |object| {
        let response = object.get("response").filter(|_| object.get("type").and_then(Value::as_str) == Some("control_response"))?;
        if response.get("request_id").and_then(Value::as_str) != Some(request_id.as_str()) {
            return None;
        }
        Some(if response.get("subtype").and_then(Value::as_str) == Some("success") { response.get("response").cloned().unwrap_or(Value::Null) } else { Value::Null })
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

/// Spends one reset credit; `key` makes a retry of the same click harmless.
pub fn use_reset_credit(executable: &str, home: Option<&str>, key: &str) -> ResetOutcome {
    codex_request(executable, home, "account/rateLimitResetCredit/consume", Some(json!({"idempotencyKey": key})), Duration::from_secs(20))
        .map_or(ResetOutcome::Failed, |r| reset_outcome(&r))
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
