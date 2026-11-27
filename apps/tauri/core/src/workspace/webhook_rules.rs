//! Webhook rules, persisted deliveries and public relay protocol (`WebhookRules.swift` and `WebhookRelay.swift` on the
//! Mac, AG-131 / #1677):
//! - Filters (`equals`, `oneOf`, `exists`) evaluated against verified deliveries before starting a run.
//! - Duplicate key templates (`{{headers.x-github-delivery}}`) with a bounded 7-day deduplication window.
//! - Burst coalescing (`10..=3600` seconds) that folds deliveries in one window into a single run with the latest body.
//! - Bounded delivery log (at most 50 entries per task, newest first).
//! - Persisted waiting deliveries (`SavedWebhookDelivery`) restored across restarts (at most 24 hours old).
//! - Public webhook relay room derivation (`HMAC-SHA256(token, "nook-webhook-room")[..32]`), URLs, and WebSocket message
//!   framing compatible with `apps/relay/worker/hooks.js`.

use std::collections::{BTreeMap, HashMap, HashSet};

use base64::Engine as _;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use super::schedule::WebhookQueue;
use super::webhook::{self, Delivery, Request, MAX_BODY_BYTES};
use crate::companion::transport::normalize_relay;

/// What a name such as `body.pull_request.number`, `body.items.0.id`, `body` or `headers.x-github-event` points at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WebhookValue {
    Missing,
    /// Text, a number or a boolean, as text.
    Text(String),
    /// An object or a list, as compact JSON: only `exists` passes on it.
    Structured(String),
}

impl WebhookValue {
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Missing => None,
            Self::Text(s) | Self::Structured(s) => Some(s.as_str()),
        }
    }
}

/// One test on a delivery (`WebhookFilter.Test` on the Mac). Unknown tests fall back to `Equals`, which fails safely
/// when the value is missing instead of accidentally passing as `Exists`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WebhookFilterTest {
    #[default]
    Equals,
    OneOf,
    Exists,
}

impl<'de> Deserialize<'de> for WebhookFilterTest {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        match String::deserialize(d).unwrap_or_default().as_str() {
            "oneOf" => Ok(Self::OneOf),
            "exists" => Ok(Self::Exists),
            _ => Ok(Self::Equals),
        }
    }
}

/// One filter rule on a webhook task (`WebhookFilter` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebhookFilter {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub field: String,
    #[serde(default)]
    pub test: WebhookFilterTest,
    /// For `OneOf`: comma-separated choices.
    #[serde(default)]
    pub value: String,
}

impl WebhookFilter {
    pub fn new(field: impl Into<String>, test: WebhookFilterTest, value: impl Into<String>) -> Self {
        Self { id: Uuid::new_v4(), field: field.into(), test, value: value.into() }
    }

    /// The choices of `OneOf`, trimmed, without empty entries.
    pub fn choices(&self) -> Vec<&str> {
        self.value.split(',').map(str::trim).filter(|s| !s.is_empty()).collect()
    }

    pub fn passes(&self, delivery: &Delivery) -> bool {
        let found = delivery.typed_value(&self.field);
        match self.test {
            WebhookFilterTest::Exists => found != WebhookValue::Missing,
            WebhookFilterTest::Equals => matches!(found, WebhookValue::Text(ref t) if t == &self.value),
            WebhookFilterTest::OneOf => matches!(found, WebhookValue::Text(ref t) if self.choices().contains(&t.as_str())),
        }
    }

    /// `"body.action ∈ opened, reopened"`, for the deliveries log.
    pub fn summary(&self) -> String {
        match self.test {
            WebhookFilterTest::Equals => format!("{} = {}", self.field, self.value),
            WebhookFilterTest::OneOf => format!("{} ∈ {}", self.field, self.choices().join(", ")),
            WebhookFilterTest::Exists => format!("{} exists", self.field),
        }
    }
}

/// The rules of one webhook task (`WebhookRules` on the Mac).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebhookRules {
    /// Every filter must pass, or the delivery starts nothing.
    pub filters: Vec<WebhookFilter>,
    /// A template such as `{{headers.x-github-delivery}}`: a delivery with a key seen in the last week is skipped.
    pub duplicate_key: String,
    /// Deliveries within this many seconds of the first become one run, with the latest delivery. 0 is off.
    pub coalesce_seconds: u32,
}

