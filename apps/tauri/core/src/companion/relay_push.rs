//! Push through the relay (`RelayPush.swift`, `RelayPushClient.swift`, docs/COMPANION.md "Push through Nook's relay"):
//! for a computer without an Apple developer account of its own, and the only way to reach Nook on Android. Each
//! notification is sealed with a key derived from the phone's pairing key and posted with its device token to the
//! relay's `/v1/push` (`apps/relay/worker/push.js`), which signs an APNs request with Nook's key (or sends a Firebase
//! data message) and passes the blob on. Apple, Google and the relay only see "Nook needs you"; the phone opens the blob.

use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Sha256;

use super::push::{self, Outcome};
use super::seal::{self, Direction};

/// What a notification says, sealed for the phone (`RelayPushContent`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayPushContent {
    pub title: String,
    pub body: String,
    /// The notification's category (`push::push_category`): its buttons.
    pub category: String,
    /// Groups a session's notifications.
    pub thread: String,
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    pub badge: i64,
    /// The id of the pairing it goes out for, so a button reaches this computer whichever is active on the phone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac: Option<String>,
}

impl RelayPushContent {
    /// Longest title and text sent: the sealed blob must stay well inside Apple's 4 KB.
    pub const MAX_TITLE: usize = 120;
    pub const MAX_BODY: usize = 240;

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        title: &str,
        body: &str,
        category: &str,
        thread: &str,
        session: &str,
        item: Option<&str>,
        badge: i64,
        mac: Option<&str>,
    ) -> Self {
        Self {
            title: title.chars().take(Self::MAX_TITLE).collect(),
            body: body.chars().take(Self::MAX_BODY).collect(),
            category: category.into(),
            thread: thread.chars().take(64).collect(),
            session: session.into(),
            item: item.map(Into::into),
            badge: badge.max(0),
            mac: mac.map(Into::into),
        }
    }
}

/// The CompanionSeal envelope inside a request: the claimed device id and the sealed bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sealed {
    pub d: String,
    pub s: String,
}

/// The body posted to the relay's `/v1/push` (`RelayPushRequest`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayPushRequest {
    /// The phone's room (`transport::relay_room`): the relay limits pushes per room.
    pub room: String,
    pub token: String,
    pub production: bool,
    pub sealed: Sealed,
    /// Opaque (`collapse_id`), so neither the relay nor Apple learns session ids.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapse: Option<String>,
    pub urgent: bool,
    /// "fcm" for an Android phone; none for Apple's push.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service: Option<String>,
}

/// The service name of a Firebase Cloud Messaging token (`FCMToken.service`), as `register` sends it in `item`.
pub const FCM: &str = "fcm";

/// A Firebase registration token, as Nook on Android registers it (`FCMToken.valid`).
pub fn valid_fcm_token(text: &str) -> bool {
    (100..=4096).contains(&text.chars().count()) && text.chars().all(|c| c.is_ascii_alphanumeric() || ":_-".contains(c))
}

fn hmac(key: &[u8], message: &[u8]) -> Vec<u8> {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("any key length");
    mac.update(message);
    mac.finalize().into_bytes().to_vec()
}

/// The key a push is sealed with (`RelayPush.pushKey`): derived from the pairing key, so the phone's notification
/// code holds this one and never the pairing key, and a push can never pass as a reply.
pub fn push_key(pairing_key: &[u8]) -> Vec<u8> {
    hmac(pairing_key, b"nook-companion-push-v1")
}

/// The collapse id Apple sees: a keyed hash of the real one (`RelayPush.collapseID`).
pub fn collapse_id(key: &str, push_key: &[u8]) -> String {
    push::token_hex(&hmac(push_key, key.as_bytes())[..16])
}

/// `https://relay/v1/push`, or none for an address that is no relay.
pub fn endpoint(relay: &str) -> Option<String> {
    let base = super::transport::normalize_relay(relay)?;
    Some(format!("{}/v1/push", base.trim_end_matches('/')))
}

/// The envelope for one phone (`RelayPush.seal`): the content's JSON, sealed with the push key, computer → phone.
pub fn seal(content: &RelayPushContent, pairing_key: &[u8], device_id: &str) -> Vec<u8> {
    let json = serde_json::to_vec(content).expect("plain struct");
    seal::seal(&json, &push_key(pairing_key), device_id, Direction::Response)
}

/// The phone side (`RelayPush.open`), with the push key it keeps.
pub fn open(envelope: &[u8], push_key: &[u8]) -> Option<RelayPushContent> {
    serde_json::from_slice(&seal::open(envelope, push_key, Direction::Response).ok()?).ok()
}

