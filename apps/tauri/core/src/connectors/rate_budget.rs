//! Forge API rate-limit budget (AG-135, port of `ForgeRateBudget` and `ForgeRateGate` on the Mac).
//!
//! Reads `X-RateLimit-*` (GitHub, Gitea) and `RateLimit-*` (GitLab) plus `Retry-After` from every HTTP answer, per host
//! and per resource (`core`, `graphql`, `search`):
//! - background polls slow down (`slowdown`: 1x -> 2x -> 4x) as a limit runs low and stop under the last 10% reserve
//!   (`allows_background`), keeping that reserve for explicit user actions;
//! - once a limit is exhausted or paused, requests to that host/resource are answered locally (`paused_until` +
//!   `local_refusal`) without touching the network until the reset;
//! - pull request status reads prefer GraphQL (`prefers_graphql`), which has its own hourly quota and batches cleanly,
//!   falling back to REST when GraphQL is paused or lower than REST below 25%.

use std::collections::HashMap;
use std::sync::Mutex;

use chrono::{DateTime, Duration, Utc};
use url::Url;

use super::{ConnectorError, ErrorKind};

/// One rate-limit window of a host/resource as reported by the last HTTP answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForgeRateWindow {
    pub limit: i64,
    pub remaining: i64,
    pub reset: DateTime<Utc>,
}

#[derive(Default)]
struct State {
    windows: HashMap<String, ForgeRateWindow>,
    /// Explicit wait requested by the forge (e.g. `Retry-After` or fallback backoff on 429).
    pauses: HashMap<String, DateTime<Utc>>,
    /// Consecutive refusals without a wait duration (`fallback_pause` doubles each time).
    refusals: HashMap<String, u32>,
}

/// Shared rate-limit tracker across connector HTTP calls.
#[derive(Default)]
pub struct ForgeRateBudget {
    state: Mutex<State>,
}

impl ForgeRateBudget {
    /// Below this share of a limit, background reads stop so explicit user actions keep working.
    pub const RESERVE: f64 = 0.1;

    pub fn new() -> Self {
        Self::default()
    }