impl WebhookRules {
    pub const COALESCE_MIN: u32 = 10;
    pub const COALESCE_MAX: u32 = 3600;
    pub const DUPLICATE_WINDOW_SECONDS: i64 = 7 * 24 * 3600;

    pub fn is_empty(&self) -> bool {
        self.filters.is_empty() && self.duplicate_key.trim().is_empty() && self.coalesce_seconds == 0
    }

    /// The coalesce window in seconds, or `None` when off. Stored values outside `10..=3600` are clamped into range.
    pub fn coalesce_window(&self) -> Option<i64> {
        if self.coalesce_seconds == 0 {
            return None;
        }
        Some(i64::from(self.coalesce_seconds.clamp(Self::COALESCE_MIN, Self::COALESCE_MAX)))
    }

    /// Returns a normalized copy: trimmed fields/keys and clamped coalesce seconds.
    pub fn cleaned(&self) -> Self {
        let filters = self
            .filters
            .iter()
            .filter_map(|f| {
                let field = f.field.trim();
                (!field.is_empty()).then(|| WebhookFilter {
                    id: f.id,
                    field: field.to_string(),
                    test: f.test,
                    value: f.value.trim().to_string(),
                })
            })
            .collect();
        let duplicate_key = self.duplicate_key.trim().to_string();
        let coalesce_seconds =
            if self.coalesce_seconds > 0 { self.coalesce_seconds.clamp(Self::COALESCE_MIN, Self::COALESCE_MAX) } else { 0 };
        Self { filters, duplicate_key, coalesce_seconds }
    }

    /// The first filter that fails, or `None` when the delivery may run.
    pub fn failing_filter(&self, delivery: &Delivery) -> Option<&WebhookFilter> {
        self.filters.iter().find(|f| !f.passes(delivery))
    }
}

/// Fills a key template such as `{{headers.x-github-delivery}}` or `{{body.pull_request.id}}-{{body.action}}` with
/// plain values (`WebhookTemplate.renderKey` on the Mac). Returns `None` when the template names no placeholder, when
/// any placeholder is missing or empty, or when the rendered result is empty.
pub fn render_key(template: &str, delivery: &Delivery) -> Option<String> {
    let found = webhook::template_matches(template);
    if found.is_empty() {
        return None;
    }
    let mut rendered = String::new();
    let mut cursor = 0;
    for (start, end, name) in found {
        rendered += &template[cursor..start];
        let val = delivery.typed_value(&name);
        let text = val.as_text()?;
        if text.is_empty() {
            return None;
        }
        rendered += text;
        cursor = end;
    }
    rendered += &template[cursor..];
    let trimmed = rendered.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.chars().take(512).collect())
}

/// Keys of deliveries seen in the last week, per task, so the same event delivered again runs once (`WebhookDedupe`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebhookDedupe {
    pub seen: HashMap<String, DateTime<Utc>>,
}

impl WebhookDedupe {
    pub const CAPACITY: usize = 500;

    /// True the first time `key` is seen within `window` seconds; records it and evicts expired/oldest entries.
    pub fn claim(&mut self, key: &str, now: DateTime<Utc>, window_seconds: i64) -> bool {
        let cutoff = now - Duration::seconds(window_seconds);
        self.seen.retain(|_, at| *at > cutoff);
        if self.seen.contains_key(key) {
            return false;
        }
        self.seen.insert(key.to_string(), now);
        while self.seen.len() > Self::CAPACITY {
            if let Some(oldest) = self.seen.iter().min_by_key(|(_, at)| *at).map(|(k, _)| k.clone()) {
                self.seen.remove(&oldest);
            } else {
                break;
            }
        }
        true
    }
}

/// An accepted delivery whose run had not started yet, saved with the tasks so a quit or crash does not lose it
/// (`SavedWebhookDelivery` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedWebhookDelivery {
    pub id: String,
    /// Base64-encoded raw request body.
    pub body: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    pub received_at: DateTime<Utc>,
    /// Deliveries a coalesce window folded into this one.
    #[serde(default = "default_combined")]
    pub combined: usize,
}