fn is_room(text: &str) -> bool {
    text.len() == 32 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The request for one phone around an envelope `seal` made (`RelayPush.request`); none when something does not fit.
pub fn request(
    envelope: &[u8],
    room: &str,
    token: &str,
    production: bool,
    collapse: Option<String>,
    urgent: bool,
    service: Option<&str>,
) -> Option<RelayPushRequest> {
    let fcm = service == Some(FCM);
    if !is_room(room) || !(if fcm { valid_fcm_token(token) } else { push::valid_token(token) }) {
        return None;
    }
    let sealed: Sealed = serde_json::from_slice(envelope).ok()?;
    Some(RelayPushRequest {
        room: room.into(),
        token: if fcm { token.into() } else { token.to_lowercase() },
        production,
        sealed,
        collapse,
        urgent,
        service: fcm.then(|| FCM.into()),
    })
}

/// What the relay's answer means for the token, as for a direct push (`RelayPush.outcome`): the outcome, Apple's
/// status, and Apple's reason or the relay's own.
pub fn outcome(status: u16, body: &[u8]) -> (Outcome, u16, Option<String>) {
    let object: Option<Value> = serde_json::from_slice(body).ok();
    let field = |k: &str| object.as_ref().and_then(|o| o.get(k)).and_then(Value::as_str).map(str::to_string);
    match status {
        200 => {
            let apns = object.as_ref().and_then(|o| o.get("apns")).and_then(Value::as_u64).unwrap_or(0) as u16;
            let reason = field("reason");
            (push::outcome(apns, reason.as_deref()), apns, reason)
        }
        429 | 502 | 503 => (Outcome::RetryLater, 0, field("error")),
        _ => (Outcome::Configuration, 0, Some(field("error").unwrap_or_else(|| format!("HTTP {status}")))),
    }
}

/// Posts one request to the relay and reads its answer; a failed connection is worth trying again later.
pub async fn post(http: &reqwest::Client, url: &str, request: &RelayPushRequest) -> (Outcome, u16, Option<String>) {
    match http.post(url).json(request).send().await {
        Ok(response) => {
            let status = response.status().as_u16();
            let body = response.bytes().await.unwrap_or_default();
            outcome(status, &body)
        }
        Err(e) => (Outcome::RetryLater, 0, Some(e.to_string())),
    }
}

/// How pushes reach the phones (`RelayPushClient.Route`): sealed through the relay in use, or straight to Apple with
/// the user's own APNs key. An Android phone always goes through the relay.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PushRoute {
    Relay,
    Own,
}

