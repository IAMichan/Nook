//! Pushmeldingen voor de companion, alleen als beslissingen en inhoud (`CompanionPush.swift`). Het versturen naar
//! Apple (APNs) staat in [`super::apns`].
//!
//! Wat een melding zegt is bewust kort: Apple brengt hem over, dus standaard noemt hij de agent en wat er nodig is,
//! niet de titel van de sessie, en nooit een commando, bestand of antwoord.

use std::collections::BTreeSet;

use chrono::{DateTime, Timelike, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Value};

use super::models::{base64url_encode, DeliveryLog};

pub mod category {
    pub const APPROVAL_DENY: &str = "NOOK_APPROVAL_DENY";
    pub const APPROVAL_ALLOW: &str = "NOOK_APPROVAL_ALLOW";
    pub const QUESTION: &str = "NOOK_QUESTION";
    pub const INFO: &str = "NOOK_INFO";
    pub const ACTION_ALLOW: &str = "NOOK_ACTION_ALLOW";
    pub const ACTION_DENY: &str = "NOOK_ACTION_DENY";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PushKind {
    Approval,
    Question,
    Failed,
    Finished,
    Limited,
}

impl PushKind {
    pub const ALL: [PushKind; 5] = [PushKind::Approval, PushKind::Question, PushKind::Failed, PushKind::Finished, PushKind::Limited];

    pub fn raw(self) -> &'static str {
        match self {
            PushKind::Approval => "approval",
            PushKind::Question => "question",
            PushKind::Failed => "failed",
            PushKind::Finished => "finished",
            PushKind::Limited => "limited",
        }
    }

    fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.raw() == raw)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PushEvent {
    pub kind: PushKind,
    pub session: String,
    /// De goedkeuring of vraag waar de knoppen over gaan.
    pub item: Option<String>,
    pub agent: String,
    pub title: String,
    /// De telefoon mag deze goedkeuring vanuit de melding toestaan.
    pub can_allow: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PushSettings {
    pub enabled: bool,
    #[serde(serialize_with = "kinds_out", deserialize_with = "kinds_in")]
    pub kinds: BTreeSet<PushKind>,
    /// Alleen als je niet bij de computer bent: aan je bureau zijn de kaarten van Nook genoeg.
    pub only_when_away: bool,
    /// De titel van de sessie in de melding. Standaard uit: Apple ziet de tekst.
    pub include_title: bool,
    /// Stille uren als uur van de dag (0…23); beide leeg = geen.
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "hour_in")]
    pub quiet_from: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "hour_in")]
    pub quiet_to: Option<u32>,
    pub quiet_allows_urgent: bool,
}

impl Default for PushSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            kinds: [PushKind::Approval, PushKind::Question, PushKind::Failed, PushKind::Finished].into(),
            only_when_away: true,
            include_title: false,
            quiet_from: None,
            quiet_to: None,
            quiet_allows_urgent: true,
        }
    }
}

fn kinds_out<S: Serializer>(kinds: &BTreeSet<PushKind>, s: S) -> Result<S::Ok, S::Error> {
    let mut raw: Vec<&str> = kinds.iter().map(|k| k.raw()).collect();
    raw.sort();
    raw.serialize(s)
}

/// Onbekende soorten vallen weg in plaats van alles te laten mislukken.
fn kinds_in<'de, D: Deserializer<'de>>(d: D) -> Result<BTreeSet<PushKind>, D::Error> {
    let raw = Value::deserialize(d)?;
    Ok(raw.as_array().map(|list| list.iter().filter_map(|v| v.as_str().and_then(PushKind::from_raw)).collect()).unwrap_or_default())
}

fn hour_in<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
    let raw = Value::deserialize(d)?;
    Ok(raw.as_u64().filter(|h| *h <= 23).map(|h| h as u32))
}

impl PushSettings {
    /// Leest wat er is; wat ontbreekt of niet klopt krijgt de standaardwaarde (zoals de tolerante decoder op de Mac).
    pub fn from_value(value: &Value) -> Self {
        serde_json::from_value(value.clone()).unwrap_or_default()
    }

