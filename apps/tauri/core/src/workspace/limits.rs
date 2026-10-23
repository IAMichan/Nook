//! Een beurt die op een gebruikslimiet stopte (`UsageLimits` en `FailureClassifier` op de Mac), zo
//! gelezen: wanneer de limiet weer vrij is, zodat de sessie dan vanzelf verder kan. Claude Code meldt het in
//! `rate_limit_event` (status "rejected", `resetsAt`) en in het resultaat (`terminal_reason`, `api_error_status`);
//! Codex met de foutcode `usageLimitExceeded` en zijn limietstand.

use std::collections::BTreeMap;

use chrono::{DateTime, Duration, Utc};
use serde_json::Value;

use super::parsers::number;

/// Wat een sessie stuurt als hij na de reset verdergaat (voor het model, dus Engels).
pub const RESUME_MESSAGE: &str = "Continue where you left off.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudeLimitEvent {
    /// "five_hour", "seven_day", "seven_day_opus", …
    pub window: String,
    /// Geweigerd en geen extra gebruik om op terug te vallen: de beurt wacht.
    pub blocked: bool,
    pub resets_at: Option<DateTime<Utc>>,
}

fn seconds(v: Option<&Value>) -> Option<DateTime<Utc>> {
    number(v).and_then(|s| DateTime::from_timestamp(s as i64, 0))
}

/// `rate_limit_event.rate_limit_info`.
pub fn claude_event(info: &Value) -> Option<ClaudeLimitEvent> {
    let status = info.get("status")?.as_str()?;
    let overage = info.get("overageStatus").and_then(Value::as_str).is_some_and(|s| s == "allowed" || s == "allowed_warning");
    let using = info.get("isUsingOverage").and_then(Value::as_bool) == Some(true)
        || info.get("overageInUse").and_then(Value::as_bool) == Some(true);
    Some(ClaudeLimitEvent {
        window: info.get("rateLimitType").and_then(Value::as_str).unwrap_or("five_hour").to_string(),
        blocked: status == "rejected" && !overage && !using,
        resets_at: seconds(info.get("resetsAt")),
    })
}

/// De laatste reset van de geblokkeerde vensters; `None` als een ervan niet zei wanneer.
pub fn latest_reset(windows: &BTreeMap<String, Option<DateTime<Utc>>>) -> Option<DateTime<Utc>> {
    if windows.is_empty() || windows.values().any(Option::is_none) {
        return None;
    }
    windows.values().flatten().max().copied()
}

/// Codex' `codexErrorInfo`: een code ("usageLimitExceeded") of een object met de code als sleutel.
pub fn codex_error_code(info: Option<&Value>) -> Option<String> {
    match info? {
        Value::String(code) => Some(code.clone()),
        Value::Object(map) => map.keys().min().cloned(),
        _ => None,
    }
}

pub fn is_codex_usage_limit(info: Option<&Value>) -> bool {
    matches!(codex_error_code(info).as_deref(), Some("usageLimitExceeded") | Some("rateLimitExceeded"))
}

/// Wanneer Codex verder mag: de laatste reset van de vensters op 100 %; `None` als een daarvan geen tijd heeft.
pub fn codex_reset(params: &Value) -> Option<DateTime<Utc>> {
    let snapshot = params.get("rateLimits").unwrap_or(params);
    if snapshot.get("limitId").and_then(Value::as_str).is_some_and(|l| l != "codex") {
        return None;
    }
    let full: Vec<&Value> = ["primary", "secondary"]
        .iter()
        .filter_map(|k| snapshot.get(*k))
        .filter(|w| number(w.get("usedPercent")).unwrap_or(0.0) >= 100.0)
        .collect();
    if full.is_empty() {
        return None;
    }
    let resets: Vec<Option<DateTime<Utc>>> = full.iter().map(|w| seconds(w.get("resetsAt"))).collect();
    if resets.iter().any(Option::is_none) {
        return None;
    }
    resets.into_iter().flatten().max()
}

/// Wat het resultaat van de agent zei over een beurt die niet goed ging.
#[derive(Debug, Clone, PartialEq)]
pub struct FailureEvidence {
    pub result_subtype: Option<String>,
    pub terminal_reason: Option<String>,
    pub api_error_status: Option<i64>,
    pub is_error: bool,
    /// Een gestreamde `rate_limit_event` werd geweigerd zonder extra gebruik.
    pub rate_limit_rejected: bool,
    /// Geblokkeerde vensters en wanneer elk vrijkomt (`None`: niet gemeld).
    pub rate_limit_resets: BTreeMap<String, Option<DateTime<Utc>>>,
    pub message_text: Option<String>,
    pub now: DateTime<Utc>,
    /// `/compact` die op een limiet stopte meldt succes, maar er werd niets samengevat: toch een fout.
    pub is_compaction: bool,
}