impl PushRoute {
    /// The first choice (`RelayPushClient.init`): someone who already set up their own key keeps it; everyone else
    /// starts on the relay when the build has one.
    pub fn default_for(has_own_key: bool, build_has_relay: bool) -> Self {
        if has_own_key || !build_has_relay {
            Self::Own
        } else {
            Self::Relay
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::companion::models::PairedDevice;

    fn pairing_key() -> Vec<u8> {
        (0u8..32).collect()
    }
    const ROOM: &str = "cae98fe2b67a6f65273aa18446bdf884";
    /// Made outside Swift and Rust (Python: HMAC, HKDF-SHA256 and ChaCha20-Poly1305 as CompanionSeal does); the same
    /// vector as the Mac's `RelayPushTests`.
    const VECTOR: &str = r#"{"d": "630dcd2966c43366", "s": "AAAAAAAAAAAAAAAABS3kO4MIl6sxb1ccggt5baLczbPE5rpaZZaRXcuXSEkU4GmcxaFGzXF2q8bQTP2LEs8QYTtYj28NxxIl6Jzq5FRLlKT08PCoTrtIfWad9wFhK/oWpdxpklboXglaJ9jrZzvC7W6L/zlNGKz8GyQVJJtQdWS9SyRboYTAbGjAzZDq+8r9QGuqTk4csyaBfiMwc1M="}"#;

    #[test]
    fn push_key_and_collapse_id_match_the_mac() {
        let push = push_key(&pairing_key());
        assert_eq!(push::token_hex(&push), "7a429408bc2815112a429079b335fb1a10ddd5ca648231192c2182f7ce957c07");
        assert_eq!(PairedDevice::identifier(&pairing_key()), "630dcd2966c43366");
        assert_eq!(super::super::transport::relay_room(&pairing_key()), ROOM);
        let collapse = collapse_id("approval:s1:i1", &push);
        assert_eq!(collapse, "f6b38485348952fccce2343eeac86bd8");
        assert_eq!(push, super::super::client::push_key(&pairing_key()), "the phone side derives the same key");
    }

    #[test]
    fn opens_the_outside_vector_and_seals_a_round_trip() {
        let push = push_key(&pairing_key());
        let outside = open(VECTOR.as_bytes(), &push).expect("the Mac's vector opens");
        assert_eq!(outside.title, "Claude");
        assert_eq!(outside.item.as_deref(), Some("i1"));
        assert_eq!(outside.badge, 2);

        let content = RelayPushContent::new(
            "Claude · Fix tests",
            "Needs your approval",
            "approvalDeny",
            "s1",
            "s1",
            Some("i1"),
            2,
            Some("630dcd2966c43366"),
        );
        let device = PairedDevice::identifier(&pairing_key());
        let envelope = seal(&content, &pairing_key(), &device);
        assert_eq!(seal::claimed_device(&envelope).as_deref(), Some(device.as_str()));
        assert_eq!(open(&envelope, &push), Some(content));
        assert!(open(&envelope, &pairing_key()).is_none(), "the pairing key itself does not open a push");
        assert!(seal::open(&envelope, &pairing_key(), Direction::Response).is_err(), "a push never passes as a reply");
    }

    #[test]
    fn content_is_bounded() {
        let c = RelayPushContent::new(&"t".repeat(500), &"b".repeat(500), "question", "s", "s", Some("i"), -3, None);
        assert_eq!(c.title.chars().count(), RelayPushContent::MAX_TITLE);
        assert_eq!(c.body.chars().count(), RelayPushContent::MAX_BODY);
        assert_eq!(c.badge, 0);
        let json = serde_json::to_value(&c).unwrap();
        assert!(json.get("mac").is_none());
    }

    #[test]
    fn request_around_an_envelope() {
        let token = "a1".repeat(32);
        let r = request(VECTOR.as_bytes(), ROOM, &token.to_uppercase(), true, Some("ab".into()), true, None).unwrap();
        assert_eq!(r.token, token);
        assert_eq!(r.sealed.d, "630dcd2966c43366");
        let json = serde_json::to_value(&r).unwrap();
        let mut keys: Vec<&String> = json.as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(keys, ["collapse", "production", "room", "sealed", "token", "urgent"], "what push.js reads");
        assert!(request(VECTOR.as_bytes(), "nope", &token, true, None, false, None).is_none());
        assert!(request(VECTOR.as_bytes(), ROOM, "xyz", true, None, false, None).is_none());
        assert!(request(b"{}", ROOM, &token, true, None, false, None).is_none());

        assert_eq!(endpoint("nook-relay.me.workers.dev").as_deref(), Some("https://nook-relay.me.workers.dev/v1/push"));
        assert!(endpoint("http://example.com").is_none());
    }

    #[test]
    fn android_tokens_go_as_fcm() {
        let fcm = format!("dQw4w9WgXcQ:APA91b{}", "x".repeat(140));
        assert!(valid_fcm_token(&fcm));
        assert!(!valid_fcm_token(&"a1".repeat(32)), "too short for Firebase");
        assert!(!valid_fcm_token(&format!("{fcm}/../x")));
        let r = request(VECTOR.as_bytes(), ROOM, &fcm, true, None, false, Some(FCM)).unwrap();
        assert_eq!(r.token, fcm, "kept as it is, not lowercased");
        assert_eq!(r.service.as_deref(), Some("fcm"));
        assert!(request(VECTOR.as_bytes(), ROOM, &"a1".repeat(32), true, None, false, Some(FCM)).is_none());
        assert!(request(VECTOR.as_bytes(), ROOM, &fcm, true, None, false, None).is_none(), "an FCM token is no APNs token");
    }

    #[test]
    fn reads_the_relays_answer() {
        assert_eq!(outcome(200, br#"{"apns":200}"#).0, Outcome::Delivered);
        let gone = outcome(200, br#"{"apns":410,"reason":"Unregistered"}"#);
        assert_eq!(gone.0, Outcome::DropToken);
        assert_eq!(gone.2.as_deref(), Some("Unregistered"));
        assert_eq!(outcome(429, b"").0, Outcome::RetryLater);
        assert_eq!(outcome(502, b"").0, Outcome::RetryLater);
        let off = outcome(501, br#"{"error":"push is not set up on this relay"}"#);
        assert_eq!(off.0, Outcome::Configuration);
        assert_eq!(off.2.as_deref(), Some("push is not set up on this relay"));
    }

    #[test]
    fn the_first_route() {
        assert_eq!(PushRoute::default_for(true, true), PushRoute::Own);
        assert_eq!(PushRoute::default_for(false, false), PushRoute::Own);
        assert_eq!(PushRoute::default_for(false, true), PushRoute::Relay);
    }
}