fn default_combined() -> usize {
    1
}

impl SavedWebhookDelivery {
    /// Deliveries older than this at launch are no longer news and are dropped.
    pub const MAX_AGE_SECONDS: i64 = 24 * 3600;

    pub fn from_delivery(d: &Delivery) -> Self {
        Self {
            id: d.id.clone(),
            body: base64::engine::general_purpose::STANDARD.encode(&d.body),
            headers: d.headers.clone(),
            received_at: d.received_at,
            combined: d.combined.max(1),
        }
    }

    pub fn into_delivery(self) -> Option<Delivery> {
        let body = base64::engine::general_purpose::STANDARD.decode(&self.body).ok()?;
        if body.len() > MAX_BODY_BYTES {
            return None;
        }
        Some(Delivery { id: self.id, body, headers: self.headers, received_at: self.received_at, combined: self.combined.max(1) })
    }

    /// Restores waiting deliveries at launch: only for tasks that still take webhooks, not older than 24 hours,
    /// oldest first, capped at `WebhookQueue::MAX_QUEUED_PER_TASK`.
    pub fn restore(
        saved: HashMap<Uuid, Vec<SavedWebhookDelivery>>,
        webhook_tasks: &HashSet<Uuid>,
        now: DateTime<Utc>,
    ) -> HashMap<Uuid, Vec<SavedWebhookDelivery>> {
        let cutoff = now - Duration::seconds(Self::MAX_AGE_SECONDS);
        let mut out = HashMap::new();
        for (task, list) in saved {
            if !webhook_tasks.contains(&task) {
                continue;
            }
            let mut fresh: Vec<SavedWebhookDelivery> = list.into_iter().filter(|d| d.received_at >= cutoff).collect();
            fresh.sort_by_key(|d| d.received_at);
            fresh.truncate(WebhookQueue::MAX_QUEUED_PER_TASK);
            if !fresh.is_empty() {
                out.insert(task, fresh);
            }
        }
        out
    }
}

/// An open coalesce window for a task (`WebhookCoalescer.Window` on the Mac).
#[derive(Debug, Clone)]
pub struct CoalesceWindow<D> {
    pub closes_at: DateTime<Utc>,
    pub latest: D,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoalesceOutcome {
    /// A new window opened: flush it at `closes_at`.
    Opened { closes_at: DateTime<Utc> },
    /// Folded into an open window; `count` deliveries are in it now.
    Merged { count: usize },
}

/// Folds a burst of deliveries into one run: the window opens with the first delivery and closes `seconds` later
/// (later deliveries do not extend it); the run gets the latest delivery and the count.
#[derive(Debug)]
pub struct WebhookCoalescer<D> {
    windows: HashMap<Uuid, CoalesceWindow<D>>,
}

impl<D> Default for WebhookCoalescer<D> {
    fn default() -> Self {
        Self { windows: HashMap::new() }
    }
}

impl<D> WebhookCoalescer<D> {
    pub fn has_open(&self, task: Uuid, now: DateTime<Utc>) -> bool {
        self.windows.get(&task).is_some_and(|w| w.closes_at > now)
    }

    pub fn has_any(&self, task: Uuid) -> bool {
        self.windows.contains_key(&task)
    }

    pub fn add(&mut self, delivery: D, task: Uuid, seconds: i64, now: DateTime<Utc>) -> CoalesceOutcome {
        if let Some(window) = self.windows.get_mut(&task) {
            if window.closes_at > now {
                window.latest = delivery;
                window.count += 1;
                return CoalesceOutcome::Merged { count: window.count };
            }
        }
        let closes_at = now + Duration::seconds(seconds);
        self.windows.insert(task, CoalesceWindow { closes_at, latest: delivery, count: 1 });
        CoalesceOutcome::Opened { closes_at }
    }

    /// Removes and returns the window of `task` once it has closed; `None` while still open or absent.
    pub fn flush(&mut self, task: Uuid, now: DateTime<Utc>) -> Option<CoalesceWindow<D>> {
        if self.windows.get(&task).is_some_and(|w| w.closes_at <= now) {
            self.windows.remove(&task)
        } else {
            None
        }
    }