impl Default for FailureEvidence {
    fn default() -> Self {
        Self {
            result_subtype: None,
            terminal_reason: None,
            api_error_status: None,
            is_error: false,
            rate_limit_rejected: false,
            rate_limit_resets: BTreeMap::new(),
            message_text: None,
            now: Utc::now(),
            is_compaction: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FailureClass {
    UsageLimit(Option<DateTime<Utc>>),
    Authentication,
    /// 403: de eigen tekst van de agent zegt waarom.
    Forbidden,
    /// Je eigen stop (`terminal_reason` aborted_*): geen fout.
    Interrupted,
    Network,
    Generic,
}

/// In lagen: eerst de expliciete reden, dan de API-status, dan gestreamde limieten, pas dan de tekst.
pub fn classify(e: &FailureEvidence) -> FailureClass {
    match e.terminal_reason.as_deref() {
        Some("aborted_tools") | Some("aborted_streaming") => return FailureClass::Interrupted,
        Some("blocking_limit") => return FailureClass::UsageLimit(reset(e)),
        _ => {}
    }
    match e.api_error_status {
        Some(429) => return FailureClass::UsageLimit(reset(e)),
        // 529 (overbelast) mag opnieuw, maar heeft geen reset: geen gebruikslimiet.
        Some(529) => return FailureClass::Network,
        Some(401) => return FailureClass::Authentication,
        Some(403) => return FailureClass::Forbidden,
        _ => {}
    }
    if e.rate_limit_rejected {
        return FailureClass::UsageLimit(latest_reset(&e.rate_limit_resets));
    }
    // Gewone tekst van de agent kan "network" noemen; alleen een mislukt resultaat wordt gelezen.
    let Some(text) = e.message_text.as_deref().filter(|t| is_failing(e) && !t.is_empty()) else { return FailureClass::Generic };
    if let Some(s) = gateway_reset_seconds(text) {
        return FailureClass::UsageLimit((s > 0.0).then(|| e.now + Duration::milliseconds((s * 1000.0) as i64)));
    }
    let lower = text.to_lowercase();
    if lower.contains("[429]") || lower.contains("rate_limit_error") {
        return FailureClass::UsageLimit(latest_reset(&e.rate_limit_resets));
    }
    if lower.contains("authentication_failed")
        || lower.contains("invalid api key")
        || lower.contains("/login")
        || lower.contains("api error: 401")
    {
        return FailureClass::Authentication;
    }
    if lower.contains("api error: 403") {
        return FailureClass::Forbidden;
    }
    const NETWORK: [&str; 9] = [
        "econnreset",
        "enotfound",
        "etimedout",
        "econnrefused",
        "fetch failed",
        "socket hang up",
        "network error",
        "network connection",
        "offline",
    ];
    if NETWORK.iter().any(|n| lower.contains(n)) {
        return FailureClass::Network;
    }
    FailureClass::Generic
}

/// Of de beurt mislukte. Een onderbreking is een stop, geen fout; een limiet tijdens `/compact` wel.
pub fn is_failure(e: &FailureEvidence) -> bool {
    match classify(e) {
        FailureClass::Interrupted => false,
        FailureClass::UsageLimit(_) | FailureClass::Authentication | FailureClass::Forbidden | FailureClass::Network => true,
        FailureClass::Generic => is_failing(e),
    }
}

fn is_failing(e: &FailureEvidence) -> bool {
    e.is_error || e.is_compaction || e.result_subtype.as_deref().is_some_and(|s| s != "success")
}

fn reset(e: &FailureEvidence) -> Option<DateTime<Utc>> {
    if let Some(s) = e.message_text.as_deref().and_then(gateway_reset_seconds).filter(|s| *s > 0.0) {
        return Some(e.now + Duration::milliseconds((s * 1000.0) as i64));
    }
    latest_reset(&e.rate_limit_resets)
}

/// "(reset after 1h2m3s)" in de 429-tekst van een gateway.
pub fn gateway_reset_seconds(text: &str) -> Option<f64> {
    let start = text.find("(reset after ")?;
    let rest = &text[start + "(reset after ".len()..];
    let end = rest.find(')')?;
    let inner = rest[..end].trim();
    let mut total = 0.0;
    let mut digits = String::new();
    for c in inner.chars() {
        match c {
            '0'..='9' => digits.push(c),
            'h' | 'm' | 's' => {
                let n: f64 = digits.parse().ok()?;
                total += n * match c {
                    'h' => 3600.0,
                    'm' => 60.0,
                    _ => 1.0,
                };
                digits.clear();
            }
            ' ' => {}
            _ => return None,
        }
    }
    if !digits.is_empty() {
        return None;
    }
    Some(total)
}

/// "Gebruikslimiet bereikt; deze beurt wacht tot de limiet over 2u 15m vrijkomt (14:30)."
pub fn limit_text(reset: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let Some(reset) = reset else { return "Gebruikslimiet bereikt; wanneer die vrijkomt is onbekend.".into() };
    let local = reset.with_timezone(&chrono::Local);
    let clock = if local.date_naive() == now.with_timezone(&chrono::Local).date_naive() {
        local.format("%H:%M").to_string()
    } else {
        local.format("%d-%m %H:%M").to_string()
    };
    format!(
        "Gebruikslimiet bereikt; deze beurt wacht tot de limiet over {} vrijkomt ({clock}).",
        duration((reset - now).num_seconds().max(0))
    )
}

/// "< 1 min", "12 min", "2u 5m", "3 d" (AgentPathFormat.duration).
pub fn duration(seconds: i64) -> String {
    let minutes = seconds / 60;
    if minutes < 1 {
        return "< 1 min".into();
    }
    if minutes < 60 {
        return format!("{minutes} min");
    }
    let hours = minutes / 60;
    if hours < 48 {
        return if minutes % 60 == 0 { format!("{hours}u") } else { format!("{hours}u {}m", minutes % 60) };
    }
    format!("{} d", hours / 24)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(s: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(s, 0).unwrap()
    }

    #[test]
    fn claude_rate_limit_event() {
        let rejected = claude_event(&json!({"status": "rejected", "rateLimitType": "seven_day", "resetsAt": 1_700_000_000})).unwrap();
        assert_eq!(rejected, ClaudeLimitEvent { window: "seven_day".into(), blocked: true, resets_at: Some(at(1_700_000_000)) });
        assert!(!claude_event(&json!({"status": "rejected", "overageStatus": "allowed"})).unwrap().blocked);
        assert!(!claude_event(&json!({"status": "rejected", "isUsingOverage": true})).unwrap().blocked);
        assert!(!claude_event(&json!({"status": "allowed_warning"})).unwrap().blocked);
        assert!(claude_event(&json!({})).is_none());
    }

    #[test]
    fn latest_reset_needs_every_window() {
        let known = BTreeMap::from([("five_hour".to_string(), Some(at(100))), ("seven_day".to_string(), Some(at(200)))]);
        let partly = BTreeMap::from([("five_hour".to_string(), Some(at(100))), ("seven_day".to_string(), None)]);
        assert_eq!(latest_reset(&known), Some(at(200)));
        assert_eq!(latest_reset(&partly), None);
        assert_eq!(latest_reset(&BTreeMap::new()), None);
    }

    #[test]
    fn codex_usage_limit() {
        assert!(is_codex_usage_limit(Some(&json!("usageLimitExceeded"))));
        assert!(is_codex_usage_limit(Some(&json!({"rateLimitExceeded": {}}))));
        assert!(!is_codex_usage_limit(Some(&json!({"httpConnectionFailed": {"httpStatusCode": 502}}))));
        assert!(!is_codex_usage_limit(None));
        let params = json!({"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 100, "resetsAt": 1_700_000_000}, "secondary": {"usedPercent": 40, "resetsAt": 1_800_000_000}}});
        assert_eq!(codex_reset(&params), Some(at(1_700_000_000)));
        assert_eq!(codex_reset(&json!({"rateLimits": {"primary": {"usedPercent": 100}}})), None);
        assert_eq!(codex_reset(&json!({"rateLimits": {"primary": {"usedPercent": 30, "resetsAt": 1}}})), None);
        assert_eq!(codex_reset(&json!({"rateLimits": {"limitId": "spark", "primary": {"usedPercent": 100, "resetsAt": 1}}})), None);
    }

    fn ev() -> FailureEvidence {
        FailureEvidence { now: at(1_000_000), ..Default::default() }
    }

    #[test]
    fn aborts_are_interruptions() {
        for reason in ["aborted_tools", "aborted_streaming"] {
            let e = FailureEvidence { result_subtype: Some("success".into()), terminal_reason: Some(reason.into()), ..ev() };
            assert_eq!(classify(&e), FailureClass::Interrupted);
            assert!(!is_failure(&e));
        }
        let e = FailureEvidence { terminal_reason: Some("aborted_tools".into()), api_error_status: Some(429), is_error: true, ..ev() };
        assert_eq!(classify(&e), FailureClass::Interrupted);
    }

    #[test]
    fn limits_and_statuses() {
        let resets = BTreeMap::from([("five_hour".to_string(), Some(at(1_000_100))), ("seven_day".to_string(), Some(at(1_000_500)))]);
        let e = FailureEvidence { terminal_reason: Some("blocking_limit".into()), rate_limit_resets: resets.clone(), ..ev() };
        assert_eq!(classify(&e), FailureClass::UsageLimit(Some(at(1_000_500))));
        assert_eq!(classify(&FailureEvidence { api_error_status: Some(429), is_error: true, ..ev() }), FailureClass::UsageLimit(None));
        assert_eq!(classify(&FailureEvidence { api_error_status: Some(529), is_error: true, ..ev() }), FailureClass::Network);
        assert_eq!(classify(&FailureEvidence { api_error_status: Some(401), is_error: true, ..ev() }), FailureClass::Authentication);
        assert_eq!(
            classify(&FailureEvidence { api_error_status: Some(403), is_error: true, message_text: Some("Forbidden".into()), ..ev() }),
            FailureClass::Forbidden
        );
        let mut e = FailureEvidence { is_error: true, rate_limit_rejected: true, rate_limit_resets: resets, ..ev() };
        assert_eq!(classify(&e), FailureClass::UsageLimit(Some(at(1_000_500))));
        e.rate_limit_resets.insert("b".into(), None);
        assert_eq!(classify(&e), FailureClass::UsageLimit(None));
    }

    #[test]
    fn gateway_text() {
        let text = r#"API Error: 503 [req] [429]: {"type":"error","error":{"type":"rate_limit_error","message":"x"}} (reset after 1h2m3s)"#;
        let e = FailureEvidence {
            terminal_reason: Some("api_error".into()),
            api_error_status: Some(503),
            is_error: true,
            message_text: Some(text.into()),
            ..ev()
        };
        assert_eq!(classify(&e), FailureClass::UsageLimit(Some(at(1_000_000 + 3723))));
        assert_eq!(gateway_reset_seconds("(reset after 45s)"), Some(45.0));
        assert_eq!(gateway_reset_seconds("(reset after 2m)"), Some(120.0));
        assert_eq!(gateway_reset_seconds("no hint"), None);
        let zero = FailureEvidence { is_error: true, message_text: Some("[429] rate_limit_error (reset after )".into()), ..ev() };
        assert_eq!(classify(&zero), FailureClass::UsageLimit(None));
    }

    #[test]
    fn text_rules_and_failures() {
        let c = |t: &str| classify(&FailureEvidence { is_error: true, message_text: Some(t.into()), ..ev() });
        assert_eq!(c("API Error [429] rate_limit_error"), FailureClass::UsageLimit(None));
        assert_eq!(c("Invalid API key. Please run /login"), FailureClass::Authentication);
        assert_eq!(c("authentication_failed"), FailureClass::Authentication);
        assert_eq!(c("fetch failed: ENOTFOUND"), FailureClass::Network);
        assert_eq!(c("something odd"), FailureClass::Generic);
        let chat =
            FailureEvidence { result_subtype: Some("success".into()), message_text: Some("fix the network error handling".into()), ..ev() };
        assert_eq!(classify(&chat), FailureClass::Generic);
        assert!(!is_failure(&chat));
        assert!(is_failure(&FailureEvidence { is_error: true, ..ev() }));
        assert!(is_failure(&FailureEvidence { result_subtype: Some("error_during_execution".into()), ..ev() }));
        assert!(is_failure(&FailureEvidence { result_subtype: Some("success".into()), api_error_status: Some(429), ..ev() }));
        assert!(!is_failure(&FailureEvidence { result_subtype: Some("success".into()), ..ev() }));
        assert!(is_failure(&FailureEvidence {
            result_subtype: Some("success".into()),
            rate_limit_rejected: true,
            is_compaction: true,
            ..ev()
        }));
    }

    #[test]
    fn texts() {
        assert_eq!(duration(30), "< 1 min");
        assert_eq!(duration(125 * 60), "2u 5m");
        assert!(limit_text(None, at(0)).contains("onbekend"));
        assert!(limit_text(Some(at(3600)), at(0)).contains("over 1u vrijkomt"));
    }
}