    /// `hour` is het uur van de dag in de tijdzone van de gebruiker.
    pub fn in_quiet_hours(&self, hour: u32) -> bool {
        match (self.quiet_from, self.quiet_to) {
            (Some(from), Some(to)) if from != to => {
                if from < to {
                    hour >= from && hour < to
                } else {
                    hour >= from || hour < to
                }
            }
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushSkip {
    Disabled,
    KindOff,
    AtTheComputer,
    QuietHours,
    Duplicate,
    NoDevices,
}

pub fn is_urgent(kind: PushKind) -> bool {
    matches!(kind, PushKind::Approval | PushKind::Question)
}

/// `None` = versturen. `hour` is het lokale uur van nu.
pub fn skip_reason(event: &PushEvent, settings: &PushSettings, away: bool, hour: u32) -> Option<PushSkip> {
    if !settings.enabled {
        return Some(PushSkip::Disabled);
    }
    if !settings.kinds.contains(&event.kind) {
        return Some(PushSkip::KindOff);
    }
    if settings.only_when_away && !away {
        return Some(PushSkip::AtTheComputer);
    }
    if settings.in_quiet_hours(hour) && !(settings.quiet_allows_urgent && is_urgent(event.kind)) {
        return Some(PushSkip::QuietHours);
    }
    None
}

/// De categorie van de melding, die de knoppen bepaalt: Weiger (en Sta toe als het laag risico is) bij een goedkeuring.
pub fn push_category(event: &PushEvent) -> &'static str {
    match event.kind {
        PushKind::Approval if event.can_allow => category::APPROVAL_ALLOW,
        PushKind::Approval => category::APPROVAL_DENY,
        PushKind::Question => category::QUESTION,
        _ => category::INFO,
    }
}

/// Onthoudt wat er verstuurd is, zodat dezelfde goedkeuring of dezelfde klare beurt niet twee keer zoemt.
pub struct PushLedger {
    log: DeliveryLog,
}

impl Default for PushLedger {
    fn default() -> Self {
        Self { log: DeliveryLog::new(300) }
    }
}

impl PushLedger {
    pub fn key(event: &PushEvent, turn: i64) -> String {
        format!("{}:{}:{}", event.kind.raw(), event.session, event.item.clone().unwrap_or_else(|| turn.to_string()))
    }

    /// Waar als de gebeurtenis nieuw is.
    pub fn admit(&mut self, event: &PushEvent, turn: i64) -> bool {
        self.log.record(&Self::key(event, turn))
    }
}

/// De JSON van een melding. `title` en `body` staan al in de taal van de gebruiker; `badge` is hoeveel sessies je nodig
/// hebben. Eigen gegevens staan onder "nook" en zijn alleen ids.
pub fn apns_payload(event: &PushEvent, title: &str, body: &str, badge: i64) -> Value {
    let mut nook = json!({ "session": event.session });
    if let Some(item) = &event.item {
        nook["item"] = json!(item);
    }
    json!({
        "aps": {
            "alert": { "title": title, "body": body },
            "sound": "default",
            "category": push_category(event),
            "thread-id": event.session,
            "badge": badge.max(0),
            "interruption-level": if is_urgent(event.kind) { "time-sensitive" } else { "active" },
            "content-available": 1,
        },
        "nook": nook,
    })
}

/// Eén melding per goedkeuring of vraag (zodat hij vervangen kan worden), anders één per beurt van een sessie.
pub fn collapse_id(event: &PushEvent, turn: i64) -> String {
    PushLedger::key(event, turn).chars().take(64).collect()
}

/// APNs weigert tokens ouder dan een uur en een nieuwe vaker dan elke 20 minuten.
pub const JWT_LIFETIME_SECS: i64 = 50 * 60;

/// Het ongetekende deel van de JWT voor APNs: `header.claims` (ES256).
pub fn jwt_signing_input(key_id: &str, team_id: &str, issued_at: DateTime<Utc>) -> Option<String> {
    if !valid_identifier(key_id) || !valid_identifier(team_id) {
        return None;
    }
    let header = format!(r#"{{"alg":"ES256","kid":"{key_id}"}}"#);
    let claims = format!(r#"{{"iss":"{team_id}","iat":{}}}"#, issued_at.timestamp());
    Some(format!("{}.{}", base64url_encode(header.as_bytes()), base64url_encode(claims.as_bytes())))
}

/// Sleutel- en team-ids zijn tien letters en cijfers.
pub fn valid_identifier(text: &str) -> bool {
    text.len() == 10 && text.chars().all(|c| c.is_ascii_alphanumeric())
}

/// Een toesteltoken is hex (nu 32 bytes, meer mag).
pub fn valid_token(text: &str) -> bool {
    (32..=200).contains(&text.len()) && text.chars().all(|c| c.is_ascii_hexdigit())
}

pub fn endpoint(production: bool, device_token: &str) -> Option<String> {
    if !valid_token(device_token) {
        return None;
    }
    let host = if production { "api.push.apple.com" } else { "api.sandbox.push.apple.com" };
    Some(format!("https://{host}/3/device/{}", device_token.to_lowercase()))
}

pub fn token_hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}

/// Wat een antwoord van Apple betekent voor het bewaarde token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Delivered,
    DropToken,
    RetryLater,
    Configuration,
}

pub fn outcome(status: u16, reason: Option<&str>) -> Outcome {
    match status {
        200 => Outcome::Delivered,
        410 => Outcome::DropToken,
        400 if matches!(reason, Some("BadDeviceToken") | Some("DeviceTokenNotForTopic")) => Outcome::DropToken,
        429 | 500 | 503 => Outcome::RetryLater,
        _ => Outcome::Configuration,
    }
}

/// Het lokale uur, voor de stille uren.
pub fn local_hour() -> u32 {
    chrono::Local::now().hour()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companion::models::base64url_decode;

    fn event(kind: PushKind, can_allow: bool) -> PushEvent {
        PushEvent {
            kind,
            session: "S1".into(),
            item: matches!(kind, PushKind::Approval | PushKind::Question).then(|| "I1".into()),
            agent: "Claude Code".into(),
            title: "Fix login".into(),
            can_allow,
        }
    }

    #[test]
    fn disabled_and_kind_off() {
        let mut s = PushSettings::default();
        assert_eq!(skip_reason(&event(PushKind::Approval, false), &s, true, 12), Some(PushSkip::Disabled));
        s.enabled = true;
        assert_eq!(skip_reason(&event(PushKind::Approval, false), &s, true, 12), None);
        assert_eq!(skip_reason(&event(PushKind::Limited, false), &s, true, 12), Some(PushSkip::KindOff));
    }

    #[test]
    fn only_when_away() {
        let mut s = PushSettings { enabled: true, ..Default::default() };
        assert_eq!(skip_reason(&event(PushKind::Approval, false), &s, false, 12), Some(PushSkip::AtTheComputer));
        s.only_when_away = false;
        assert_eq!(skip_reason(&event(PushKind::Approval, false), &s, false, 12), None);
    }

    #[test]
    fn quiet_hours_wrap_midnight_and_let_urgent_through() {
        let mut s = PushSettings { enabled: true, quiet_from: Some(22), quiet_to: Some(7), ..Default::default() };
        assert!(s.in_quiet_hours(23));
        assert!(s.in_quiet_hours(3));
        assert!(!s.in_quiet_hours(12));
        assert_eq!(skip_reason(&event(PushKind::Approval, false), &s, true, 23), None);
        assert_eq!(skip_reason(&event(PushKind::Finished, false), &s, true, 23), Some(PushSkip::QuietHours));
        s.quiet_allows_urgent = false;
        assert_eq!(skip_reason(&event(PushKind::Approval, false), &s, true, 23), Some(PushSkip::QuietHours));
        s.quiet_from = Some(9);
        s.quiet_to = Some(9);
        assert!(!s.in_quiet_hours(9), "gelijke uren betekent geen stille uren");
    }

    #[test]
    fn category_decides_the_buttons() {
        assert_eq!(push_category(&event(PushKind::Approval, true)), category::APPROVAL_ALLOW);
        assert_eq!(push_category(&event(PushKind::Approval, false)), category::APPROVAL_DENY);
        assert_eq!(push_category(&event(PushKind::Question, false)), category::QUESTION);
        assert_eq!(push_category(&event(PushKind::Finished, false)), category::INFO);
    }

    #[test]
    fn ledger_dedupes() {
        let mut ledger = PushLedger::default();
        assert!(ledger.admit(&event(PushKind::Approval, false), 0));
        assert!(!ledger.admit(&event(PushKind::Approval, false), 0));
        assert!(ledger.admit(&event(PushKind::Finished, false), 1));
        assert!(!ledger.admit(&event(PushKind::Finished, false), 1));
        assert!(ledger.admit(&event(PushKind::Finished, false), 2));
    }

    #[test]
    fn payload_carries_ids_and_no_secrets() {
        let payload = apns_payload(&event(PushKind::Approval, true), "Claude Code", "Wacht op toestemming", 2);
        assert_eq!(payload["aps"]["category"], category::APPROVAL_ALLOW);
        assert_eq!(payload["aps"]["badge"], 2);
        assert_eq!(payload["aps"]["thread-id"], "S1");
        assert_eq!(payload["nook"]["item"], "I1");
        assert!(!payload.to_string().contains("Fix login"), "de titel blijft eruit tenzij gekozen");
        assert_eq!(collapse_id(&event(PushKind::Approval, false), 0), "approval:S1:I1");
    }

    #[test]
    fn jwt_input() {
        let issued = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let input = jwt_signing_input("ABC123DEFG", "35SMNHP9K7", issued).unwrap();
        let parts: Vec<&str> = input.split('.').collect();
        assert_eq!(parts.len(), 2);
        assert_eq!(base64url_decode(parts[0]).unwrap(), br#"{"alg":"ES256","kid":"ABC123DEFG"}"#);
        assert_eq!(base64url_decode(parts[1]).unwrap(), br#"{"iss":"35SMNHP9K7","iat":1700000000}"#);
        assert!(jwt_signing_input("bad", "35SMNHP9K7", issued).is_none());
        assert!(jwt_signing_input("ABC123DEFG\"}", "35SMNHP9K7", issued).is_none(), "geen injectie in de JSON");
    }

    #[test]
    fn endpoint_and_tokens() {
        let token = "ab".repeat(32);
        assert!(endpoint(true, &token).unwrap().starts_with("https://api.push.apple.com/3/device/"));
        assert!(endpoint(false, &token.to_uppercase()).unwrap().starts_with("https://api.sandbox.push.apple.com/"));
        assert!(endpoint(true, &token.to_uppercase()).unwrap().ends_with(&token));
        assert!(endpoint(true, "../x").is_none());
        assert!(endpoint(true, "abcd").is_none());
        assert_eq!(token_hex(&[0x0a, 0xff]), "0aff");
    }

    #[test]
    fn outcomes() {
        assert_eq!(outcome(200, None), Outcome::Delivered);
        assert_eq!(outcome(410, Some("Unregistered")), Outcome::DropToken);
        assert_eq!(outcome(400, Some("BadDeviceToken")), Outcome::DropToken);
        assert_eq!(outcome(400, Some("PayloadEmpty")), Outcome::Configuration);
        assert_eq!(outcome(403, Some("InvalidProviderToken")), Outcome::Configuration);
        assert_eq!(outcome(429, None), Outcome::RetryLater);
    }

    #[test]
    fn settings_decode_is_tolerant() {
        let raw: Value = serde_json::from_str(r#"{"enabled":true,"kinds":["approval","nonsense"],"quietFrom":99}"#).unwrap();
        let s = PushSettings::from_value(&raw);
        assert!(s.enabled);
        assert_eq!(s.kinds, [PushKind::Approval].into());
        assert_eq!(s.quiet_from, None);
        assert!(s.only_when_away);
        let again: PushSettings = serde_json::from_value(serde_json::to_value(&s).unwrap()).unwrap();
        assert_eq!(again, s);
        assert_eq!(serde_json::from_value::<PushSettings>(raw).unwrap(), s);
    }
}