    /// Removes and returns every window whose `closes_at <= now`.
    pub fn flush_due(&mut self, now: DateTime<Utc>) -> Vec<(Uuid, CoalesceWindow<D>)> {
        let ready: Vec<Uuid> = self.windows.iter().filter(|(_, w)| w.closes_at <= now).map(|(id, _)| *id).collect();
        ready.into_iter().filter_map(|id| self.windows.remove(&id).map(|w| (id, w))).collect()
    }

    pub fn forget(&mut self, task: Uuid) -> bool {
        self.windows.remove(&task).is_some()
    }

    pub fn next_deadline(&self) -> Option<DateTime<Utc>> {
        self.windows.values().map(|w| w.closes_at).min()
    }

    pub fn windows(&self) -> &HashMap<Uuid, CoalesceWindow<D>> {
        &self.windows
    }
}

/// Outcome of one verified delivery, for the task's Deliveries log (`WebhookDeliveryRecord.Outcome`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WebhookDeliveryOutcome {
    Accepted,
    Filtered,
    Duplicate,
    Coalesced,
    QueueFull,
}

/// One row in a task's Deliveries log (`WebhookDeliveryRecord` on the Mac).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebhookDeliveryRecord {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    pub delivery_id: String,
    pub received_at: DateTime<Utc>,
    pub outcome: WebhookDeliveryOutcome,
    /// Plain detail for the log: failing filter summary, duplicate key, burst count, or window seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl WebhookDeliveryRecord {
    pub const LIMIT: usize = 50;

    pub fn new(delivery_id: impl Into<String>, outcome: WebhookDeliveryOutcome, detail: Option<String>, now: DateTime<Utc>) -> Self {
        Self { id: Uuid::new_v4(), delivery_id: delivery_id.into(), received_at: now, outcome, detail }
    }

    /// Prepends `record` (newest first) and trims `log` to at most `LIMIT` items.
    pub fn prepend(log: &mut Vec<Self>, record: Self) {
        log.insert(0, record);
        log.truncate(Self::LIMIT);
    }
}

// MARK: Public webhook relay (`WebhookRelay.swift` / `apps/relay/worker/hooks.js`)

const RELAY_LABEL: &str = "nook-webhook-room";

/// Secret store account for the computer's public webhook relay token (matches macOS).
pub const RELAY_TOKEN_ACCOUNT: &str = "scheduled-task-webhook.relay-token";

/// The relay room derived from `token`: first 32 hex chars of `HMAC-SHA256(token, "nook-webhook-room")`.
/// Public URLs name only the room, so callers can POST webhooks without being able to listen.
pub fn relay_room(token: &str) -> String {
    let mac = webhook::hmac_sha256(token.as_bytes(), RELAY_LABEL.as_bytes());
    webhook::hex(&mac).chars().take(32).collect()
}

/// Public URL to give an external webhook sender (`{relay}/v1/hooks/{room}/{task}`).
pub fn relay_public_url(relay: &str, token: &str, task: Uuid) -> Option<String> {
    let base = normalize_relay(relay)?;
    Some(format!("{base}/v1/hooks/{}/{task}", relay_room(token)))
}

/// WebSocket URL the desktop connects out to (`wss://.../v1/hooks/{room}/listen`).
pub fn relay_listen_url(relay: &str, token: &str) -> Option<String> {
    let base = normalize_relay(relay)?;
    let ws = base.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    Some(format!("{ws}/v1/hooks/{}/listen", relay_room(token)))
}

/// A webhook request forwarded by the relay over the listening WebSocket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayIncoming {
    pub id: String,
    pub request: Request,
}