    /// Which limit bucket a URL counts against: GitHub GraphQL and search have their own; everything else is `"core"`.
    pub fn resource(url: &Url) -> &'static str {
        let path = url.path().to_ascii_lowercase();
        if path.ends_with("/graphql") {
            "graphql"
        } else if path.contains("/search/") {
            "search"
        } else {
            "core"
        }
    }

    /// API host corresponding to a web page URL (`github.com` -> `api.github.com`; Enterprise / GitLab / Gitea keep host).
    pub fn api_host(page_url: Option<&str>) -> Option<String> {
        let parsed = Url::parse(page_url?).ok()?;
        let host = parsed.host_str()?.to_ascii_lowercase();
        if host == "github.com" || host == "www.github.com" {
            Some("api.github.com".to_string())
        } else {
            Some(host)
        }
    }

    /// Host from an API URL (e.g. `https://api.github.com` -> `"api.github.com"`).
    pub fn host_of(url: &str) -> Option<String> {
        Url::parse(url).ok().and_then(|u| u.host_str().map(|h| h.to_ascii_lowercase()))
    }

    fn key(host: &str, resource: &str) -> String {
        format!("{}|{}", host.to_ascii_lowercase(), resource.to_ascii_lowercase())
    }

    fn url_key(url: &str) -> Option<String> {
        let parsed = Url::parse(url).ok()?;
        let host = parsed.host_str()?;
        Some(Self::key(host, Self::resource(&parsed)))
    }

    /// 30 seconds after the first refusal without a wait header, doubling each time, capped at 15 minutes.
    pub fn fallback_pause(attempt: u32) -> i64 {
        let shift = attempt.saturating_sub(1).min(10);
        let secs = 30i64.saturating_mul(1i64 << shift);
        secs.min(15 * 60)
    }

    /// Records rate-limit headers from an HTTP response. Answers without limit headers leave the budget unchanged.
    pub fn record(&self, url: &str, status: u16, headers: &[(String, String)], now: DateTime<Utc>) {
        let Ok(parsed) = Url::parse(url) else { return };
        let Some(host) = parsed.host_str() else { return };

        let find = |name: &str| -> Option<&str> {
            headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.trim()).filter(|v| !v.is_empty())
        };
        let limit_header = |suffix: &str| -> Option<&str> {
            let x = format!("X-RateLimit-{suffix}");
            let plain = format!("RateLimit-{suffix}");
            find(&x).or_else(|| find(&plain))
        };

        let resource = find("X-RateLimit-Resource").unwrap_or_else(|| Self::resource(&parsed));
        let key = Self::key(host, resource);
        let retry_after = find("Retry-After").and_then(|v| v.parse::<f64>().ok());

        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let (Some(limit), Some(remaining), Some(reset_val)) = (
            limit_header("Limit").and_then(|v| v.parse::<i64>().ok()),
            limit_header("Remaining").and_then(|v| v.parse::<i64>().ok()),
            limit_header("Reset").and_then(|v| v.parse::<f64>().ok()),
        ) {
            if limit > 0 {
                // GitHub and GitLab send Unix timestamps; some forges send seconds from now.
                let reset = if reset_val > 1_000_000_000.0 {
                    DateTime::from_timestamp(reset_val as i64, 0).unwrap_or(now)
                } else {
                    now + Duration::seconds(reset_val.max(0.0) as i64)
                };
                state.windows.insert(key.clone(), ForgeRateWindow { limit, remaining: remaining.max(0), reset });
            }
        }

        if status == 429 || (status == 403 && retry_after.is_some()) {
            if let Some(secs) = retry_after.filter(|s| *s > 0.0) {
                let capped = secs.min(3600.0) as i64;
                state.pauses.insert(key, now + Duration::seconds(capped));
            } else {
                let needs_fallback = state.windows.get(&key).map(|w| w.remaining > 0 || w.reset <= now).unwrap_or(true);
                if needs_fallback {
                    let attempt = state.refusals.get(&key).copied().unwrap_or(0).saturating_add(1);
                    state.refusals.insert(key.clone(), attempt);
                    state.pauses.insert(key, now + Duration::seconds(Self::fallback_pause(attempt)));
                }
            }
        } else if (200..400).contains(&status) {
            state.refusals.remove(&key);
        }
    }

    /// Convenience adapter for `reqwest::header::HeaderMap`.
    pub fn record_reqwest(&self, url: &str, status: u16, headers: &reqwest::header::HeaderMap) {
        let pairs: Vec<(String, String)> =
            headers.iter().filter_map(|(k, v)| v.to_str().ok().map(|val| (k.as_str().to_string(), val.to_string()))).collect();
        self.record(url, status, &pairs, Utc::now());
    }

    /// Active rate-limit window for a host/resource; `None` once its reset time has passed.
    pub fn window(&self, host: &str, resource: &str, now: DateTime<Utc>) -> Option<ForgeRateWindow> {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let w = state.windows.get(&Self::key(host, resource))?;
        (w.reset > now).then(|| w.clone())
    }

    /// Timestamp until which requests to `url` must be answered locally instead of hitting the network.
    pub fn paused_until(&self, url: &str, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let key = Self::url_key(url)?;
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut until: Option<DateTime<Utc>> = None;
        if let Some(w) = state.windows.get(&key) {
            if w.remaining == 0 && w.reset > now {
                until = Some(w.reset);
            }
        }
        if let Some(&pause) = state.pauses.get(&key) {
            if pause > now {
                until = Some(until.map(|u| u.max(pause)).unwrap_or(pause));
            }
        }
        until
    }

    /// Whether a background read may proceed (not paused, and remaining share >= 10% reserve).
    pub fn allows_background(&self, host: &str, resource: &str, now: DateTime<Utc>) -> bool {
        let key = Self::key(host, resource);
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(&pause) = state.pauses.get(&key) {
            if pause > now {
                return false;
            }
        }
        let Some(w) = state.windows.get(&key).filter(|w| w.reset > now) else { return true };
        (w.remaining as f64) >= (w.limit as f64) * Self::RESERVE
    }

    /// `allows_background` for the forge host of a web page URL (`or_graphql`: either REST or GraphQL having room).
    pub fn allows_background_for_page(&self, page_url: Option<&str>, or_graphql: bool, now: DateTime<Utc>) -> bool {
        let Some(host) = Self::api_host(page_url) else { return true };
        self.allows_background(&host, "core", now) || (or_graphql && self.allows_background(&host, "graphql", now))
    }

    /// Poll interval multiplier: 1x (>= 50% left), 2x (>= 25% left), 4x (< 25% left).
    pub fn slowdown(&self, host: &str, resource: &str, now: DateTime<Utc>) -> f64 {
        let Some(w) = self.window(host, resource, now) else { return 1.0 };
        Self::slowdown_for(w.remaining, w.limit)
    }

    pub fn slowdown_for(remaining: i64, limit: i64) -> f64 {
        if limit <= 0 {
            return 1.0;
        }
        let left = remaining as f64 / limit as f64;
        if left >= 0.5 {
            1.0
        } else if left >= 0.25 {
            2.0
        } else {
            4.0
        }
    }

    /// Slowdown multiplier for a web page URL's forge API (`or_graphql`: minimum of REST and GraphQL slowdowns).
    pub fn slowdown_for_page(&self, page_url: Option<&str>, or_graphql: bool, now: DateTime<Utc>) -> f64 {
        let Some(host) = Self::api_host(page_url) else { return 1.0 };
        let rest = self.slowdown(&host, "core", now);
        if or_graphql {
            rest.min(self.slowdown(&host, "graphql", now))
        } else {
            rest
        }
    }

    /// Whether a pull request status read should use GraphQL instead of REST.
    ///
    /// Prefers GraphQL by default (separate hourly limit, single batched request) and falls back to REST while
    /// GraphQL is paused or below 25% and lower than REST.
    pub fn prefers_graphql(&self, host: &str, now: DateTime<Utc>) -> bool {
        let gql_url = format!("https://{host}/graphql");
        if self.paused_until(&gql_url, now).is_some() {
            return false;
        }
        let rest_url = format!("https://{host}/");
        let rest_paused = self.paused_until(&rest_url, now).is_some();
        let left = |resource: &str| -> Option<f64> { self.window(host, resource, now).map(|w| w.remaining as f64 / w.limit as f64) };
        let rest = if rest_paused { 0.0 } else { left("core").unwrap_or(1.0) };
        let graph = left("graphql").unwrap_or(1.0);
        graph >= 0.25 || graph > rest
    }

    /// Local refusal error returned by the gate without sending a network request (`ForgeRateGate` on the Mac).
    pub fn local_refusal(url: &str, until: DateTime<Utc>) -> ConnectorError {
        let host = Self::host_of(url).unwrap_or_else(|| "forge".to_string());
        let reset = until.format("%H:%M UTC");
        ConnectorError::kind(
            format!("Rate limit reached for {host}; waiting locally until {reset} before sending more requests."),
            ErrorKind::RateLimited,
        )
    }

    /// Clears all recorded windows and pauses (tests).
    pub fn reset(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.windows.clear();
        state.pauses.clear();
        state.refusals.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000, 0).unwrap()
    }

    fn headers(remaining: i64, limit: i64, reset_in: i64, resource: Option<&str>) -> Vec<(String, String)> {
        let mut out = vec![
            ("X-RateLimit-Limit".into(), limit.to_string()),
            ("X-RateLimit-Remaining".into(), remaining.to_string()),
            ("X-RateLimit-Reset".into(), (now().timestamp() + reset_in).to_string()),
        ];
        if let Some(res) = resource {
            out.push(("X-RateLimit-Resource".into(), res.into()));
        }
        out
    }

    #[test]
    fn background_slows_down_and_stops_under_reserve() {
        let budget = ForgeRateBudget::new();
        let t = now();
        assert!(budget.allows_background("api.github.com", "core", t));
        assert_eq!(budget.slowdown("api.github.com", "core", t), 1.0);

        let url = "https://api.github.com/repos/a/b/pulls/1";
        budget.record(url, 200, &headers(3000, 5000, 1800, Some("core")), t);
        assert_eq!(budget.slowdown("api.github.com", "core", t), 1.0);

        budget.record(url, 200, &headers(2000, 5000, 1800, Some("core")), t);
        assert_eq!(budget.slowdown("api.github.com", "core", t), 2.0);

        budget.record(url, 200, &headers(1000, 5000, 1800, Some("core")), t);
        assert_eq!(budget.slowdown("api.github.com", "core", t), 4.0);
        assert!(budget.allows_background("api.github.com", "core", t));

        budget.record(url, 200, &headers(499, 5000, 1800, Some("core")), t);
        assert!(!budget.allows_background("api.github.com", "core", t));
        assert!(budget.paused_until("https://api.github.com/repos/a/b", t).is_none());

        let later = t + Duration::seconds(1801);
        assert!(budget.allows_background("api.github.com", "core", later));
        assert_eq!(budget.slowdown("api.github.com", "core", later), 1.0);
    }

    #[test]
    fn used_up_pauses_until_reset_per_limit() {
        let budget = ForgeRateBudget::new();
        let t = now();
        let rest = "https://api.github.com/repos/a/b/pulls/1";
        budget.record(rest, 403, &headers(0, 5000, 600, Some("core")), t);
        assert_eq!(budget.paused_until(rest, t), Some(t + Duration::seconds(600)));
        assert!(budget.paused_until("https://api.github.com/graphql", t).is_none());
        assert!(budget.paused_until("https://gitlab.com/api/v4/projects", t).is_none());
        assert!(budget.paused_until(rest, t + Duration::seconds(601)).is_none());
    }

    #[test]
    fn refusal_without_time_waits_longer_each_time() {
        let budget = ForgeRateBudget::new();
        let t = now();
        let url = "https://ghe.example.com/api/v3/repos/a/b";
        budget.record(url, 429, &[], t);
        assert_eq!(budget.paused_until(url, t), Some(t + Duration::seconds(30)));
        budget.record(url, 429, &[], t);
        assert_eq!(budget.paused_until(url, t), Some(t + Duration::seconds(60)));
        assert_eq!(ForgeRateBudget::fallback_pause(20), 15 * 60);

        budget.record(url, 403, &[("Retry-After".into(), "90".into())], t);
        assert_eq!(budget.paused_until(url, t), Some(t + Duration::seconds(90)));
    }

    #[test]
    fn graphql_goes_first_until_it_runs_low() {
        let budget = ForgeRateBudget::new();
        let t = now();
        assert!(budget.prefers_graphql("api.github.com", t));

        budget.record("https://api.github.com/graphql", 200, &headers(1500, 5000, 1800, Some("graphql")), t);
        assert!(budget.prefers_graphql("api.github.com", t));

        budget.record("https://api.github.com/graphql", 200, &headers(1000, 5000, 1800, Some("graphql")), t);
        assert!(!budget.prefers_graphql("api.github.com", t));

        budget.record("https://api.github.com/repos/a/b", 200, &headers(500, 5000, 1800, Some("core")), t);
        assert!(budget.prefers_graphql("api.github.com", t));

        budget.record("https://api.github.com/repos/a/b", 403, &headers(0, 5000, 1800, Some("core")), t);
        assert!(budget.prefers_graphql("api.github.com", t));
        assert!(budget.allows_background_for_page(Some("https://github.com/a/b/pull/1"), true, t));
        assert!(!budget.allows_background_for_page(Some("https://github.com/a/b/pull/1"), false, t));

        budget.record("https://api.github.com/graphql", 403, &headers(0, 5000, 1800, Some("graphql")), t);
        assert!(!budget.prefers_graphql("api.github.com", t));
    }

    #[test]
    fn resource_and_api_host_classification() {
        assert_eq!(ForgeRateBudget::resource(&Url::parse("https://api.github.com/graphql").unwrap()), "graphql");
        assert_eq!(ForgeRateBudget::resource(&Url::parse("https://ghe.example.com/api/graphql").unwrap()), "graphql");
        assert_eq!(ForgeRateBudget::resource(&Url::parse("https://api.github.com/search/issues?q=x").unwrap()), "search");
        assert_eq!(ForgeRateBudget::resource(&Url::parse("https://api.github.com/repos/a/b").unwrap()), "core");
        assert_eq!(ForgeRateBudget::api_host(Some("https://github.com/a/b/pull/1")), Some("api.github.com".into()));
        assert_eq!(ForgeRateBudget::api_host(Some("https://ghe.example.com/a/b/pull/1")), Some("ghe.example.com".into()));
    }

    #[test]
    fn local_refusal_reports_rate_limited_kind() {
        let err = ForgeRateBudget::local_refusal("https://api.github.com/repos/a/b/pulls/1", now() + Duration::seconds(600));
        assert_eq!(err.kind, ErrorKind::RateLimited);
        assert!(err.message.contains("api.github.com"));
    }
}