/// Parses one JSON frame sent by `apps/relay/worker/hooks.js`: `{ id, path, headers, body (base64) }`.
pub fn parse_relay_incoming(text: &str) -> Option<RelayIncoming> {
    let object: Value = serde_json::from_str(text).ok()?;
    let id = object.get("id")?.as_str()?.to_string();
    let path = object.get("path")?.as_str()?.to_string();
    let encoded = object.get("body")?.as_str()?;
    let body = base64::engine::general_purpose::STANDARD.decode(encoded).ok()?;
    if body.len() > MAX_BODY_BYTES {
        return None;
    }
    let mut headers = BTreeMap::new();
    if let Some(map) = object.get("headers").and_then(Value::as_object) {
        for (k, v) in map {
            if let Some(s) = v.as_str() {
                headers.entry(k.to_ascii_lowercase()).or_insert_with(|| s.to_string());
            }
        }
    }
    Some(RelayIncoming { id, request: Request { method: "POST".into(), path, headers, body } })
}

/// Formats the JSON answer sent back to the relay for a delivered webhook request.
pub fn format_relay_answer(id: &str, status: u16, message: &str) -> String {
    json!({ "id": id, "message": message, "status": status }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn delivery(body: &str, headers: &[(&str, &str)]) -> Delivery {
        let headers = headers.iter().map(|(k, v)| (k.to_ascii_lowercase(), (*v).to_string())).collect();
        Delivery { id: "d1".into(), body: body.as_bytes().to_vec(), headers, received_at: utc("2026-11-27T10:00:00Z"), combined: 1 }
    }

    #[test]
    fn filters_match_equals_one_of_and_exists_and_treat_objects_as_structured() {
        let d = delivery(
            r#"{"action":"opened","draft":false,"number":42,"pull_request":{"title":"Fix","labels":["bug"]}}"#,
            &[("X-GitHub-Event", "pull_request")],
        );
        assert!(WebhookFilter::new("headers.x-github-event", WebhookFilterTest::Equals, "pull_request").passes(&d));
        assert!(WebhookFilter::new("body.action", WebhookFilterTest::OneOf, "opened, reopened").passes(&d));
        assert!(!WebhookFilter::new("body.action", WebhookFilterTest::OneOf, "closed, merged").passes(&d));
        assert!(WebhookFilter::new("body.draft", WebhookFilterTest::Equals, "false").passes(&d));
        assert!(WebhookFilter::new("body.number", WebhookFilterTest::Equals, "42").passes(&d));
        // Structured object/array only passes `exists`, never `equals` or `oneOf`.
        assert!(WebhookFilter::new("body.pull_request", WebhookFilterTest::Exists, "").passes(&d));
        assert!(!WebhookFilter::new("body.pull_request", WebhookFilterTest::Equals, r#"{"labels":["bug"],"title":"Fix"}"#).passes(&d));
        assert!(!WebhookFilter::new("body.missing", WebhookFilterTest::Exists, "").passes(&d));
    }

    #[test]
    fn render_key_requires_all_placeholders_present() {
        let d = delivery(r#"{"action":"opened","pull_request":{"id":99}}"#, &[("X-GitHub-Delivery", "abc-1")]);
        assert_eq!(render_key("{{headers.x-github-delivery}}", &d).as_deref(), Some("abc-1"));
        assert_eq!(render_key("{{body.pull_request.id}}-{{body.action}}", &d).as_deref(), Some("99-opened"));
        assert_eq!(render_key("{{body.missing}}-{{body.action}}", &d), None);
        assert_eq!(render_key("plain-no-placeholder", &d), None);
    }

    #[test]
    fn dedupe_expires_after_window_and_caps_capacity() {
        let t0 = utc("2026-11-20T10:00:00Z");
        let mut dedupe = WebhookDedupe::default();
        assert!(dedupe.claim("k1", t0, WebhookRules::DUPLICATE_WINDOW_SECONDS));
        assert!(!dedupe.claim("k1", t0 + Duration::days(6), WebhookRules::DUPLICATE_WINDOW_SECONDS));
        assert!(dedupe.claim("k1", t0 + Duration::days(8), WebhookRules::DUPLICATE_WINDOW_SECONDS));

        for i in 0..(WebhookDedupe::CAPACITY + 25) {
            assert!(dedupe.claim(&format!("key-{i}"), t0 + Duration::seconds(i as i64), WebhookRules::DUPLICATE_WINDOW_SECONDS));
        }
        assert_eq!(dedupe.seen.len(), WebhookDedupe::CAPACITY);
    }

    #[test]
    fn coalescer_folds_burst_without_extending_window() {
        let task = Uuid::new_v4();
        let t0 = utc("2026-11-27T10:00:00Z");
        let mut c = WebhookCoalescer::default();
        assert_eq!(c.add("first", task, 60, t0), CoalesceOutcome::Opened { closes_at: t0 + Duration::seconds(60) });
        assert_eq!(c.add("second", task, 60, t0 + Duration::seconds(30)), CoalesceOutcome::Merged { count: 2 });
        assert_eq!(c.add("third", task, 60, t0 + Duration::seconds(59)), CoalesceOutcome::Merged { count: 3 });
        assert!(c.flush(task, t0 + Duration::seconds(59)).is_none());
        let closed = c.flush(task, t0 + Duration::seconds(60)).unwrap();
        assert_eq!(closed.latest, "third");
        assert_eq!(closed.count, 3);
        assert!(c.flush(task, t0 + Duration::seconds(61)).is_none());
    }

    #[test]
    fn saved_deliveries_restore_only_fresh_webhook_tasks_oldest_first() {
        let keep = Uuid::new_v4();
        let dropped = Uuid::new_v4();
        let now = utc("2026-11-27T12:00:00Z");
        let fresh_old = SavedWebhookDelivery {
            id: "a".into(),
            body: base64::engine::general_purpose::STANDARD.encode(b"1"),
            headers: BTreeMap::new(),
            received_at: now - Duration::hours(2),
            combined: 2,
        };
        let fresh_new = SavedWebhookDelivery {
            id: "b".into(),
            body: base64::engine::general_purpose::STANDARD.encode(b"2"),
            headers: BTreeMap::new(),
            received_at: now - Duration::minutes(5),
            combined: 1,
        };
        let stale = SavedWebhookDelivery {
            id: "old".into(),
            body: base64::engine::general_purpose::STANDARD.encode(b"0"),
            headers: BTreeMap::new(),
            received_at: now - Duration::hours(25),
            combined: 1,
        };
        let mut saved = HashMap::new();
        saved.insert(keep, vec![fresh_new.clone(), stale, fresh_old.clone()]);
        saved.insert(dropped, vec![fresh_new]);
        let tasks: HashSet<Uuid> = [keep].into_iter().collect();
        let restored = SavedWebhookDelivery::restore(saved, &tasks, now);
        assert!(!restored.contains_key(&dropped));
        let list = &restored[&keep];
        assert_eq!(list.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(), vec!["a", "b"]);
        assert_eq!(list[0].combined, 2);
    }

    #[test]
    fn relay_room_urls_and_frame_round_trip() {
        let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let room = relay_room(token);
        assert_eq!(room.len(), 32);
        assert!(room.chars().all(|c| c.is_ascii_hexdigit()));
        let task = Uuid::parse_str("11111111-2222-3333-4444-555555555555").unwrap();
        assert_eq!(
            relay_public_url("https://relay.nook.test/", token, task).as_deref(),
            Some(format!("https://relay.nook.test/v1/hooks/{room}/{task}").as_str())
        );
        assert_eq!(
            relay_listen_url("https://relay.nook.test", token).as_deref(),
            Some(format!("wss://relay.nook.test/v1/hooks/{room}/listen").as_str())
        );
        let frame = json!({
            "id": "req-1",
            "path": format!("/hooks/{task}"),
            "headers": { "X-Hub-Signature-256": "sha256=abc" },
            "body": base64::engine::general_purpose::STANDARD.encode(b"{\"ok\":true}"),
        })
        .to_string();
        let incoming = parse_relay_incoming(&frame).unwrap();
        assert_eq!(incoming.id, "req-1");
        assert_eq!(incoming.request.method, "POST");
        assert_eq!(incoming.request.headers.get("x-hub-signature-256").map(String::as_str), Some("sha256=abc"));
        assert_eq!(incoming.request.body, b"{\"ok\":true}");
        let ans: Value = serde_json::from_str(&format_relay_answer("req-1", 202, "accepted")).unwrap();
        assert_eq!(ans["id"], "req-1");
        assert_eq!(ans["status"], 202);
        assert_eq!(ans["message"], "accepted");
    }
}
